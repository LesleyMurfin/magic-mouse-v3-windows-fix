// SPDX-License-Identifier: MIT
//
// MagicKbDesc — descriptor-patch logic + IRP completion routine.
//
// Bytes we insert before Col02's closing `c0 c0`:
//
//   09 20    Usage (Battery Strength)            <- local item, re-emit
//   B1 02    Feature (Data, Variable, Absolute)  <- main item
//
// Same global attributes as the preceding Input declaration:
//   75 08    Report Size (8 bits)
//   95 01    Report Count (1)
//   15 00    Logical Min (0)
//   26 FF 00 Logical Max (255)
// All four global items persist across main items per HID spec
// (§6.2.2.7). Only the Usage (local) needs re-emitting.

#include "MagicKbDesc.h"

const UCHAR g_FeatureInsertBytes[4] = { 0x09, 0x20, 0xB1, 0x02 };

// Match signature for the END of Col02's logical collection.
// Col02 starts with `05 0C 09 01 A1 01 05 01 09 06 A1 02 85 47 ...`
// and ends with `... 81 02 C0 C0`. We anchor on the unique RID
// declaration `85 47` followed (within ~32 bytes) by `81 02 C0 C0`.
//
// We DON'T anchor on the full Col02 byte sequence because it might
// vary slightly across firmware revisions — but the RID 0x47 + Input
// main item + double-end anchor is stable.

static PUCHAR
MagicKbDescFindCol02InsertPoint(
    _In_reads_bytes_(BufferLength) PUCHAR Buffer,
    _In_                           SIZE_T BufferLength
    )
{
    // Search for `85 47` (Report ID 0x47).
    if (BufferLength < 6) {
        return NULL;
    }

    for (SIZE_T i = 0; i + 5 < BufferLength; i++) {
        if (Buffer[i] == 0x85 && Buffer[i + 1] == 0x47) {
            // Found Report ID 0x47. Now search forward up to 64 bytes
            // for `81 02 C0 C0` (Input + double EndCollection).
            SIZE_T scanEnd = (i + 64 < BufferLength) ? i + 64 : BufferLength;
            for (SIZE_T j = i + 2; j + 3 < scanEnd; j++) {
                if (Buffer[j]     == 0x81 && Buffer[j + 1] == 0x02 &&
                    Buffer[j + 2] == 0xC0 && Buffer[j + 3] == 0xC0) {
                    // Insert at offset j+2 (immediately before C0 C0).
                    return &Buffer[j + 2];
                }
            }
        }
    }
    return NULL;
}

SIZE_T
MagicKbDescPatchDescriptor(
    _Inout_updates_bytes_(BufferCapacity) PUCHAR Buffer,
    _In_                                  SIZE_T OriginalLength,
    _In_                                  SIZE_T BufferCapacity
    )
{
    PUCHAR insertPoint;
    SIZE_T insertOffset;
    SIZE_T newLength;

    if (Buffer == NULL || OriginalLength == 0) {
        return 0;
    }

    insertPoint = MagicKbDescFindCol02InsertPoint(Buffer, OriginalLength);
    if (insertPoint == NULL) {
        // This descriptor isn't Col02, or isn't an Apple keyboard with
        // RID 0x47. Pass through unmodified.
        return 0;
    }

    newLength = OriginalLength + sizeof(g_FeatureInsertBytes);
    if (newLength > BufferCapacity) {
        // Caller must reallocate with a larger buffer.
        return newLength;
    }

    insertOffset = (SIZE_T)(insertPoint - Buffer);

    // Shift the tail right by 4 bytes to make room.
    RtlMoveMemory(insertPoint + sizeof(g_FeatureInsertBytes),
                  insertPoint,
                  OriginalLength - insertOffset);

    // Insert the patch bytes.
    RtlCopyMemory(insertPoint, g_FeatureInsertBytes, sizeof(g_FeatureInsertBytes));

    return newLength;
}

