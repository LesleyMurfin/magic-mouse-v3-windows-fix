// SPDX-License-Identifier: MIT
#include "Driver.h"
#include "InputHandler.h"
#include "GestureEngine.h"
#include "AclTranslate.h"

// BRB_L2CA_ACL_TRANSFER field offsets on x64 (bthddi.h / Win10+).
// BRB_HEADER.Type is at +0x16. ACL Buffer/Size follow the 0x70-byte header
// + BTH_ADDR + ChannelHandle. Validated against WDK 10.0.14393 bthddi.h.
#define MM_BRB_LENGTH_OFFSET  0x10
#define MM_BRB_TYPE_OFFSET    0x16
#define MM_ACL_FLAGS_OFFSET   0x80
#define MM_ACL_BUFSIZE_OFFSET 0x84
#define MM_ACL_BUFFER_OFFSET  0x88
#define MM_ACL_MDL_OFFSET     0x90
#define MM_ACL_MIN_BRB_LEN    0x98

static VOID
ForwardPassthrough(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target)
{
    WdfRequestFormatRequestUsingCurrentType(Request);
    WDF_REQUEST_SEND_OPTIONS opts;
    WDF_REQUEST_SEND_OPTIONS_INIT(&opts, WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
    if (!WdfRequestSend(Request, Target, &opts))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

static VOID
ForwardSdpWithCompletion(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target, _In_ PDEVICE_CONTEXT ctx)
{
    WdfSpinLockAcquire(ctx->Lock);
    ctx->IoctlInterceptCount++;
    WdfSpinLockRelease(ctx->Lock);

    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(Request, OnSdpQueryComplete, ctx);
    if (!WdfRequestSend(Request, Target, WDF_NO_SEND_OPTIONS))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, EvtDeviceAdd);
    return WdfDriverCreate(DriverObject, RegistryPath, WDF_NO_OBJECT_ATTRIBUTES,
                           &config, WDF_NO_HANDLE);
}

NTSTATUS
EvtDeviceAdd(_In_ WDFDRIVER Driver, _Inout_ PWDFDEVICE_INIT DeviceInit)
{
    UNREFERENCED_PARAMETER(Driver);

    WdfFdoInitSetFilter(DeviceInit);

    WDF_OBJECT_ATTRIBUTES reqAttr;
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&reqAttr, MM_REQUEST_CONTEXT);
    WdfDeviceInitSetRequestAttributes(DeviceInit, &reqAttr);

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
            if (NT_SUCCESS(WdfRegistryQueryULong(paramsKey, &valName, &val)))
            {
                ctx->EnableInjection = (val != 0);
            }
            WdfRegistryClose(paramsKey);
        }
    }

    ctx->ProductId = 0;
    {
        PDEVICE_OBJECT pdo = WdfDeviceWdmGetPhysicalDevice(device);
        if (pdo != NULL)
        {
            WCHAR hwIdBuf[256] = { 0 };
            ULONG retLen = 0;
            NTSTATUS pidStatus = IoGetDeviceProperty(
                pdo,
                DevicePropertyHardwareID,
                sizeof(hwIdBuf) - sizeof(WCHAR),
                hwIdBuf,
                &retLen);

            if (NT_SUCCESS(pidStatus) && retLen >= sizeof(WCHAR))
            {
                ULONG wcharCount = retLen / sizeof(WCHAR);
                for (ULONG i = 0; i + 8 <= wcharCount; i++)
                {
                    if (hwIdBuf[i]     == L'P' &&
                        hwIdBuf[i + 1] == L'I' &&
                        hwIdBuf[i + 2] == L'D' &&
                        hwIdBuf[i + 3] == L'&')
                    {
                        USHORT pid = 0;
                        for (ULONG j = i + 4; j < wcharCount && j < i + 8; j++)
                        {
                            WCHAR  c      = hwIdBuf[j];
                            USHORT nibble = 0;
                            if      (c >= L'0' && c <= L'9') { nibble = (USHORT)(c - L'0'); }
                            else if (c >= L'A' && c <= L'F') { nibble = (USHORT)(c - L'A' + 10); }
                            else if (c >= L'a' && c <= L'f') { nibble = (USHORT)(c - L'a' + 10); }
                            else { break; }
                            pid = (USHORT)((pid << 4) | nibble);
                        }
                        ctx->ProductId = pid;
                        break;
                    }
                }
            }
        }
        DbgPrint("MM: AddDevice ProductId=0x%04X EnableInjection=%d\n",
                 ctx->ProductId, ctx->EnableInjection);
    }

    WDF_TIMER_CONFIG timerCfg;
    WDF_TIMER_CONFIG_INIT_PERIODIC(&timerCfg, MmDiagTimerFunc, 1000);
    WDF_OBJECT_ATTRIBUTES timerAttr;
    WDF_OBJECT_ATTRIBUTES_INIT(&timerAttr);
    timerAttr.ParentObject = device;
    status = WdfTimerCreate(&timerCfg, &timerAttr, &ctx->DiagTimer);
    if (!NT_SUCCESS(status)) { return status; }

    WDF_WORKITEM_CONFIG wiCfg;
    WDF_WORKITEM_CONFIG_INIT(&wiCfg, MmDiagWorkItemFunc);
    WDF_OBJECT_ATTRIBUTES wiAttr;
    WDF_OBJECT_ATTRIBUTES_INIT(&wiAttr);
    wiAttr.ParentObject = device;
    status = WdfWorkItemCreate(&wiCfg, &wiAttr, &ctx->DiagWorkItem);
    if (!NT_SUCCESS(status)) { return status; }

    WdfTimerStart(ctx->DiagTimer, WDF_REL_TIMEOUT_IN_MS(1000));

    WDF_IO_QUEUE_CONFIG qCfg;
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&qCfg, WdfIoQueueDispatchParallel);
    qCfg.EvtIoDeviceControl         = EvtIoDeviceControl;
    qCfg.EvtIoInternalDeviceControl = EvtIoInternalDeviceControl;
    qCfg.EvtIoRead                  = EvtIoRead;
    qCfg.EvtIoDefault               = EvtIoDefault;

    WDFQUEUE queue;
    return WdfIoQueueCreate(device, &qCfg, WDF_NO_OBJECT_ATTRIBUTES, &queue);
}

