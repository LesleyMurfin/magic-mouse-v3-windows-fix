// SPDX-License-Identifier: MIT
#include "Driver.h"
#include "InputHandler.h"   // SdpRewrite_Process
#include "GestureEngine.h"  // TranslateMouse2ToHid, MM2_HEADER_LEN

// --------------------------------------------------------------------------
// DriverEntry
// --------------------------------------------------------------------------

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, EvtDeviceAdd);
    return WdfDriverCreate(DriverObject, RegistryPath, WDF_NO_OBJECT_ATTRIBUTES,
                           &config, WDF_NO_HANDLE);
}

// --------------------------------------------------------------------------
// EvtDeviceAdd — bind as lower filter, read config, start diagnostic timer
// --------------------------------------------------------------------------

NTSTATUS
EvtDeviceAdd(_In_ WDFDRIVER Driver, _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    UNREFERENCED_PARAMETER(Driver);

    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES devAttr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&devAttr, DEVICE_CONTEXT);

    WDFDEVICE device;
    NTSTATUS status = WdfDeviceCreate(&DeviceInit, &devAttr, &device);
    if (!NT_SUCCESS(status)) { return status; }

    PDEVICE_CONTEXT ctx = GetDeviceContext(device);

    WDF_OBJECT_ATTRIBUTES lockAttr;
    WDF_OBJECT_ATTRIBUTES_INIT(&lockAttr);
    lockAttr.ParentObject = device;
    status = WdfSpinLockCreate(&lockAttr, &ctx->Lock);
    if (!NT_SUCCESS(status)) { return status; }

    // Read EnableInjection from Parameters registry subkey.
    // Default TRUE — missing key/value means "enabled".
    ctx->EnableInjection = TRUE;
    {
        WDFKEY paramsKey = NULL;
        NTSTATUS ks = WdfDriverOpenParametersRegistryKey(
            Driver, KEY_READ, WDF_NO_OBJECT_ATTRIBUTES, &paramsKey);
        if (NT_SUCCESS(ks) && paramsKey != NULL)
        {
            ULONG val = 1;
            UNICODE_STRING valName;
            RtlInitUnicodeString(&valName, L"EnableInjection");
            NTSTATUS vs = WdfRegistryQueryULong(paramsKey, &valName, &val);
            if (NT_SUCCESS(vs))
            {
                ctx->EnableInjection = (val != 0);
            }
            WdfRegistryClose(paramsKey);
        }
    }

    DbgPrint("M13: AddDevice — EnableInjection=%d\n", ctx->EnableInjection);

    // Populate ProductId from hardware ID so OnSdpQueryComplete can gate
    // Descriptor C injection to v3 (PID 0x0323) only.
    // v1 (PIDs 0x030D / 0x0310) has a native HID descriptor with RID=0x47
    // for battery; overwriting it with Descriptor C would break v1 battery.
    //
    // Hardware ID format (BT stack):
    //   BTHENUM\{...}_VID&XXXXXXXX_PID&NNNN_REV&XXXX
    // We scan for the substring "PID&" and parse the following 4 hex digits.
    //
    // IoGetDeviceProperty on the PDO works at PASSIVE_LEVEL (EvtDeviceAdd runs
    // at PASSIVE_LEVEL), requires no extra allocation handles, and is the
    // standard WDM approach for lower filter drivers that don't own the PDO.
    ctx->ProductId = 0;  // safe default: unknown → injection allowed
    {
        PDEVICE_OBJECT pdo = WdfDeviceWdmGetPhysicalDevice(device);
        if (pdo != NULL)
        {
            // Hardware ID is a REG_MULTI_SZ; allocate a 512-byte stack buffer.
            // Typical BT hardware ID strings are well under 256 wide characters.
            WCHAR hwIdBuf[256] = { 0 };
            ULONG retLen = 0;
            NTSTATUS pidStatus = IoGetDeviceProperty(
                pdo,
                DevicePropertyHardwareID,
                sizeof(hwIdBuf) - sizeof(WCHAR),  // leave room for terminator
                hwIdBuf,
                &retLen);

            if (NT_SUCCESS(pidStatus) && retLen >= sizeof(WCHAR))
            {
                // Scan the MULTI_SZ block (may contain multiple NUL-separated
                // strings; we search the entire block for "PID&").
                ULONG wcharCount = retLen / sizeof(WCHAR);
                for (ULONG i = 0; i + 8 <= wcharCount; i++)
                {
                    if (hwIdBuf[i]   == L'P' &&
                        hwIdBuf[i+1] == L'I' &&
                        hwIdBuf[i+2] == L'D' &&
                        hwIdBuf[i+3] == L'&')
                    {
                        // Parse up to 4 hex digits immediately following "PID&".
                        USHORT pid = 0;
                        for (ULONG j = i + 4; j < wcharCount && j < i + 8; j++)
                        {
                            WCHAR  c      = hwIdBuf[j];
                            USHORT nibble = 0;
                            if      (c >= L'0' && c <= L'9') nibble = (USHORT)(c - L'0');
                            else if (c >= L'A' && c <= L'F') nibble = (USHORT)(c - L'A' + 10);
                            else if (c >= L'a' && c <= L'f') nibble = (USHORT)(c - L'a' + 10);
                            else break;
                            pid = (USHORT)((pid << 4) | nibble);
                        }
                        ctx->ProductId = pid;
                        break;
                    }
                }
            }
            else
            {
                DbgPrint("M13: AddDevice — IoGetDeviceProperty(HardwareID) status=0x%08X; ProductId stays 0\n",
                         (ULONG)pidStatus);
            }
        }
        DbgPrint("M13: AddDevice — ProductId=0x%04X\n", ctx->ProductId);
    }

    // Diagnostic 1 Hz timer (parent = device, fires M13_DiagTimerFunc)
    WDF_TIMER_CONFIG timerCfg;
    WDF_TIMER_CONFIG_INIT_PERIODIC(&timerCfg, M13_DiagTimerFunc, 1000);
    WDF_OBJECT_ATTRIBUTES timerAttr;
    WDF_OBJECT_ATTRIBUTES_INIT(&timerAttr);
    timerAttr.ParentObject = device;
    status = WdfTimerCreate(&timerCfg, &timerAttr, &ctx->DiagTimer);
    if (!NT_SUCCESS(status)) { return status; }

    // Work item for PASSIVE_LEVEL registry writes (parent = device)
    WDF_WORKITEM_CONFIG wiCfg;
    WDF_WORKITEM_CONFIG_INIT(&wiCfg, M13_DiagWorkItemFunc);
    WDF_OBJECT_ATTRIBUTES wiAttr;
    WDF_OBJECT_ATTRIBUTES_INIT(&wiAttr);
    wiAttr.ParentObject = device;
    status = WdfWorkItemCreate(&wiCfg, &wiAttr, &ctx->DiagWorkItem);
    if (!NT_SUCCESS(status)) { return status; }

    WdfTimerStart(ctx->DiagTimer, WDF_REL_TIMEOUT_IN_MS(1000));

    // Default I/O queue — parallel dispatch.
    // EvtIoDeviceControl: intercept IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE (0x410210)
    //   sent as IRP_MJ_DEVICE_CONTROL by applewirelessmouse.sys/HidBth.sys.
    // EvtIoInternalDeviceControl: same intercept via IRP_MJ_INTERNAL_DEVICE_CONTROL
    //   (covers both dispatch types; only one fires per request).
    // EvtIoDefault: passthrough for all other IRP types (READ, WRITE, etc.)
    //   so we don't break the device stack for non-SDP traffic.
    WDF_IO_QUEUE_CONFIG qCfg;
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&qCfg, WdfIoQueueDispatchParallel);
    qCfg.EvtIoDeviceControl         = EvtIoDeviceControl;
    qCfg.EvtIoInternalDeviceControl = EvtIoInternalDeviceControl;
    qCfg.EvtIoRead                  = EvtIoRead;   // M14: intercept READ completions for RID=0x12 scroll translation
    qCfg.EvtIoDefault               = EvtIoDefault;
    WDFQUEUE queue;
    return WdfIoQueueCreate(device, &qCfg, WDF_NO_OBJECT_ATTRIBUTES, &queue);
}