VOID
MagicKbDescDescriptorCompletion(
    _In_ WDFREQUEST                 Request,
    _In_ WDFIOTARGET                Target,
    _In_ PWDF_REQUEST_COMPLETION_PARAMS Params,
    _In_ WDFCONTEXT                 Context
    )
{
    NTSTATUS status = Params->IoStatus.Status;
    SIZE_T   info   = (SIZE_T)Params->IoStatus.Information;
    PUCHAR   buffer = NULL;
    SIZE_T   bufferLength = 0;
    SIZE_T   validLen;
    SIZE_T   patchedLength;

    UNREFERENCED_PARAMETER(Target);
    UNREFERENCED_PARAMETER(Context);

    if (!NT_SUCCESS(status) || info == 0) {
        WdfRequestComplete(Request, status);
        return;
    }

    // Retrieve the output buffer from the request. WdfRequestRetrieveOutputBuffer
    // is callable at IRQL <= DISPATCH_LEVEL, which matches WDF completion-routine
    // IRQL guarantees.
    status = WdfRequestRetrieveOutputBuffer(Request,
                                            info,
                                            (PVOID*)&buffer,
                                            &bufferLength);
    if (!NT_SUCCESS(status) || buffer == NULL) {
        WdfRequestComplete(Request, status);
        return;
    }

    // B4 — defend against the lower stack reporting more bytes written than the
    // buffer can actually hold. Use the smaller of the two as the byte-search
    // and shift bound.
    validLen = (info <= bufferLength) ? info : bufferLength;

    patchedLength = MagicKbDescPatchDescriptor(buffer, validLen, bufferLength);
    if (patchedLength == 0) {
        // No patch applicable — pass through unchanged.
        WdfRequestCompleteWithInformation(Request, status, info);
        return;
    }
    if (patchedLength > bufferLength) {
        // Buffer too small for the 4-byte expansion. After the B2 fix
        // (IOCTL_HID_GET_DEVICE_DESCRIPTOR completion routine pre-bumps
        // wReportLength), this branch should be unreachable. If it ever
        // fires, hidclass.sys did not call us through the LENGTH IOCTL —
        // log loudly and fail explicitly so we can diagnose.
        KdPrint(("MagicKbDesc: descriptor buf too small: have=%Iu need=%Iu "
                 "(BUG: IOCTL_HID_GET_DEVICE_DESCRIPTOR pre-bump missed)\n",
                 bufferLength, patchedLength));
        WdfRequestComplete(Request, STATUS_BUFFER_OVERFLOW);
        return;
    }

    KdPrint(("MagicKbDesc: descriptor patched: %Iu -> %Iu bytes\n",
             validLen, patchedLength));
    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, patchedLength);
}

// B2 — pre-bump wReportLength so hidclass.sys allocates a buffer big enough
// for the patched descriptor (original_len + sizeof(g_FeatureInsertBytes)).
//
// IOCTL_HID_GET_DEVICE_DESCRIPTOR returns a HID_DESCRIPTOR struct whose
// DescriptorList[0].wReportLength holds the size of the report descriptor.
// hidclass.sys reads that value to size the buffer it then passes to
// IOCTL_HID_GET_REPORT_DESCRIPTOR. Bumping wReportLength here makes the
// downstream buffer 4 bytes larger, so MagicKbDescDescriptorCompletion's
// in-place patch fits.
VOID
MagicKbDescDeviceDescriptorCompletion(
    _In_ WDFREQUEST                 Request,
    _In_ WDFIOTARGET                Target,
    _In_ PWDF_REQUEST_COMPLETION_PARAMS Params,
    _In_ WDFCONTEXT                 Context
    )
{
    NTSTATUS        status = Params->IoStatus.Status;
    SIZE_T          info   = (SIZE_T)Params->IoStatus.Information;
    PHID_DESCRIPTOR hidDesc = NULL;
    SIZE_T          bufferLength = 0;

    UNREFERENCED_PARAMETER(Target);
    UNREFERENCED_PARAMETER(Context);

    if (!NT_SUCCESS(status) || info < sizeof(HID_DESCRIPTOR)) {
        // hidbth either failed or returned a smaller-than-expected struct.
        // Pass through unchanged — we're a transparent filter for non-Apple
        // HID devices that might match our INF whitelist incorrectly.
        WdfRequestCompleteWithInformation(Request, status, info);
        return;
    }

    status = WdfRequestRetrieveOutputBuffer(Request,
                                            sizeof(HID_DESCRIPTOR),
                                            (PVOID*)&hidDesc,
                                            &bufferLength);
    if (!NT_SUCCESS(status) || hidDesc == NULL) {
        WdfRequestComplete(Request, status);
        return;
    }

    // Sanity: confirm the struct shape matches what we expect before mutating.
    if (hidDesc->bLength       != sizeof(HID_DESCRIPTOR) ||
        hidDesc->bDescriptorType != 0x21 ||             // HID class descriptor
        hidDesc->bNumDescriptors == 0) {
        // Not a stock HID descriptor — leave it alone.
        WdfRequestCompleteWithInformation(Request, Params->IoStatus.Status, info);
        return;
    }

    // Bump the report descriptor length so hidclass allocates a +4 buffer.
    hidDesc->DescriptorList[0].wReportLength =
        (USHORT)(hidDesc->DescriptorList[0].wReportLength + sizeof(g_FeatureInsertBytes));

    KdPrint(("MagicKbDesc: bumped wReportLength by %u to %u\n",
             (unsigned)sizeof(g_FeatureInsertBytes),
             hidDesc->DescriptorList[0].wReportLength));

    WdfRequestCompleteWithInformation(Request, STATUS_SUCCESS, info);
}

