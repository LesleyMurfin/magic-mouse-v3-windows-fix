#include "Driver.h"
#include "InputHandler.h"
#include "GestureEngine.h"
#include "AclTranslate.h"
#include <bthdef.h>
#include <bthddi.h>
#include <hidclass.h>

// BRB fields from WDK bthddi.h (BrbHeader / BrbL2caAclTransfer).
// Do not use 14393 byte offsets — layout drift writes HID into foreign pool.
//
// 2026-09-15: the kernel HID SetFeature-via-sibling-PDO path (local HID /
// device-interface-arrival GUIDs, IoRegisterPlugPlayNotification hook, its
// workitem, and the UNICODE substring matcher that fed it) was removed here.
// It shipped as 2.0.4.2, was installed live once, and took pointer AND scroll
// down with it - the self-issued IOCTL_HID_SET_FEATURE contends with the
// Bluetooth control channel this filter already tracks state for (STATUS.md,
// "Incident - 2026-09-08 morning"). MT recovery is handled in userspace by
// scripts/mm-auto-f1-watcher.ps1, which is proven on real reconnects and on
// boot. Retrieve the old code from git history if it is ever redesigned to
// route through MtControlHandle instead of an independent I/O target.

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

static VOID
MmInvalidateChannelStateLocked(_In_ PDEVICE_CONTEXT ctx)
{
    ctx->MtControlHandle = NULL;
    ctx->MtChannelHandle = NULL;
    ctx->MtEnableSent = FALSE;
    ctx->MtEnableTries = 0;
}

static VOID
MmInvalidateClosedChannelStateLocked(_In_ PDEVICE_CONTEXT ctx,
                                     _In_ PVOID ClosedHandle)
{
    if (ClosedHandle == NULL)
    {
        return;
    }

    if (ctx->MtControlHandle == ClosedHandle)
    {
        ctx->MtControlHandle = NULL;
        ctx->MtEnableSent = FALSE;
        ctx->MtEnableTries = 0;
    }
    if (ctx->MtChannelHandle == ClosedHandle)
    {
        ctx->MtChannelHandle = NULL;
    }
}

VOID
EvtDeviceContextCleanup(_In_ WDFOBJECT Object)
{
    PDEVICE_CONTEXT ctx = GetDeviceContext((WDFDEVICE)Object);
    if (ctx != NULL && ctx->Lock != NULL)
    {
        WdfSpinLockAcquire(ctx->Lock);
        MmInvalidateChannelStateLocked(ctx);
        WdfSpinLockRelease(ctx->Lock);
    }
}