VOID
EvtIoInternalDeviceControl(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request,
                            _In_ size_t OutputBufferLength, _In_ size_t InputBufferLength,
                            _In_ ULONG IoControlCode)
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    WDFDEVICE       device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT ctx    = GetDeviceContext(device);
    WDFIOTARGET     target = WdfDeviceGetIoTarget(device);

    if (IoControlCode == IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE &&
        ctx != NULL && ctx->EnableInjection)
    {
        ForwardSdpWithCompletion(Request, target, ctx);
        return;
    }

    if (IoControlCode == IOCTL_INTERNAL_BTH_SUBMIT_BRB &&
        ctx != NULL && ctx->EnableInjection)
    {
        PIRP irp = WdfRequestWdmGetIrp(Request);
        PIO_STACK_LOCATION sl = IoGetCurrentIrpStackLocation(irp);
        PUCHAR brb = (PUCHAR)sl->Parameters.Others.Argument1;

        if (brb != NULL)
        {
            USHORT type = 0;
            ULONG  brbLen = 0;
            RtlCopyMemory(&brbLen, brb + MM_BRB_LENGTH_OFFSET, sizeof(ULONG));
            RtlCopyMemory(&type, brb + MM_BRB_TYPE_OFFSET, sizeof(USHORT));

            if (type == (USHORT)BRB_L2CA_ACL_TRANSFER && brbLen >= MM_ACL_MIN_BRB_LEN)
            {
                ULONG flags = 0;
                RtlCopyMemory(&flags, brb + MM_ACL_FLAGS_OFFSET, sizeof(ULONG));
                if ((flags & ACL_TRANSFER_DIRECTION_IN) != 0)
                {
                    PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
                    reqCtx->Brb = brb;

                    WdfSpinLockAcquire(ctx->Lock);
                    ctx->AclInterceptCount++;
                    WdfSpinLockRelease(ctx->Lock);

                    WdfRequestFormatRequestUsingCurrentType(Request);
                    WdfRequestSetCompletionRoutine(Request, OnAclTransferComplete, ctx);
                    if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
                    {
                        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
                    }
                    return;
                }
            }
        }
    }

    ForwardPassthrough(Request, target);
}

VOID
EvtIoDeviceControl(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request,
                   _In_ size_t OutputBufferLength, _In_ size_t InputBufferLength,
                   _In_ ULONG IoControlCode)
{
    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    WDFDEVICE       device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT ctx    = GetDeviceContext(device);
    WDFIOTARGET     target = WdfDeviceGetIoTarget(device);

    if (IoControlCode == IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE &&
        ctx != NULL && ctx->EnableInjection)
    {
        ForwardSdpWithCompletion(Request, target, ctx);
        return;
    }

    ForwardPassthrough(Request, target);
}

VOID
EvtIoDefault(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request)
{
    ForwardPassthrough(Request, WdfDeviceGetIoTarget(WdfIoQueueGetDevice(Queue)));
}

