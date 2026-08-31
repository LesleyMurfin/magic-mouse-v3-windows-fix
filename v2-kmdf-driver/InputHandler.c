// SPDX-License-Identifier: MIT
//
// SdpRewrite — SDP attribute 0x0206 (HIDDescriptorList) descriptor injection.
//
// Called from OnSdpQueryComplete after IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE
// (0x410210) completes. Replaces the HID report descriptor with the
// live-aligned blob (COL01 RID 0x12 + Wheel/AC Pan, COL02 RID 0x90 Input).
//
// SDP DataElement (Bluetooth Core Spec Vol 3 Part B §3.3):
//   09 02 06    UINT16 attribute ID = 0x0206
//   35 LL       outer SEQUENCE
//     35 LL     inner SEQUENCE
//       08 22   UINT8 HID Report Descriptor type
//       25 NN   TEXT_STRING length
//         <NN bytes>
//
// Plus the top-level AttributeLists sequence after the 8-byte
// BTH_SDP_STREAM_RESPONSE header.

#include "InputHandler.h"
#include "HidDescriptor.h"

#define SDP_TYPE_UINT8   0x08
#define SDP_TYPE_UINT16  0x09
#define SDP_SEQ_1B       0x35
#define SDP_SEQ_2B       0x36
#define SDP_STR_1B       0x25

#define HID_DESC_ATTR_HI  0x02
#define HID_DESC_ATTR_LO  0x06
#define HID_RPT_DESC_TYPE 0x22

#define SDP_SCAN_MATCH_LEN 11
#define SDP_DESC_MAX_LEN  512

static BOOLEAN
ScanForSdpHidDescriptor(
    _In_reads_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG    bufSize,
    _Out_ PULONG   descOffset,
    _Out_ PULONG   descLen)
{
    if (buf == NULL || bufSize < SDP_SCAN_MATCH_LEN) { return FALSE; }
    ULONG limit = bufSize - SDP_SCAN_MATCH_LEN;

    for (ULONG i = 0; i <= limit; i++)
    {
        if (buf[i]     != SDP_TYPE_UINT16)  { continue; }
        if (buf[i + 1] != HID_DESC_ATTR_HI) { continue; }
        if (buf[i + 2] != HID_DESC_ATTR_LO) { continue; }

        if (buf[i + 3] != SDP_SEQ_1B) { continue; }
        UCHAR outerLen = buf[i + 4];
        if (outerLen < 4) { continue; }
        if ((ULONG)(i + 5) + outerLen > bufSize) { continue; }

        if (buf[i + 5] != SDP_SEQ_1B) { continue; }
        UCHAR innerLen = buf[i + 6];
        if (innerLen < 4) { continue; }
        if ((ULONG)(i + 7) + innerLen > bufSize) { continue; }

        if (buf[i + 7] != SDP_TYPE_UINT8)    { continue; }
        if (buf[i + 8] != HID_RPT_DESC_TYPE) { continue; }

        if (buf[i + 9] != SDP_STR_1B) { continue; }
        UCHAR nd = buf[i + 10];
        if (nd == 0 || nd > SDP_DESC_MAX_LEN) { continue; }
        if ((ULONG)(i + 11) + nd > bufSize) { continue; }

        *descOffset = i + 11;
        *descLen    = (ULONG)nd;
        return TRUE;
    }
    return FALSE;
}