VOID
MagicKbDescEvtIoInternalDeviceControl(
    _In_ WDFQUEUE   Queue,
    _In_ WDFREQUEST Request,
    _In_ size_t     OutputBufferLength,
    _In_ size_t     InputBufferLength,
    _In_ ULONG      IoControlCode
    )
{
    WDFDEVICE  device = WdfIoQueueGetDevice(Queue);
    WDFIOTARGET target = WdfDeviceGetIoTarget(device);

    UNREFERENCED_PARAMETER(OutputBufferLength);
    UNREFERENCED_PARAMETER(InputBufferLength);

    KdPrint(("MagicKbDesc: EvtIoInternalDeviceControl ioctl=0x%X\n", IoControlCode));

    // B1 — canonical WDF lower-filter completion-routine pattern: format the
    // request, set the completion routine, then ONE WdfRequestSend. The
    // completion routine MUST be set BEFORE WdfRequestSend; once the request
    // is sent its ownership transfers to the I/O target.
    if (IoControlCode == IOCTL_HID_GET_REPORT_DESCRIPTOR) {
        WdfRequestFormatRequestUsingCurrentType(Request);
        WdfRequestSetCompletionRoutine(Request,
                                       MagicKbDescDescriptorCompletion,
                                       NULL);
        if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS)) {
            NTSTATUS status = WdfRequestGetStatus(Request);
            KdPrint(("MagicKbDesc: WdfRequestSend(GET_REPORT_DESCRIPTOR) failed 0x%X\n", status));
            WdfRequestComplete(Request, status);
        }
        return;
    }

    // B2 — intercept the LENGTH IOCTL too, so hidclass allocates a buffer
    // big enough for the subsequent GET_REPORT_DESCRIPTOR after our 4-byte
    // patch.
    if (IoControlCode == IOCTL_HID_GET_DEVICE_DESCRIPTOR) {
        WdfRequestFormatRequestUsingCurrentType(Request);
        WdfRequestSetCompletionRoutine(Request,
                                       MagicKbDescDeviceDescriptorCompletion,
                                       NULL);
        if (!WdfRequestSend(Request, target, WDF_NO_SEND_OPTIONS)) {
            NTSTATUS status = WdfRequestGetStatus(Request);
            KdPrint(("MagicKbDesc: WdfRequestSend(GET_DEVICE_DESCRIPTOR) failed 0x%X\n", status));
            WdfRequestComplete(Request, status);
        }
        return;
    }

    // Default forward (send-and-forget) for all other IOCTLs.
    {
        WDF_REQUEST_SEND_OPTIONS opts;
        WDF_REQUEST_SEND_OPTIONS_INIT(&opts, WDF_REQUEST_SEND_OPTION_SEND_AND_FORGET);
        if (!WdfRequestSend(Request, target, &opts)) {
            NTSTATUS status = WdfRequestGetStatus(Request);
            WdfRequestComplete(Request, status);
        }
    }
}