VOID
EvtIoRead(_In_ WDFQUEUE Queue, _In_ WDFREQUEST Request, _In_ size_t Length)
{
    UNREFERENCED_PARAMETER(Length);

    WDFDEVICE       device = WdfIoQueueGetDevice(Queue);
    PDEVICE_CONTEXT ctx    = GetDeviceContext(device);
    WDFIOTARGET     target = WdfDeviceGetIoTarget(device);

    WdfRequestFormatRequestUsingCurrentType(Request);
    WdfRequestSetCompletionRoutine(Request, OnReadComplete, ctx);
    if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
    {
        WdfRequestComplete(Request, WdfRequestGetStatus(Request));
    }
}

VOID
OnAclTransferComplete(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target,
                      _In_ PWDF_REQUEST_COMPLETION_PARAMS Params, _In_ WDFCONTEXT Context)
{
    UNREFERENCED_PARAMETER(Target);

    PDEVICE_CONTEXT ctx    = (PDEVICE_CONTEXT)Context;
    NTSTATUS        status = Params->IoStatus.Status;
    PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
    PUCHAR brb = (reqCtx != NULL) ? (PUCHAR)reqCtx->Brb : NULL;

    if (NT_SUCCESS(status) && ctx != NULL && brb != NULL)
    {
        ULONG brbLen = 0;
        RtlCopyMemory(&brbLen, brb + MM_BRB_LENGTH_OFFSET, sizeof(ULONG));
        if (brbLen >= MM_ACL_MIN_BRB_LEN)
        {
            ULONG  bufSize = 0;
            PVOID  buffer  = NULL;
            PMDL   mdl     = NULL;
            RtlCopyMemory(&bufSize, brb + MM_ACL_BUFSIZE_OFFSET, sizeof(ULONG));
            RtlCopyMemory(&buffer,  brb + MM_ACL_BUFFER_OFFSET,  sizeof(PVOID));
            RtlCopyMemory(&mdl,     brb + MM_ACL_MDL_OFFSET,     sizeof(PMDL));

            PUCHAR payload = (PUCHAR)buffer;
            if (payload == NULL && mdl != NULL)
            {
                payload = (PUCHAR)MmGetSystemAddressForMdlSafe(mdl, NormalPagePriority);
            }

            if (payload != NULL && bufSize >= 6)
            {
                ULONG newLen = bufSize;
                __try
                {
                    if (TranslateAclHidReport(payload, bufSize, &newLen, ctx) &&
                        newLen > 0 && newLen <= bufSize)
                    {
                        RtlCopyMemory(brb + MM_ACL_BUFSIZE_OFFSET, &newLen, sizeof(ULONG));
                        WdfSpinLockAcquire(ctx->Lock);
                        ctx->AclTranslateCount++;
                        ctx->Rid12Count++;
                        WdfSpinLockRelease(ctx->Lock);
                    }
                }
                __except (EXCEPTION_EXECUTE_HANDLER)
                {
                    DbgPrint("MM: OnAclTransferComplete — buffer exception, passthrough\n");
                }
            }
        }
    }

    WdfRequestComplete(Request, status);
}

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
    if (!NT_SUCCESS(WdfRequestRetrieveOutputBuffer(Request, 1, &buf, &bufLen)) || buf == NULL)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    SIZE_T bytesRead = Params->IoStatus.Information;
    WdfSpinLockAcquire(ctx->Lock);
    ctx->HidReadCount++;
    if (bytesRead > 0 && bytesRead <= bufLen && (buf[0] == 0x12 || buf[0] == 0x27))
    {
        ctx->Rid12Count++;
    }
    WdfSpinLockRelease(ctx->Lock);

    __try
    {
        if (bytesRead >= 6 && (buf[0] == 0x12 || buf[0] == 0x27) &&
            (ctx->ProductId == 0 || ctx->ProductId == MM_PID_V3))
        {
            UCHAR  translated[MM_MOUSE_REPORT_LEN];
            ULONG  translatedLen = sizeof(translated);
            NTSTATUS ts = TranslateMouse2ToHid(buf, bytesRead, translated, &translatedLen, ctx);
            if (NT_SUCCESS(ts) && translatedLen == MM_MOUSE_REPORT_LEN &&
                bufLen >= MM_MOUSE_REPORT_LEN)
            {
                RtlCopyMemory(buf, translated, translatedLen);
                WdfRequestSetInformation(Request, translatedLen);
            }
        }
    }
    __except (EXCEPTION_EXECUTE_HANDLER)
    {
        DbgPrint("MM: OnReadComplete — buffer exception, passthrough\n");
    }

    WdfRequestComplete(Request, status);
}

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

    PVOID  buf         = NULL;
    size_t bufAllocLen = 0;
    if (!NT_SUCCESS(WdfRequestRetrieveOutputBuffer(Request, 1, &buf, &bufAllocLen)) ||
        buf == NULL)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    size_t sdpLen = Params->IoStatus.Information;
    if (sdpLen == 0 || sdpLen > bufAllocLen)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    WdfSpinLockAcquire(ctx->Lock);
    ctx->LastSdpBufSize = (ULONG)sdpLen;
    ULONG snapLen = (sdpLen < 64) ? (ULONG)sdpLen : 64;
    RtlCopyMemory(ctx->LastSdpBytes, buf, snapLen);
    if (snapLen < 64) { RtlZeroMemory(ctx->LastSdpBytes + snapLen, 64 - snapLen); }
    WdfSpinLockRelease(ctx->Lock);

    // This INF binds 0323 only. Still refuse to rewrite if PID is a known
    // other Magic Mouse (defense in depth — do not retarget 030D).
    if (ctx->ProductId != 0 && ctx->ProductId != MM_PID_V3)
    {
        WdfRequestComplete(Request, status);
        return;
    }

    ULONG    newLen      = (ULONG)sdpLen;
    NTSTATUS patchStatus = SdpRewrite_Process((PUCHAR)buf, (ULONG)sdpLen, &newLen);

    WdfSpinLockAcquire(ctx->Lock);
    ctx->LastPatchStatus = (ULONG)patchStatus;
    if (patchStatus == STATUS_SUCCESS)
    {
        ctx->SdpScanHits++;
        ctx->SdpPatchSuccess++;
    }
    else if (patchStatus == STATUS_MORE_PROCESSING_REQUIRED)
    {
        ctx->SdpScanHits++;
    }
    WdfSpinLockRelease(ctx->Lock);

    if (patchStatus == STATUS_SUCCESS && newLen != (ULONG)sdpLen)
    {
        WdfRequestSetInformation(Request, (ULONG_PTR)newLen);
    }

    WdfRequestComplete(Request, status);
}