NTSTATUS
DriverEntry(_In_ PDRIVER_OBJECT DriverObject, _In_ PUNICODE_STRING RegistryPath)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, EvtDeviceAdd);
    DbgPrint("MM: DriverEntry %s dest %s artifact %s\n",
             MM_FILE_VERSION_STR, MM_INF_SYS_NAME, MM_ARTIFACT_SYS_PATTERN);
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
    devAttr.EvtCleanupCallback = EvtDeviceContextCleanup;
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
    ctx->ScrollStep      = MM_SCROLL_STEP;
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

            // Scroll sensitivity tunable: higher = coarser detent = less
            // sensitive. Out-of-range values fall back to the proven default
            // rather than being honoured, so a bad registry write cannot
            // produce a notch-per-report flood or a dead wheel.
            ULONG stepVal = 0;
            RtlInitUnicodeString(&valName, L"ScrollStep");
            if (NT_SUCCESS(WdfRegistryQueryULong(paramsKey, &valName, &stepVal)) &&
                stepVal >= MM_SCROLL_STEP_MIN && stepVal <= MM_SCROLL_STEP_MAX)
            {
                ctx->ScrollStep = stepVal;
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

    // Closing a channel must always be observed, including when injection
    // is disabled, so teardown cannot leave a handle eligible for reuse.
    if (IoControlCode == IOCTL_INTERNAL_BTH_SUBMIT_BRB && ctx != NULL)
    {
        PIRP irp = WdfRequestWdmGetIrp(Request);
        PIO_STACK_LOCATION sl = IoGetCurrentIrpStackLocation(irp);
        PBRB pBrb = (PBRB)sl->Parameters.Others.Argument1;

        if (pBrb != NULL &&
            pBrb->BrbHeader.Type == BRB_L2CA_CLOSE_CHANNEL &&
            pBrb->BrbHeader.Length >= sizeof(struct _BRB_L2CA_CLOSE_CHANNEL))
        {
            PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
            reqCtx->Brb = pBrb;
            reqCtx->UsedScratch = FALSE;
            WdfRequestFormatRequestUsingCurrentType(Request);
            WdfRequestSetCompletionRoutine(Request, OnCloseChannelComplete, ctx);
            if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
            {
                WdfRequestComplete(Request, WdfRequestGetStatus(Request));
            }
            return;
        }
    }

    if (IoControlCode == IOCTL_INTERNAL_BTH_SUBMIT_BRB &&
        ctx != NULL && ctx->EnableInjection)
    {
        PIRP irp = WdfRequestWdmGetIrp(Request);
        PIO_STACK_LOCATION sl = IoGetCurrentIrpStackLocation(irp);
        PBRB pBrb = (PBRB)sl->Parameters.Others.Argument1;

        // Learn the HID control channel from BOTH directions of the open.
        //
        // BRB_L2CA_OPEN_CHANNEL is the HOST-initiated open (pnputil
        // /restart-device, boot, re-pair). BRB_L2CA_OPEN_CHANNEL_RESPONSE is
        // how a DEVICE-initiated reconnect arrives - the Apple mouse dropping
        // its link on idle and coming back on its own - and it was never
        // handled, so MtControlHandle stayed NULL for the entire life of that
        // connection. With it NULL the pass-through at the ACL intercept below
        // cannot fire, every control-channel read is processed by this filter,
        // and the GET_REPORT(Input,0x90) response is destroyed: measured on
        // hardware 2026-09-17, the wire carried A1 90 04 10 (16%) on every
        // probe while userspace read 90 00 00. Both BRB types share the
        // _BRB_L2CA_OPEN_CHANNEL layout, so one intercept serves both.
        if (pBrb != NULL &&
            (pBrb->BrbHeader.Type == BRB_L2CA_OPEN_CHANNEL ||
             pBrb->BrbHeader.Type == BRB_L2CA_OPEN_CHANNEL_RESPONSE) &&
            pBrb->BrbHeader.Length >= sizeof(struct _BRB_L2CA_OPEN_CHANNEL) &&
            pBrb->BrbL2caOpenChannel.Psm == MM_HID_CONTROL_PSM)
        {
            PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
            reqCtx->Brb = pBrb;
            reqCtx->UsedScratch = FALSE;
            WdfRequestFormatRequestUsingCurrentType(Request);
            WdfRequestSetCompletionRoutine(Request, OnOpenChannelComplete, ctx);
            if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
            {
                WdfRequestComplete(Request, WdfRequestGetStatus(Request));
            }
            return;
        }


        if (pBrb != NULL &&
            pBrb->BrbHeader.Type == BRB_L2CA_ACL_TRANSFER &&
            pBrb->BrbHeader.Length >= sizeof(BRB_L2CA_ACL_TRANSFER) &&
            (pBrb->BrbL2caAclTransfer.TransferFlags & ACL_TRANSFER_DIRECTION_IN) == 0)
        {
            ULONG n = pBrb->BrbL2caAclTransfer.BufferSize;
            ULONG outFlags = pBrb->BrbL2caAclTransfer.TransferFlags;
            PUCHAR origBuf = (PUCHAR)pBrb->BrbL2caAclTransfer.Buffer;
            UCHAR origHdr = 0;

            if (origBuf == NULL && pBrb->BrbL2caAclTransfer.BufferMDL != NULL)
            {
                origBuf = (PUCHAR)MmGetSystemAddressForMdlSafe(
                    pBrb->BrbL2caAclTransfer.BufferMDL, NormalPagePriority);
            }
            if (origBuf != NULL && n >= 1)
            {
                origHdr = origBuf[0];
            }

            WdfSpinLockAcquire(ctx->Lock);
            ctx->AclOutCount++;
            ctx->LastOutBufferSize = n;
            ctx->LastOutFlags = outFlags;
            ctx->LastOutHdr = (ULONG)origHdr;
            WdfSpinLockRelease(ctx->Lock);

            ForwardPassthrough(Request, target);
            return;
        }

        if (pBrb != NULL &&
            pBrb->BrbHeader.Type == BRB_L2CA_ACL_TRANSFER &&
            pBrb->BrbHeader.Length >= sizeof(BRB_L2CA_ACL_TRANSFER) &&
            (pBrb->BrbL2caAclTransfer.TransferFlags & ACL_TRANSFER_DIRECTION_IN) != 0)
        {
            PVOID ctlHandle;
            WdfSpinLockAcquire(ctx->Lock);
            ctlHandle = ctx->MtControlHandle;
            WdfSpinLockRelease(ctx->Lock);
            if (ctlHandle != NULL &&
                pBrb->BrbL2caAclTransfer.ChannelHandle == ctlHandle)
            {
                ForwardPassthrough(Request, target);
                return;
            }

            PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
            reqCtx->Brb = pBrb;
            reqCtx->UsedScratch = FALSE;
            reqCtx->OrigBuffer = NULL;
            reqCtx->OrigMdl = NULL;
            reqCtx->OrigBufferSize = 0;
            reqCtx->OrigRemainingBufferSize = 0;
            reqCtx->OrigFlags = 0;

            BOOLEAN sdpOk = FALSE;
            WdfSpinLockAcquire(ctx->Lock);
            ctx->AclInterceptCount++;
            sdpOk = (ctx->SdpPatchSuccess != 0);
            ctx->MtChannelHandle = pBrb->BrbL2caAclTransfer.ChannelHandle;
            RtlCopyMemory(ctx->MtBtAddress,
                          &pBrb->BrbL2caAclTransfer.BtAddress,
                          sizeof(ctx->MtBtAddress));
            ctx->LastInBrbLength = pBrb->BrbHeader.Length;
            ctx->LastInFlags = pBrb->BrbL2caAclTransfer.TransferFlags;
            WdfSpinLockRelease(ctx->Lock);

            // Divert to the scratch buffer only when the caller's buffer is a
            // whole input report. HidBth reads the HID control channel
            // header-first - BufferSize 1 for the 0xA1 DATA byte - so a
            // scratch read of MM_ACL_MAX_PARSE with ACL_SHORT_TRANSFER_OK
            // consumes the entire GET_REPORT response while only 1 byte can
            // be copied back to the caller. That is why Input 0x90 on COL02
            // returned 90 00 00 with STATUS_SUCCESS: the percent arrived off
            // the air and was discarded here. Interrupt-channel reports are
            // posted with a 9-byte buffer, so the multitouch read this filter
            // exists for is still diverted and translated, and
            // OnAclTransferComplete already refuses to translate below
            // origCap >= MM_MOUSE_REPORT_LEN - a shorter diversion could only
            // ever swallow data, never produce a wheel report.
            if (sdpOk &&
                pBrb->BrbL2caAclTransfer.BufferSize >= MM_MOUSE_REPORT_LEN &&
                pBrb->BrbL2caAclTransfer.BufferSize < MM_ACL_MAX_PARSE)
            {
                reqCtx->OrigBuffer = pBrb->BrbL2caAclTransfer.Buffer;
                reqCtx->OrigMdl = pBrb->BrbL2caAclTransfer.BufferMDL;
                reqCtx->OrigBufferSize = pBrb->BrbL2caAclTransfer.BufferSize;
                reqCtx->OrigRemainingBufferSize =
                    pBrb->BrbL2caAclTransfer.RemainingBufferSize;
                reqCtx->OrigFlags = pBrb->BrbL2caAclTransfer.TransferFlags;
                reqCtx->UsedScratch = TRUE;
                pBrb->BrbL2caAclTransfer.Buffer = reqCtx->Scratch;
                pBrb->BrbL2caAclTransfer.BufferMDL = NULL;
                pBrb->BrbL2caAclTransfer.BufferSize = MM_ACL_MAX_PARSE;
                pBrb->BrbL2caAclTransfer.TransferFlags |= ACL_SHORT_TRANSFER_OK;
            }

            WdfRequestFormatRequestUsingCurrentType(Request);
            WdfRequestSetCompletionRoutine(Request, OnAclTransferComplete, ctx);
            if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS))
            {
                if (reqCtx->UsedScratch)
                {
                    pBrb->BrbL2caAclTransfer.Buffer = reqCtx->OrigBuffer;
                    pBrb->BrbL2caAclTransfer.BufferMDL = reqCtx->OrigMdl;
                    pBrb->BrbL2caAclTransfer.BufferSize = reqCtx->OrigBufferSize;
                    pBrb->BrbL2caAclTransfer.RemainingBufferSize =
                        reqCtx->OrigRemainingBufferSize;
                    pBrb->BrbL2caAclTransfer.TransferFlags = reqCtx->OrigFlags;
                    reqCtx->UsedScratch = FALSE;
                }
                WdfRequestComplete(Request, WdfRequestGetStatus(Request));
            }
            return;
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
    PBRB pBrb = (reqCtx != NULL) ? (PBRB)reqCtx->Brb : NULL;

    if (pBrb != NULL && reqCtx != NULL && reqCtx->UsedScratch)
    {
        ULONG received = pBrb->BrbL2caAclTransfer.BufferSize;
        PUCHAR scratch = reqCtx->Scratch;

        pBrb->BrbL2caAclTransfer.Buffer = reqCtx->OrigBuffer;
        pBrb->BrbL2caAclTransfer.BufferMDL = reqCtx->OrigMdl;
        pBrb->BrbL2caAclTransfer.TransferFlags = reqCtx->OrigFlags;
        pBrb->BrbL2caAclTransfer.BufferSize = reqCtx->OrigBufferSize;
        pBrb->BrbL2caAclTransfer.RemainingBufferSize = reqCtx->OrigRemainingBufferSize;
        reqCtx->UsedScratch = FALSE;

        ULONG origCap = reqCtx->OrigBufferSize;
        PUCHAR orig = (PUCHAR)reqCtx->OrigBuffer;
        if (orig == NULL && reqCtx->OrigMdl != NULL)
        {
            orig = (PUCHAR)MmGetSystemAddressForMdlSafe(reqCtx->OrigMdl, NormalPagePriority);
            origCap = MmGetMdlByteCount(reqCtx->OrigMdl);
        }

        if (ctx != NULL)
        {
            ULONG snap = received;
            if (snap > 16) { snap = 16; }
            WdfSpinLockAcquire(ctx->Lock);
            ctx->LastAclReceived = received;
            ctx->LastAclCapacity = origCap;
            RtlZeroMemory(ctx->LastAclBytes, sizeof(ctx->LastAclBytes));
            if (scratch != NULL && snap > 0)
            {
                RtlCopyMemory(ctx->LastAclBytes, scratch, snap);
            }
            WdfSpinLockRelease(ctx->Lock);
        }

        BOOLEAN sdpOk = FALSE;
        if (ctx != NULL)
        {
            WdfSpinLockAcquire(ctx->Lock);
            sdpOk = (ctx->SdpPatchSuccess != 0);
            WdfSpinLockRelease(ctx->Lock);
        }

        if (NT_SUCCESS(status) && orig != NULL && origCap >= 1 && received >= 1)
        {
            ULONG newLen = 0;
            BOOLEAN wrote = FALSE;
            if (sdpOk && origCap >= MM_MOUSE_REPORT_LEN)
            {
                __try
                {
                    if (TranslateAclHidReport(scratch, received, MM_ACL_MAX_PARSE,
                                              &newLen, ctx) &&
                        newLen > 0 && newLen <= origCap)
                    {
                        RtlCopyMemory(orig, scratch, newLen);
                        pBrb->BrbL2caAclTransfer.BufferSize = newLen;
                        wrote = TRUE;
                        if (ctx != NULL)
                        {
                            WdfSpinLockAcquire(ctx->Lock);
                            ctx->AclTranslateCount++;
                            ctx->Rid12Count++;
                            WdfSpinLockRelease(ctx->Lock);
                        }
                    }
                }
                __except (EXCEPTION_EXECUTE_HANDLER)
                {
                    DbgPrint("MM: ACL scratch translate exception, passthrough\n");
                }
            }
            if (!wrote)
            {
                ULONG pass = received;
                if (pass > origCap) { pass = origCap; }
                __try
                {
                    RtlCopyMemory(orig, scratch, pass);
                    pBrb->BrbL2caAclTransfer.BufferSize = pass;
                }
                __except (EXCEPTION_EXECUTE_HANDLER)
                {
                    pBrb->BrbL2caAclTransfer.BufferSize = reqCtx->OrigBufferSize;
                }
            }
        }
    }
    else if (NT_SUCCESS(status) && ctx != NULL && pBrb != NULL &&
             pBrb->BrbHeader.Type == BRB_L2CA_ACL_TRANSFER &&
             pBrb->BrbHeader.Length >= sizeof(BRB_L2CA_ACL_TRANSFER))
    {
        BOOLEAN sdpOk = FALSE;
        WdfSpinLockAcquire(ctx->Lock);
        sdpOk = (ctx->SdpPatchSuccess != 0);
        WdfSpinLockRelease(ctx->Lock);

        if (sdpOk)
        {
            ULONG  bufSize = pBrb->BrbL2caAclTransfer.BufferSize;
            PVOID  buffer  = pBrb->BrbL2caAclTransfer.Buffer;
            PMDL   mdl     = pBrb->BrbL2caAclTransfer.BufferMDL;
            PUCHAR payload = (PUCHAR)buffer;
            if (payload == NULL && mdl != NULL)
            {
                payload = (PUCHAR)MmGetSystemAddressForMdlSafe(mdl, NormalPagePriority);
            }
            ULONG capacity = 0;
            if (mdl != NULL)
            {
                capacity = MmGetMdlByteCount(mdl);
            }
            else if (payload != NULL)
            {
                capacity = bufSize + pBrb->BrbL2caAclTransfer.RemainingBufferSize;
            }
            WdfSpinLockAcquire(ctx->Lock);
            ctx->LastAclReceived = bufSize;
            ctx->LastAclCapacity = capacity;
            WdfSpinLockRelease(ctx->Lock);
            if (payload != NULL && bufSize >= 1 && capacity >= 8)
            {
                ULONG newLen = bufSize;
                __try
                {
                    if (TranslateAclHidReport(payload, bufSize, capacity, &newLen, ctx) &&
                        newLen > 0 && newLen <= 256 && newLen <= capacity)
                    {
                        pBrb->BrbL2caAclTransfer.BufferSize = newLen;
                        WdfSpinLockAcquire(ctx->Lock);
                        ctx->AclTranslateCount++;
                        ctx->Rid12Count++;
                        WdfSpinLockRelease(ctx->Lock);
                    }
                }
                __except (EXCEPTION_EXECUTE_HANDLER)
                {
                    DbgPrint("MM: OnAclTransferComplete buffer exception, passthrough\n");
                }
            }
        }
    }

    WdfRequestComplete(Request, status);
}

