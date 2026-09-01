#include "Driver.h"
#include "InputHandler.h"
#include "GestureEngine.h"
#include "AclTranslate.h"
#include <bthdef.h>
#include <bthddi.h>

// BRB fields from WDK bthddi.h (BrbHeader / BrbL2caAclTransfer).
// Do not use 14393 byte offsets — layout drift writes HID into foreign pool.

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
        PBRB pBrb = (PBRB)sl->Parameters.Others.Argument1;

        if (pBrb != NULL &&
            pBrb->BrbHeader.Type == BRB_L2CA_OPEN_CHANNEL &&
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

            if (sdpOk &&
                pBrb->BrbL2caAclTransfer.BufferSize > 0 &&
                pBrb->BrbL2caAclTransfer.BufferSize < MM_ACL_MAX_PARSE)
            {
                reqCtx->OrigBuffer = pBrb->BrbL2caAclTransfer.Buffer;
                reqCtx->OrigMdl = pBrb->BrbL2caAclTransfer.BufferMDL;
                reqCtx->OrigBufferSize = pBrb->BrbL2caAclTransfer.BufferSize;
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
        pBrb->BrbHeader.Type == BRB_L2CA_OPEN_CHANNEL &&
        pBrb->BrbL2caOpenChannel.Psm == MM_HID_CONTROL_PSM &&
        pBrb->BrbL2caOpenChannel.ChannelHandle != NULL)
    {
        WdfSpinLockAcquire(ctx->Lock);
        ctx->MtControlHandle = pBrb->BrbL2caOpenChannel.ChannelHandle;
        RtlCopyMemory(ctx->MtBtAddress,
                      &pBrb->BrbL2caOpenChannel.BtAddress,
                      sizeof(ctx->MtBtAddress));
        ctx->MtEnableTries = 0;
        ctx->MtControlOutSeen = 0;
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
OnAclOutComplete(_In_ WDFREQUEST Request, _In_ WDFIOTARGET Target,
                 _In_ PWDF_REQUEST_COMPLETION_PARAMS Params, _In_ WDFCONTEXT Context)
{
    UNREFERENCED_PARAMETER(Target);

    PDEVICE_CONTEXT ctx = (PDEVICE_CONTEXT)Context;
    NTSTATUS status = Params->IoStatus.Status;
    PMM_REQUEST_CONTEXT reqCtx = GetRequestContext(Request);
    PBRB pBrb = (reqCtx != NULL) ? (PBRB)reqCtx->Brb : NULL;

    if (pBrb != NULL && reqCtx != NULL && reqCtx->UsedScratch)
    {
        pBrb->BrbL2caAclTransfer.Buffer = reqCtx->OrigBuffer;
        pBrb->BrbL2caAclTransfer.BufferMDL = reqCtx->OrigMdl;
        pBrb->BrbL2caAclTransfer.BufferSize = reqCtx->OrigBufferSize;
        pBrb->BrbL2caAclTransfer.TransferFlags = reqCtx->OrigFlags;
        reqCtx->UsedScratch = FALSE;
    }

    if (ctx != NULL)
    {
        WdfSpinLockAcquire(ctx->Lock);
        ctx->MtEnableStatus = (ULONG)status;
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
        KeWaitForSingleObject(&event, Executive, KernelMode, FALSE, NULL);
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

VOID
MmDiagWorkItemFunc(_In_ WDFWORKITEM WorkItem)
{
    WDFDEVICE device = (WDFDEVICE)WdfWorkItemGetParentObject(WorkItem);
    PDEVICE_CONTEXT ctx = GetDeviceContext(device);
    if (ctx == NULL) { return; }
    ULONG ictlCount, scanHits, patchOk, lastSize, lastStatus;
    ULONG hidReads, rid12, aclN, aclX, lastAclR, lastAclC;
    ULONG mtStatus, mtTries, lastInLen, lastInFl, aclOut, lastOutSz, lastOutFl, lastOutHdr;
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
    SET_DWORD(L"LastAclReceived",     lastAclR);
    SET_DWORD(L"LastAclCapacity",     lastAclC);
    SET_DWORD(L"MtEnableStatus",     mtStatus);
    SET_DWORD(L"MtEnableTries",      mtTries);
    SET_DWORD(L"LastInBrbLength",    lastInLen);
    SET_DWORD(L"LastInFlags",        lastInFl);
    SET_DWORD(L"AclOutCount",        aclOut);
    SET_DWORD(L"LastOutBufferSize",  lastOutSz);
    SET_DWORD(L"LastOutFlags",       lastOutFl);
    SET_DWORD(L"LastOutHdr",         lastOutHdr);

#undef SET_DWORD

    RtlInitUnicodeString(&n, L"LastSdpBytes");
    ZwSetValueKey(key, &n, 0, REG_BINARY, lastBytes, 64);
    RtlInitUnicodeString(&n, L"LastAclBytes");
    ZwSetValueKey(key, &n, 0, REG_BINARY, lastAclBytes, 16);
    ZwClose(key);
}