VOID
MmDiagTimerFunc(_In_ WDFTIMER Timer)
{
    WDFDEVICE device = (WDFDEVICE)WdfTimerGetParentObject(Timer);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    if (ctx != NULL && ctx->DiagWorkItem != NULL)
    {
        WdfWorkItemEnqueue(ctx->DiagWorkItem);
    }
}

VOID
MmDiagWorkItemFunc(_In_ WDFWORKITEM WorkItem)
{
    WDFDEVICE device = (WDFDEVICE)WdfWorkItemGetParentObject(WorkItem);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    if (ctx == NULL) { return; }

    ULONG ictlCount, scanHits, patchOk, lastSize, lastStatus;
    ULONG hidReads, rid12, aclN, aclX;
    UCHAR lastBytes[64];

    WdfSpinLockAcquire(ctx->Lock);
    ictlCount  = ctx->IoctlInterceptCount;
    scanHits   = ctx->SdpScanHits;
    patchOk    = ctx->SdpPatchSuccess;
    lastSize   = ctx->LastSdpBufSize;
    lastStatus = ctx->LastPatchStatus;
    hidReads   = ctx->HidReadCount;
    rid12      = ctx->Rid12Count;
    aclN       = ctx->AclInterceptCount;
    aclX       = ctx->AclTranslateCount;
    RtlCopyMemory(lastBytes, ctx->LastSdpBytes, 64);
    WdfSpinLockRelease(ctx->Lock);

    UNICODE_STRING keyPath;
    RtlInitUnicodeString(&keyPath,
        L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\MagicMouseDriver\\Diag");
    OBJECT_ATTRIBUTES attr;
    InitializeObjectAttributes(&attr, &keyPath,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    HANDLE key  = NULL;
    ULONG  disp = 0;
    if (!NT_SUCCESS(ZwCreateKey(&key, KEY_WRITE, &attr, 0, NULL,
                                REG_OPTION_NON_VOLATILE, &disp)))
    {
        return;
    }

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
    SET_DWORD(L"Rid12Count",          rid12);
    SET_DWORD(L"AclInterceptCount",   aclN);
    SET_DWORD(L"AclTranslateCount",   aclX);

#undef SET_DWORD

    RtlInitUnicodeString(&n, L"LastSdpBytes");
    ZwSetValueKey(key, &n, 0, REG_BINARY, lastBytes, 64);
    ZwClose(key);
}