VOID
OnOpenChannelComplete(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target,
                      _In_ PWDF_REQUEST_COMPLETION_PARAMS Params, _In_ WDFCONTEXT Context)
{
    UNREFERENCED_PARAMETER(Target);

    PDEVICE_CONTEXT ctx = (PDEVICE_CONTEXT)Context;
    NTSTATUS status = Params->IoStatus.Status;
    PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
    PBRB pBrb = (reqCtx != NULL) ? (PBRB)reqCtx->Brb : NULL;

    if (NT_SUCCESS(status) && ctx != NULL && pBrb != NULL &&
        (pBrb->BrbHeader.Type == BRB_L2CA_OPEN_CHANNEL ||
         pBrb->BrbHeader.Type == BRB_L2CA_OPEN_CHANNEL_RESPONSE) &&
        pBrb->BrbL2caOpenChannel.Psm == MM_HID_CONTROL_PSM &&
        pBrb->BrbL2caOpenChannel.ChannelHandle != NULL)
    {
        WdfSpinLockAcquire(ctx->Lock);
        ctx->MtControlHandle = pBrb->BrbL2caOpenChannel.ChannelHandle;
        RtlCopyMemory(ctx->MtBtAddress,
                      &pBrb->BrbL2caOpenChannel.BtAddress,
                      sizeof(ctx->MtBtAddress));
        ctx->MtEnableTries = 0;
        ctx->MtEnableSent = FALSE;
        WdfSpinLockRelease(ctx->Lock);
        if (ctx->DiagWorkItem != NULL)
        {
            WdfWorkItemEnqueue(ctx->DiagWorkItem);
        }
    }

    WdfRequestComplete(Request, status);
}