static NTSTATUS
PatchSdpHidDescriptor(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG    bufSize,
    _In_  ULONG    descOffset,
    _In_  ULONG    descLen,
    _Out_ PULONG   newBufUsed)
{
    ASSERT(descOffset >= 11);
    if (g_HidDescriptorSize == 0) { return STATUS_INVALID_PARAMETER; }

    ULONG newDescLen   = g_HidDescriptorSize;
    ULONG innerPayload = 2 + 2 + newDescLen;
    ULONG outerPayload = 2 + innerPayload;

    if (newDescLen   > 0xFF) { return STATUS_INVALID_PARAMETER; }
    if (innerPayload > 0xFF) { return STATUS_INVALID_PARAMETER; }
    if (outerPayload > 0xFF) { return STATUS_INVALID_PARAMETER; }

    ULONG tailOffset = descOffset + descLen;
    if (tailOffset > bufSize) { return STATUS_INVALID_PARAMETER; }
    ULONG tailBytes  = bufSize - tailOffset;
    ULONG needed     = descOffset + newDescLen + tailBytes;
    if (needed > bufSize) { return STATUS_BUFFER_TOO_SMALL; }

    if (newDescLen != descLen && tailBytes > 0)
    {
        ULONG newTailOffset = descOffset + newDescLen;
        RtlMoveMemory(buf + newTailOffset, buf + tailOffset, tailBytes);
    }

    if (newDescLen < descLen)
    {
        ULONG gapStart = descOffset + newDescLen + tailBytes;
        ULONG gapLen   = descLen - newDescLen;
        RtlZeroMemory(buf + gapStart, gapLen);
    }

    RtlCopyMemory(buf + descOffset, g_HidDescriptor, newDescLen);

    buf[descOffset - 1] = (UCHAR)newDescLen;
    buf[descOffset - 5] = (UCHAR)innerPayload;
    buf[descOffset - 7] = (UCHAR)outerPayload;

    // buf[0..7] = BTH_SDP_STREAM_RESPONSE; buf[8] is AttributeLists tag.
    LONG delta = (LONG)newDescLen - (LONG)descLen;
    if (delta != 0 && bufSize >= 11 && buf[8] == SDP_SEQ_1B)
    {
        LONG newTop = (LONG)(UCHAR)buf[9] + delta;
        if (newTop >= 0 && newTop <= 0xFF)
        {
            buf[9] = (UCHAR)newTop;
        }

        ULONG respSize;
        RtlCopyMemory(&respSize, buf + 4, sizeof(ULONG));
        LONG newResp = (LONG)respSize + delta;
        if (newResp > 0)
        {
            respSize = (ULONG)newResp;
            RtlCopyMemory(buf + 4, &respSize, sizeof(ULONG));
        }
    }
    else if (delta != 0 && bufSize >= 12 && buf[8] == SDP_SEQ_2B)
    {
        USHORT top    = (USHORT)(((USHORT)buf[9] << 8) | (USHORT)buf[10]);
        LONG   newTop = (LONG)top + delta;
        if (newTop >= 0 && newTop <= 0xFFFF)
        {
            buf[9]  = (UCHAR)((USHORT)newTop >> 8);
            buf[10] = (UCHAR)((USHORT)newTop & 0xFF);
        }

        ULONG respSize;
        RtlCopyMemory(&respSize, buf + 4, sizeof(ULONG));
        LONG newResp = (LONG)respSize + delta;
        if (newResp > 0)
        {
            respSize = (ULONG)newResp;
            RtlCopyMemory(buf + 4, &respSize, sizeof(ULONG));
        }
    }

    *newBufUsed = needed;
    return STATUS_SUCCESS;
}

NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG  bufSize,
    _Out_ PULONG newLen)
{
    *newLen = bufSize;

    if (buf == NULL || bufSize < SDP_SCAN_MATCH_LEN)
    {
        return STATUS_INVALID_PARAMETER;
    }

    ULONG descOffset = 0, descLen = 0;
    if (!ScanForSdpHidDescriptor(buf, bufSize, &descOffset, &descLen))
    {
        return STATUS_NOT_FOUND;
    }

    DbgPrint("MM: SDP 0x0206 at buf[%lu], existing=%lu B, injecting %lu B\n",
             descOffset, descLen, g_HidDescriptorSize);

    ULONG    used = 0;
    NTSTATUS s    = PatchSdpHidDescriptor(buf, bufSize, descOffset, descLen, &used);
    if (!NT_SUCCESS(s))
    {
        DbgPrint("MM: PatchSdpHidDescriptor 0x%08X — passthrough\n", s);
        return STATUS_MORE_PROCESSING_REQUIRED;
    }

    DbgPrint("MM: Patch OK — SDP buffer %lu -> %lu bytes\n", bufSize, used);
    *newLen = used;
    return STATUS_SUCCESS;
}