// --------------------------------------------------------------------------
// EvtIoInternalDeviceControl
//
// Intercepts IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE (0x410210) and forwards
// it with a completion routine to rewrite the SDP output buffer.
// All other IOCTLs pass through send-and-forget.
// --------------------------------------------------------------------------

VOID
EvtIoInternalDeviceControl(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request,
                            _In_ size_t OutputBufferLength, _In_ size_t InputBufferLength,
                            _In_ ULONG IoControlCode)
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    WDFDEVICE    device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    WDFIOTARGET  target = WdfDeviceGetIoTarget(device);

    if (IoControlCode == IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE &&
        ctx != NULL && ctx->EnableInjection)
    {
        WdfSpinLockAcquire(ctx->Lock);
        ctx->IoctlInterceptCount++;
        WdfSpinLockRelease(ctx->Lock);

        // Forward with our completion routine so we can rewrite the output buffer.
        WdfRequestFormatRequestUsingCurrentType(Request);
        WdfRequestSetCompletionRoutine(Request, OnSdpQueryComplete, ctx);
        if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
        {
            WdfRequestComplete(Request, WdfRequestGetStatus(Request));
        }
        return;
    }

    // Passthrough — send-and-forget.
    WdfRequestFormatRequestUsingCurrentType(Request);
    WDF_REQUEST_SEND_OPTIONS opts;
    WDF_REQUEST_SEND_OPTIONS_INIT(&opts, WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
    if (!WdfRequestSend(Request, target, &opts))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

// --------------------------------------------------------------------------
// EvtIoDeviceControl — IRP_MJ_DEVICE_CONTROL intercept
//
// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE is sent by applewirelessmouse.sys
// via IRP_MJ_DEVICE_CONTROL. Same logic as EvtIoInternalDeviceControl.
// --------------------------------------------------------------------------

VOID
EvtIoDeviceControl(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request,
                   _In_ size_t OutputBufferLength, _In_ size_t InputBufferLength,
                   _In_ ULONG IoControlCode)
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    WDFDEVICE    device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    WDFIOTARGET  target = WdfDeviceGetIoTarget(device);

    if (IoControlCode == IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE &&
        ctx != NULL && ctx->EnableInjection)
    {
        WdfSpinLockAcquire(ctx->Lock);
        ctx->IoctlInterceptCount++;
        WdfSpinLockRelease(ctx->Lock);

        WdfRequestFormatRequestUsingCurrentType(Request);
        WdfRequestSetCompletionRoutine(Request, OnSdpQueryComplete, ctx);
        if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
        {
            WdfRequestComplete(Request, WdfRequestGetStatus(Request));
        }
        return;
    }

    WdfRequestFormatRequestUsingCurrentType(Request);
    WDF_REQUEST_SEND_OPTIONS opts;
    WDF_REQUEST_SEND_OPTIONS_INIT(&opts, WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
    if (!WdfRequestSend(Request, target, &opts))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

// --------------------------------------------------------------------------
// EvtIoDefault — passthrough for all non-IOCTL I/O requests
//
// WDF filter drivers with a default queue must explicitly forward any IRP
// types not otherwise handled (READ, WRITE, etc.) or WDF completes them
// with STATUS_INVALID_DEVICE_REQUEST, breaking the device.
// --------------------------------------------------------------------------

VOID
EvtIoDefault(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request)
{
    WDFDEVICE   device = WdfIoQueueGetDevice(Queue);
    WDFIOTARGET target = WdfDeviceGetIoTarget(device);

    WdfRequestFormatRequestUsingCurrentType(Request);
    WDF_REQUEST_SEND_OPTIONS opts;
    WDF_REQUEST_SEND_OPTIONS_INIT(&opts, WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
    if (!WdfRequestSend(Request, target, &opts))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

// --------------------------------------------------------------------------
// EvtIoRead — M14: intercept IRP_MJ_READ completions
//
// Forwards the READ request with OnReadComplete so we can inspect the
// returned buffer. HidBth fills the buffer with a HID input report on
// completion; byte[0] is the Report ID.
// --------------------------------------------------------------------------

VOID
EvtIoRead(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request, _In_ size_t Length)
{
    UNREFERENCED_PARAMETER(Length);

    WDFDEVICE   device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    WDFIOTARGET target = WdfDeviceGetIoTarget(device);

    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(Request, OnReadComplete, ctx);
    if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

// --------------------------------------------------------------------------
// OnReadComplete — M14c: RID 0x12 → RID 0x02 scroll translation completion routine
//
// Replaces OnHidReadComplete. Handles IRP_MJ_READ completions:
//   - Increments HidReadCount (total IRP_MJ_READ completions seen)
//   - For v3 (PID 0x0323) devices: if buf[0] == 0x12 (MOUSE2_REPORT_ID),
//     calls TranslateMouse2ToHid() to synthesize a RID 0x02 scroll report
//   - SEH guard: IOCTL_HID_READ_REPORT may use METHOD_NEITHER buffers;
//     accessing buf without __try/__except is a Page Fault BSOD vector
//   - WdfRequestSetInformation: updates returned byte count after translation
//     (missing = heap corruption in caller)
// --------------------------------------------------------------------------

VOID
OnReadComplete(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target,
               _In_ PWDF_REQUEST_COMPLETION_PARAMS Params, _In_ WDFCONTEXT Context)
{
    UNREFERENCED_PARAMETER(Target);

    PDEVICE_CONTEXT ctx    = (PDEVICE_CONTEXT)Context;
    NTSTATUS        status = Params->IoStatus.Status;

    if (!NT_SUCCESS(status) || ctx == NULL)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    PUCHAR buf    = NULL;
    SIZE_T bufLen = 0;
    NTSTATUS rs = WdfRequestRetrieveOutputBuffer(Request, 1, &buf, &bufLen);
    if (!NT_SUCCESS(rs) || buf == NULL)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    // Update diagnostic counters
    SIZE_T bytesRead = Params->IoStatus.Information;
    WdfSpinLockAcquire(ctx->Lock);
    ctx->HidReadCount++;
    if (bytesRead > 0 && bytesRead < bufLen && ((PUCHAR)buf)[0] == 0x12)
        ctx->Rid12Count++;
    WdfSpinLockRelease(ctx->Lock);

    // __try/__except required: IOCTL_HID_READ_REPORT may use METHOD_NEITHER buffers.
    // Accessing buf without SEH is a Page Fault BSOD vector.
    __try
    {
        if (bytesRead >= MM2_HEADER_LEN && ((PUCHAR)buf)[0] == 0x12
            && ctx->ProductId == MM_PID_V3)
        {
            UCHAR  translated[5];
            ULONG  translatedLen = sizeof(translated);
            NTSTATUS ts = TranslateMouse2ToHid(
                (PUCHAR)buf, bytesRead, translated, &translatedLen, ctx);
            if (NT_SUCCESS(ts) && translatedLen > 0)
            {
                RtlCopyMemory(buf, translated, translatedLen);
                // CRITICAL: update returned byte count (missing = heap corruption)
                WdfRequestSetInformation(Request, translatedLen);
            }
        }
    }
    __except(EXCEPTION_EXECUTE_HANDLER)
    {
        DbgPrint("M14: OnReadComplete — buffer access exception, passing through\n");
    }

    WdfRequestComplete(Request, status);
}

// --------------------------------------------------------------------------
// OnSdpQueryComplete — completion routine for IOCTL 0x410210
//
// Retrieves the SDP attribute response buffer, calls SdpRewrite_Process to
// find and replace the HIDDescriptorList (attribute 0x0206), then completes
// the request. If rewrite is not applicable (attribute not found, or buffer
// parse fails), completes with the original unmodified buffer and status.
// --------------------------------------------------------------------------

VOID
OnSdpQueryComplete(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target,
                   _In_ PWDF_REQUEST_COMPLETION_PARAMS Params, _In_ WDFCONTEXT Context)
{
    UNREFERENCED_PARAMETER(Target);

    PDEVICE_CONTEXT ctx    = (PDEVICE_CONTEXT)Context;
    NTSTATUS        status = Params->IoStatus.Status;

    if (!NT_SUCCESS(status) || ctx == NULL)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    // METHOD_BUFFERED: output buffer is Irp->AssociatedIrp.SystemBuffer.
    PVOID  buf         = NULL;
    size_t bufAllocLen = 0;
    NTSTATUS rs = WdfRequestRetrieveOutputBuffer(Request, 1, &buf, &bufAllocLen);
    if (!NT_SUCCESS(rs) || buf == NULL)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    // IoStatus.Information = bytes actually written by lower driver.
    size_t sdpLen = Params->IoStatus.Information;
    if (sdpLen == 0 || sdpLen > bufAllocLen)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    // Snapshot first 64 bytes + buffer size for offline diagnosis.
    WdfSpinLockAcquire(ctx->Lock);
    ctx->LastSdpBufSize = (ULONG)sdpLen;
    ULONG snapLen = (sdpLen < 64) ? (ULONG)sdpLen : 64;
    RtlCopyMemory(ctx->LastSdpBytes, buf, snapLen);
    if (snapLen < 64) RtlZeroMemory(ctx->LastSdpBytes + snapLen, 64 - snapLen);
    WdfSpinLockRelease(ctx->Lock);

    // v1 pass-through guard: only inject Descriptor C for v3 (PID 0x0323).
    // v1 (PIDs 0x030D / 0x0310) has a native HID descriptor with RID=0x47 for
    // battery; overwriting it with Descriptor C would break v1 battery permanently.
    // ProductId == 0 means we could not read the PID — allow injection (safe
    // fallback: preserves behaviour for unknown devices, same as before this guard).
    if (ctx->ProductId != 0 && ctx->ProductId != MM_PID_V3)
    {
        DbgPrint("M13: OnSdpQueryComplete — PID=0x%04X is not v3 (0x%04X), pass-through (no injection)\n",
                 ctx->ProductId, (USHORT)MM_PID_V3);
        WdfRequestComplete(Request, status);
        return;
    }

    // Attempt descriptor rewrite.
    ULONG    newLen      = (ULONG)sdpLen;
    NTSTATUS patchStatus = SdpRewrite_Process((PUCHAR)buf, (ULONG)sdpLen, &newLen);

    // Update diagnostic counters.
    WdfSpinLockAcquire(ctx->Lock);
    ctx->LastPatchStatus = (ULONG)patchStatus;
    if (patchStatus == STATUS_SUCCESS)
    {
        ctx->SdpScanHits++;
        ctx->SdpPatchSuccess++;
    }
    else if (patchStatus == STATUS_MORE_PROCESSING_REQUIRED)
    {
        // Pattern found but patch validation failed.
        ctx->SdpScanHits++;
    }
    // STATUS_NOT_FOUND: no HIDDescriptorList in this buffer — normal, no counter.
    WdfSpinLockRelease(ctx->Lock);

    // If patch shrunk the buffer, update IoStatus.Information for the caller.
    if (patchStatus == STATUS_SUCCESS && newLen != (ULONG)sdpLen)
    {
        WdfRequestSetInformation(Request, (ULONG_PTR)newLen);
    }

    WdfRequestComplete(Request, status);
}

// --------------------------------------------------------------------------
// Diagnostic timer + work item — 1 Hz flush to registry
//
// Registry path: HKLM\SYSTEM\CurrentControlSet\Services\MagicMouseDriver\Diag
//
// Keys written (read with Get-ItemProperty in PowerShell to verify driver):
//   IoctlInterceptCount  REG_DWORD  — 0x410210 IOCTLs seen
//   SdpScanHits          REG_DWORD  — attribute 0x0206 found
//   SdpPatchSuccess      REG_DWORD  — descriptor replaced successfully
//   LastSdpBufSize       REG_DWORD  — size of last SDP buffer
//   LastPatchStatusHex   REG_DWORD  — NTSTATUS of last patch attempt
//   LastSdpBytes         REG_BINARY — first 64 bytes of last SDP buffer
//   HidReadCount         REG_DWORD  — M14: total IRP_MJ_READ completions
//   Rid12Count           REG_DWORD  — M14c: completions where buf[0]==0x12 (MOUSE2)
//   Rid27Count           REG_DWORD  — legacy: completions where buf[0]==0x27
//   Rid27LoggedCount     REG_DWORD  — legacy: RID=0x27 reports sent to DbgPrint
// --------------------------------------------------------------------------

VOID M13_DiagTimerFunc(_In_ WDFTIMER Timer)
{
    WDFDEVICE device = (WDFDEVICE)WdfTimerGetParentObject(Timer);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    if (ctx != NULL && ctx->DiagWorkItem != NULL)
        WdfWorkItemEnqueue(ctx->DiagWorkItem);
}

VOID M13_DiagWorkItemFunc(_In_ WDFWORKITEM WorkItem)
{
    WDFDEVICE device = (WDFDEVICE)WdfWorkItemGetParentObject(WorkItem);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    if (ctx == NULL) return;

    // Snapshot under lock, then write registry at PASSIVE_LEVEL unlocked.
    ULONG ictlCount, scanHits, patchOk, lastSize, lastStatus;
    ULONG hidReads, rid12Count, rid27Count, rid27Logged, rid27SlotsFilled;
    UCHAR lastBytes[64];
    UCHAR rid27Snapshot[RID27_RING_SLOTS * RID27_BYTES_PER_SLOT];
    WdfSpinLockAcquire(ctx->Lock);
    ictlCount     = ctx->IoctlInterceptCount;
    scanHits      = ctx->SdpScanHits;
    patchOk       = ctx->SdpPatchSuccess;
    lastSize      = ctx->LastSdpBufSize;
    lastStatus    = ctx->LastPatchStatus;
    hidReads      = ctx->HidReadCount;
    rid12Count    = ctx->Rid12Count;
    rid27Count    = ctx->Rid27Count;
    rid27Logged   = ctx->Rid27LoggedCount;
    rid27SlotsFilled = (rid27Count < RID27_RING_SLOTS) ? rid27Count : RID27_RING_SLOTS;
    RtlCopyMemory(lastBytes, ctx->LastSdpBytes, 64);
    RtlCopyMemory(rid27Snapshot, ctx->Rid27Ring,
                  RID27_RING_SLOTS * RID27_BYTES_PER_SLOT);
    WdfSpinLockRelease(ctx->Lock);

    UNICODE_STRING keyPath;
    RtlInitUnicodeString(&keyPath,
        L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\MagicMouseDriver\\Diag");
    OBJECT_ATTRIBUTES attr;
    InitializeObjectAttributes(&attr, &keyPath,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    HANDLE key   = NULL;
    ULONG  disp  = 0;
    if (!NT_SUCCESS(ZwCreateKey(&key, KEY_WRITE, &attr, 0, NULL,
                                REG_OPTION_NON_VOLATILE, &disp))) return;

    UNICODE_STRING n;

#define SET_DWORD(Name, Val) \
    RtlInitUnicodeString(&n, Name); \
    ZwSetValueKey(key, &n, 0, REG_DWORD, &(Val), sizeof(ULONG))

    SET_DWORD(L"IoctlInterceptCount", ictlCount);
    SET_DWORD(L"SdpScanHits",         scanHits);
    SET_DWORD(L"SdpPatchSuccess",     patchOk);
    SET_DWORD(L"LastSdpBufSize",      lastSize);
    SET_DWORD(L"LastPatchStatusHex",  lastStatus);
    SET_DWORD(L"HidReadCount",        hidReads);
    SET_DWORD(L"Rid12Count",          rid12Count);
    SET_DWORD(L"Rid27Count",          rid27Count);
    SET_DWORD(L"Rid27LoggedCount",    rid27Logged);
    SET_DWORD(L"Rid27SlotsFilled",    rid27SlotsFilled);

#undef SET_DWORD

    RtlInitUnicodeString(&n, L"LastSdpBytes");
    ZwSetValueKey(key, &n, 0, REG_BINARY, lastBytes, 64);

    // Flush RID=0x27 ring buffer so PowerShell can read raw bytes directly
    // from registry (no DebugView required).
    // Each slot is RID27_BYTES_PER_SLOT bytes; only rid27SlotsFilled slots valid.
    RtlInitUnicodeString(&n, L"Rid27RingBuf");
    ZwSetValueKey(key, &n, 0, REG_BINARY, rid27Snapshot,
                  RID27_RING_SLOTS * RID27_BYTES_PER_SLOT);

    ZwClose(key);
}