VOID
OnCloseChannelComplete(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target,
                       _In_ PWDF_REQUEST_COMPLETION_PARAMS Params, _In_ WDFCONTEXT Context)
{
    UNREFERENCED_PARAMETER(Target);

    PDEVICE_CONTEXT ctx = (PDEVICE_CONTEXT)Context;
    NTSTATUS status = Params->IoStatus.Status;
    PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
    PBRB pBrb = (reqCtx != NULL) ? (PBRB)reqCtx->Brb : NULL;

    if (NT_SUCCESS(status) && ctx != NULL && pBrb != NULL &&
        pBrb->BrbHeader.Type == BRB_L2CA_CLOSE_CHANNEL &&
        pBrb->BrbHeader.Length >= sizeof(struct _BRB_L2CA_CLOSE_CHANNEL))
    {
        PVOID closedHandle = pBrb->BrbL2caCloseChannel.ChannelHandle;
        WdfSpinLockAcquire(ctx->Lock);
        MmInvalidateClosedChannelStateLocked(ctx, closedHandle);
        WdfSpinLockRelease(ctx->Lock);
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
    BOOLEAN sdpOk = FALSE;
    WdfSpinLockAcquire(ctx->Lock);
    ctx->HidReadCount++;
    if (bytesRead > 0 && bytesRead <= bufLen && (buf[0] == 0x12 || buf[0] == 0x27))
    {
        ctx->Rid12Count++;
    }
    sdpOk = (ctx->SdpPatchSuccess != 0);
    WdfSpinLockRelease(ctx->Lock);

    __try
    {
        // Same Event 41 coupling as ACL: never grow 6→8 unless hidclass
        // bound the injected 0x12+Wheel descriptor. bufLen is IRP
        // allocation (proven capacity); bytesRead is used length.
        // 0x90 battery Input is passed through. 0x12 stays 0x12.
        if (sdpOk &&
            bytesRead >= 6 && (buf[0] == 0x12 || buf[0] == 0x27) &&
            (ctx->ProductId == 0 || ctx->ProductId == MM_PID_V3) &&
            bufLen >= MM_MOUSE_REPORT_LEN)
        {
            UCHAR  translated[MM_MOUSE_REPORT_LEN];
            ULONG  translatedLen = sizeof(translated);
            NTSTATUS ts = TranslateMouse2ToHid(buf, bytesRead, translated, &translatedLen, ctx);
            if (NT_SUCCESS(ts) && translatedLen == MM_MOUSE_REPORT_LEN &&
                translatedLen <= bufLen)
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
    NTSTATUS patchStatus = SdpRewrite_Process((PUCHAR)buf, (ULONG)sdpLen,
                                              (ULONG)bufAllocLen, &newLen);

    WdfSpinLockAcquire(ctx->Lock);
    ctx->LastPatchStatus = (ULONG)patchStatus;
    if (patchStatus == STATUS_SUCCESS)
    {
        ctx->SdpScanHits++;
        ctx->SdpPatchSuccess++;
    }
    else if (patchStatus == STATUS_MORE_PROCESSING_REQUIRED ||
             patchStatus == STATUS_BUFFER_TOO_SMALL)
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

// HidBth SET_REPORT BufferSize was 66. Third-party OUT size 4 was 0xC0000206.
// Do not rewrite 0x55. Do not put 0xF1 in the HID descriptor.
#define MM_MT_OUT_LEN  66
#define MM_BRB_WAIT_MS  5000

static NTSTATUS
MmSubmitBrb(_In_ PDEVICE_OBJECT TargetDev, _In_ PBRB Brb)
{
    KEVENT event;
    IO_STATUS_BLOCK iosb;
    PIRP irp;
    NTSTATUS status;

    KeInitializeEvent(&event, NotificationEvent, FALSE);
    RtlZeroMemory(&iosb, sizeof(iosb));
    irp = IoBuildDeviceIoControlRequest(
        IOCTL_INTERNAL_BTH_SUBMIT_BRB,
        TargetDev,
        NULL,
        0,
        NULL,
        0,
        TRUE,
        &event,
        &iosb);
    if (irp == NULL)
    {
        return STATUS_INSUFFICIENT_RESOURCES;
    }
    IoGetNextIrpStackLocation(irp)->Parameters.Others.Argument1 = Brb;
    status = IoCallDriver(TargetDev, irp);
    if (status == STATUS_PENDING)
    {
        LARGE_INTEGER timeout;
        timeout.QuadPart = -((LONGLONG)MM_BRB_WAIT_MS * 10 * 1000);

        // Do not let a transport that never completes pin the caller's
        // stack packet and BRB indefinitely.  Once cancellation is issued,
        // the completion event must be observed before either is released.
        if (KeWaitForSingleObject(&event, Executive, KernelMode, FALSE,
                                  &timeout) == STATUS_TIMEOUT)
        {
            IoCancelIrp(irp);
            KeWaitForSingleObject(&event, Executive, KernelMode, FALSE, NULL);
        }
        status = iosb.Status;
    }
    return status;
}

static VOID
MmSendMtEnable(_In_ WDFDEVICE Device, _In_ PDEVICE_CONTEXT ctx)
{
    BOOLEAN sdpOk;
    BOOLEAN sent;
    ULONG tries;
    UCHAR btAddr[8];
    UCHAR pkt[MM_MT_OUT_LEN];
    NTSTATUS status;
    PBRB brb;
    WDFIOTARGET ioTarget;
    PDEVICE_OBJECT targetDev;
    PVOID ctlHandle;

    WdfSpinLockAcquire(ctx->Lock);
    sdpOk = (ctx->SdpPatchSuccess != 0);
    sent  = ctx->MtEnableSent;
    tries = ctx->MtEnableTries;
    ctlHandle = ctx->MtControlHandle;
    RtlCopyMemory(btAddr, ctx->MtBtAddress, sizeof(btAddr));
    WdfSpinLockRelease(ctx->Lock);

    if (!sdpOk || ctlHandle == NULL || sent || tries >= 3)
    {
        return;
    }

    RtlZeroMemory(pkt, sizeof(pkt));
    pkt[0] = 0x53;
    pkt[1] = 0xF1;
    pkt[2] = 0x02;
    pkt[3] = 0x01;

    WdfSpinLockAcquire(ctx->Lock);
    ctx->MtEnableTries++;
    tries = ctx->MtEnableTries;
    RtlCopyMemory(ctx->MtPkt, pkt, sizeof(ctx->MtPkt));
    WdfSpinLockRelease(ctx->Lock);

    status = STATUS_INSUFFICIENT_RESOURCES;
    ioTarget = WdfDeviceGetIoTarget(Device);
    targetDev = (ioTarget != NULL) ?
        WdfIoTargetWdmGetTargetDeviceObject(ioTarget) : NULL;
    brb = (PBRB)ExAllocatePool2(POOL_FLAG_NON_PAGED, sizeof(BRB), MM_POOL_TAG);
    if (targetDev != NULL && brb != NULL)
    {
        RtlZeroMemory(brb, sizeof(BRB));
        brb->BrbHeader.Length = sizeof(BRB_L2CA_ACL_TRANSFER);
        brb->BrbHeader.Type = (USHORT)BRB_L2CA_ACL_TRANSFER;
        RtlCopyMemory(&brb->BrbL2caAclTransfer.BtAddress, btAddr, sizeof(btAddr));
        brb->BrbL2caAclTransfer.ChannelHandle = ctlHandle;
        brb->BrbL2caAclTransfer.TransferFlags = ACL_TRANSFER_DIRECTION_OUT;
        brb->BrbL2caAclTransfer.BufferSize = MM_MT_OUT_LEN;
        brb->BrbL2caAclTransfer.Buffer = pkt;
        brb->BrbL2caAclTransfer.BufferMDL = NULL;
        status = MmSubmitBrb(targetDev, brb);
    }
    if (brb != NULL)
    {
        ExFreePoolWithTag(brb, MM_POOL_TAG);
    }

    WdfSpinLockAcquire(ctx->Lock);
    ctx->MtEnableStatus = (ULONG)status;
    if (NT_SUCCESS(status))
    {
        ctx->MtEnableSent = TRUE;
    }
    WdfSpinLockRelease(ctx->Lock);

    DbgPrint("MM: MmSendMtEnable 66-byte F1 status=0x%08X tries=%lu\n",
             (ULONG)status, tries);
}

static BOOLEAN
MmDiagValueMatches(_In_ HANDLE Key, _In_z_ PCWSTR Name, _In_ ULONG Type,
                   _In_reads_bytes_(DataSize) PVOID Data, _In_ ULONG DataSize)
{
    union
    {
        KEY_VALUE_PARTIAL_INFORMATION Info;
        UCHAR Buffer[FIELD_OFFSET(KEY_VALUE_PARTIAL_INFORMATION, Data) + 64];
    } valueStorage;
    PKEY_VALUE_PARTIAL_INFORMATION valueInfo = &valueStorage.Info;
    ULONG resultLength = 0;
    UNICODE_STRING valueName;

    if (DataSize > 64)
    {
        return FALSE;
    }

    RtlInitUnicodeString(&valueName, Name);
    if (!NT_SUCCESS(ZwQueryValueKey(Key, &valueName,
                                    KeyValuePartialInformation,
                                    valueInfo, sizeof(valueStorage),
                                    &resultLength)) ||
        valueInfo->Type != Type ||
        valueInfo->DataLength != DataSize)
    {
        return FALSE;
    }

    return (RtlCompareMemory(valueInfo->Data, Data, DataSize) == DataSize);
}

static VOID
MmDiagSetValueIfChanged(_In_ HANDLE Key, _In_z_ PCWSTR Name, _In_ ULONG Type,
                        _In_reads_bytes_(DataSize) PVOID Data, _In_ ULONG DataSize)
{
    UNICODE_STRING valueName;

    if (MmDiagValueMatches(Key, Name, Type, Data, DataSize))
    {
        return;
    }

    RtlInitUnicodeString(&valueName, Name);
    ZwSetValueKey(Key, &valueName, 0, Type, Data, DataSize);
}


VOID
MmDiagWorkItemFunc(_In_ WDFWORKITEM WorkItem)
{
    WDFDEVICE device = (WDFDEVICE)WdfWorkItemGetParentObject(WorkItem);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    if (ctx == NULL) { return; }
    ULONG ictlCount, scanHits, patchOk, lastSize, lastStatus;
    ULONG hidReads, rid12, aclN, aclX, lastAclR, lastAclC;
    ULONG mtStatus, mtTries, lastInLen, lastInFl, aclOut, lastOutSz, lastOutFl, lastOutHdr;
    ULONG scrollStep, scrollTravel, scrollNotches;
    UCHAR lastBytes[64];
    UCHAR lastAclBytes[16];

    MmSendMtEnable(device, ctx);

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
    lastAclR   = ctx->LastAclReceived;
    lastAclC   = ctx->LastAclCapacity;
    lastInLen  = ctx->LastInBrbLength;
    lastInFl   = ctx->LastInFlags;
    aclOut     = ctx->AclOutCount;
    lastOutSz  = ctx->LastOutBufferSize;
    lastOutFl  = ctx->LastOutFlags;
    lastOutHdr = ctx->LastOutHdr;
    mtStatus   = ctx->MtEnableStatus;
    mtTries    = ctx->MtEnableTries;
    scrollStep = ctx->ScrollStep;
    scrollTravel = ctx->ScrollTravelUnits;
    scrollNotches = ctx->ScrollNotchCount;
    RtlCopyMemory(lastBytes, ctx->LastSdpBytes, 64);
    RtlCopyMemory(lastAclBytes, ctx->LastAclBytes, 16);
    WdfSpinLockRelease(ctx->Lock);

    UNICODE_STRING keyPath;
    RtlInitUnicodeString(&keyPath,
        L"\\Registry\\Machine\\SYSTEM\\CurrentControlSet\\Services\\MagicMouseDriver204Scroll\\Diag");
    OBJECT_ATTRIBUTES attr;
    InitializeObjectAttributes(&attr, &keyPath,
                               OBJ_CASE_INSENSITIVE | OBJ_KERNEL_HANDLE, NULL, NULL);
    HANDLE key  = NULL;
    ULONG  disp = 0;
    if (!NT_SUCCESS(ZwCreateKey(&key,
                                KEY_WRITE | KEY_QUERY_VALUE,
                                &attr, 0, NULL, REG_OPTION_NON_VOLATILE, &disp)))
    {
        return;
    }

    MmDiagSetValueIfChanged(key, L"IoctlInterceptCount",
                            REG_DWORD, &ictlCount, sizeof(ictlCount));
    MmDiagSetValueIfChanged(key, L"SdpScanHits",
                            REG_DWORD, &scanHits, sizeof(scanHits));
    MmDiagSetValueIfChanged(key, L"SdpPatchSuccess",
                            REG_DWORD, &patchOk, sizeof(patchOk));
    MmDiagSetValueIfChanged(key, L"LastSdpBufSize",
                            REG_DWORD, &lastSize, sizeof(lastSize));
    MmDiagSetValueIfChanged(key, L"LastPatchStatusHex",
                            REG_DWORD, &lastStatus, sizeof(lastStatus));
    MmDiagSetValueIfChanged(key, L"HidReadCount",
                            REG_DWORD, &hidReads, sizeof(hidReads));
    MmDiagSetValueIfChanged(key, L"Rid12Count",
                            REG_DWORD, &rid12, sizeof(rid12));
    MmDiagSetValueIfChanged(key, L"AclInterceptCount",
                            REG_DWORD, &aclN, sizeof(aclN));
    MmDiagSetValueIfChanged(key, L"AclTranslateCount",
                            REG_DWORD, &aclX, sizeof(aclX));
    MmDiagSetValueIfChanged(key, L"ScrollTravelUnits",
                            REG_DWORD, &scrollTravel, sizeof(scrollTravel));
    MmDiagSetValueIfChanged(key, L"ScrollNotchCount",
                            REG_DWORD, &scrollNotches, sizeof(scrollNotches));
    MmDiagSetValueIfChanged(key, L"LastAclReceived",
                            REG_DWORD, &lastAclR, sizeof(lastAclR));
    MmDiagSetValueIfChanged(key, L"LastAclCapacity",
                            REG_DWORD, &lastAclC, sizeof(lastAclC));
    MmDiagSetValueIfChanged(key, L"MtEnableStatus",
                            REG_DWORD, &mtStatus, sizeof(mtStatus));
    MmDiagSetValueIfChanged(key, L"MtEnableTries",
                            REG_DWORD, &mtTries, sizeof(mtTries));
    MmDiagSetValueIfChanged(key, L"LastInBrbLength",
                            REG_DWORD, &lastInLen, sizeof(lastInLen));
    MmDiagSetValueIfChanged(key, L"LastInFlags",
                            REG_DWORD, &lastInFl, sizeof(lastInFl));
    MmDiagSetValueIfChanged(key, L"AclOutCount",
                            REG_DWORD, &aclOut, sizeof(aclOut));
    MmDiagSetValueIfChanged(key, L"LastOutBufferSize",
                            REG_DWORD, &lastOutSz, sizeof(lastOutSz));
    MmDiagSetValueIfChanged(key, L"LastOutFlags",
                            REG_DWORD, &lastOutFl, sizeof(lastOutFl));
    MmDiagSetValueIfChanged(key, L"LastOutHdr",
                            REG_DWORD, &lastOutHdr, sizeof(lastOutHdr));
    // Echoes the tunable actually in force, so a tune can be confirmed
    // without guessing whether the registry write was picked up.
    MmDiagSetValueIfChanged(key, L"ScrollStep",
                            REG_DWORD, &scrollStep, sizeof(scrollStep));

    MmDiagSetValueIfChanged(key, L"LastSdpBytes",
                            REG_BINARY, lastBytes, sizeof(lastBytes));
    MmDiagSetValueIfChanged(key, L"LastAclBytes",
                            REG_BINARY, lastAclBytes, sizeof(lastAclBytes));
    ZwClose(key);
}

