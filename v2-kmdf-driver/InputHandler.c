// SPDX-License-Identifier: MIT
//
// SdpRewrite — SDP attribute 0x0206 (HIDDescriptorList) descriptor injection.
//
// Called from OnSdpQueryComplete (Driver.c) after
// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE (0x410210) completes. Scans the SDP
// response buffer for attribute 0x0206 and replaces the embedded HID descriptor
// with g_HidDescriptor[] (Descriptor C).
//
// SDP DataElement wire format (Bluetooth Core Spec Vol 3 Part B §3.3):
//   Byte 0: type descriptor (upper 5 bits = type, lower 3 bits = size specifier)
//   Size specifier 5 = 1 additional byte gives element length
//                  6 = 2 additional bytes (big-endian) give element length
//
//   Type 1 (unsigned int): 0x08 = 8-bit, 0x09 = 16-bit (2 BE bytes follow)
//   Type 4 (sequence):     0x35 = length in next 1 byte, 0x36 = next 2 bytes
//   Type 2 (string):       0x25 = length in next 1 byte, 0x26 = next 2 bytes
//
// Pattern for HIDDescriptorList (attribute 0x0206) with 1-byte sequence headers:
//   09 02 06    UINT16 attribute ID = 0x0206
//   35 LL       outer SEQUENCE, 1-byte length (LL = outerPayload)
//     35 LL     inner SEQUENCE (one {type, descriptor} entry), 1-byte length
//       08 22   UINT8 value 0x22 = "HID Report Descriptor" type tag
//       25 NN   TEXT_STRING, 1-byte length (NN = descriptor byte count)
//         <NN bytes> = HID descriptor
//
// The SDP response buffer is the AttributeLists output of the IOCTL — it is
// itself wrapped in a top-level sequence (either 0x35 or 0x36). Patching
// updates all four length fields: TEXT_STRING len, inner seq len, outer seq
// len, AND the top-level AttributeLists sequence length.

#include "InputHandler.h"
#include "HidDescriptor.h"

// SDP DataElement type descriptor bytes
#define SDP_TYPE_UINT8   0x08   // unsigned int, 8-bit value
#define SDP_TYPE_UINT16  0x09   // unsigned int, 16-bit value (2 bytes, big-endian)
#define SDP_SEQ_1B       0x35   // sequence, 1-byte length follows
#define SDP_SEQ_2B       0x36   // sequence, 2-byte big-endian length follows
#define SDP_STR_1B       0x25   // text string, 1-byte length follows

#define HID_DESC_ATTR_HI  0x02  // HIDDescriptorList attribute ID high byte
#define HID_DESC_ATTR_LO  0x06  // HIDDescriptorList attribute ID low byte
#define HID_RPT_DESC_TYPE 0x22  // "HID Report Descriptor" type tag value

#define SDP_SCAN_MATCH_LEN 11   // bytes from attr UINT16 header to descriptor body start
#define SDP_DESC_MAX_LEN  512   // sanity cap on declared descriptor length

// --------------------------------------------------------------------------
// ScanForSdpHidDescriptor
//
// Locates the embedded HID descriptor within an SDP attribute response buffer.
// Only handles 1-byte-length-prefix sequences (0x35). If the response uses
// 0x36 (2-byte) length sequences, this returns FALSE. The diagnostic
// LastSdpBytes key will reveal the actual format so support can be added.
//
// On TRUE: *descOffset = byte offset of first descriptor byte,
//          *descLen    = byte count of the existing descriptor.
// --------------------------------------------------------------------------

static BOOLEAN
ScanForSdpHidDescriptor(
    _In_reads_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG    bufSize,
    _Out_ PULONG   descOffset,
    _Out_ PULONG   descLen)
{
    if (buf == NULL || bufSize < SDP_SCAN_MATCH_LEN) return FALSE;
    ULONG limit = bufSize - SDP_SCAN_MATCH_LEN;

    for (ULONG i = 0; i <= limit; i++)
    {
        // 09 02 06 — UINT16 attribute ID 0x0206 (HIDDescriptorList)
        if (buf[i]     != SDP_TYPE_UINT16)  continue;
        if (buf[i + 1] != HID_DESC_ATTR_HI) continue;
        if (buf[i + 2] != HID_DESC_ATTR_LO) continue;

        // Outer sequence — 1-byte length only
        if (buf[i + 3] != SDP_SEQ_1B) continue;
        UCHAR outerLen = buf[i + 4];
        if (outerLen < 4) continue;
        if ((ULONG)(i + 5) + outerLen > bufSize) continue;

        // Inner sequence — 1-byte length only
        if (buf[i + 5] != SDP_SEQ_1B) continue;
        UCHAR innerLen = buf[i + 6];
        if (innerLen < 4) continue;
        if ((ULONG)(i + 7) + innerLen > bufSize) continue;

        // UINT8 0x22 = HID_REPORT_DESCRIPTOR_TYPE
        if (buf[i + 7] != SDP_TYPE_UINT8)    continue;
        if (buf[i + 8] != HID_RPT_DESC_TYPE) continue;

        // TEXT_STRING 1-byte length
        if (buf[i + 9] != SDP_STR_1B) continue;
        UCHAR nd = buf[i + 10];
        if (nd == 0 || nd > SDP_DESC_MAX_LEN) continue;
        if ((ULONG)(i + 11) + nd > bufSize) continue;

        *descOffset = i + 11;
        *descLen    = (ULONG)nd;
        return TRUE;
    }
    return FALSE;
}

// --------------------------------------------------------------------------
// PatchSdpHidDescriptor
//
// All-or-nothing: validates all preconditions, then replaces the descriptor
// body and updates four SDP length fields. Never partially mutates on failure.
//
// Fields updated:
//   buf[descOffset - 1]  TEXT_STRING length byte
//   buf[descOffset - 5]  inner SEQUENCE length byte
//   buf[descOffset - 7]  outer SEQUENCE length byte
//   buf[0..1] or [0..2]  top-level AttributeLists sequence length
//
// With Apple's 135-byte descriptor (116 bytes + 19-byte zero padding), delta=0
// and this function performs an in-place byte swap — no tail shifting, no SDP
// length field updates needed. STATUS_BUFFER_TOO_SMALL is a safety rail for
// any future descriptor larger than the native one.
// --------------------------------------------------------------------------

static NTSTATUS
PatchSdpHidDescriptor(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG    bufSize,
    _In_  ULONG    descOffset,
    _In_  ULONG    descLen,
    _Out_ PULONG   newBufUsed)
{
    // Validate before any mutation.
    // descOffset = i + 11 (from ScanForSdpHidDescriptor), always >= 11.
    ASSERT(descOffset >= 11);
    if (g_HidDescriptorSize == 0) return STATUS_INVALID_PARAMETER;

    ULONG newDescLen   = g_HidDescriptorSize;
    ULONG innerPayload = 2 + 2 + newDescLen;  // 08 22 + 25 NN + <desc>
    ULONG outerPayload = 2 + innerPayload;    // 35 LL + inner seq

    if (newDescLen   > 0xFF) return STATUS_INVALID_PARAMETER;
    if (innerPayload > 0xFF) return STATUS_INVALID_PARAMETER;
    if (outerPayload > 0xFF) return STATUS_INVALID_PARAMETER;

    ULONG tailOffset = descOffset + descLen;
    if (tailOffset > bufSize) return STATUS_INVALID_PARAMETER;
    ULONG tailBytes  = bufSize - tailOffset;
    ULONG needed     = descOffset + newDescLen + tailBytes;
    if (needed > bufSize)    return STATUS_BUFFER_TOO_SMALL;

    // Shift tail bytes if sizes differ.
    if (newDescLen != descLen && tailBytes > 0)
    {
        ULONG newTailOffset = descOffset + newDescLen;
        RtlMoveMemory(buf + newTailOffset, buf + tailOffset, tailBytes);
    }

    // Zero the gap left by shrinking (keeps buffer clean for diagnostics).
    if (newDescLen < descLen)
    {
        ULONG gapStart = descOffset + newDescLen + tailBytes;
        ULONG gapLen   = descLen - newDescLen;
        RtlZeroMemory(buf + gapStart, gapLen);
    }

    // Place new descriptor.
    RtlCopyMemory(buf + descOffset, g_HidDescriptor, newDescLen);

    // Fix three innermost SDP length bytes.
    // Layout relative to descOffset (= match position i + 11):
    //   [descOffset-1] = buf[i+10] = TEXT_STRING length (0x25 NN)
    //   [descOffset-5] = buf[i+ 6] = inner SEQUENCE length (0x35 LL)
    //   [descOffset-7] = buf[i+ 4] = outer SEQUENCE length (0x35 LL)
    buf[descOffset - 1] = (UCHAR)newDescLen;    // TEXT_STRING len
    buf[descOffset - 5] = (UCHAR)innerPayload;  // inner SEQUENCE len
    buf[descOffset - 7] = (UCHAR)outerPayload;  // outer SEQUENCE len

    // Fix the top-level AttributeLists sequence that wraps the entire response.
    // The SDP ServiceAttributeResponse AttributeLists parameter is itself a
    // sequence data element starting at buf[0].
    LONG delta = (LONG)newDescLen - (LONG)descLen;  // negative when shrinking
    if (bufSize >= 2 && buf[0] == SDP_SEQ_1B)
    {
        // 0x35 NN — 1-byte length
        LONG newTop = (LONG)(UCHAR)buf[1] + delta;
        if (newTop >= 0 && newTop <= 0xFF)
            buf[1] = (UCHAR)newTop;
    }
    else if (bufSize >= 3 && buf[0] == SDP_SEQ_2B)
    {
        // 0x36 HH LL — 2-byte big-endian length
        USHORT top    = ((USHORT)buf[1] << 8) | (USHORT)buf[2];
        LONG   newTop = (LONG)top + delta;
        if (newTop >= 0 && newTop <= 0xFFFF)
        {
            buf[1] = (UCHAR)((USHORT)newTop >> 8);
            buf[2] = (UCHAR)((USHORT)newTop & 0xFF);
        }
    }

    *newBufUsed = needed;
    return STATUS_SUCCESS;
}

// --------------------------------------------------------------------------
// SdpRewrite_Process — public entry point
// --------------------------------------------------------------------------

NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG  bufSize,
    _Out_ PULONG newLen)
{
    *newLen = bufSize;  // default: no change

    if (buf == NULL || bufSize < SDP_SCAN_MATCH_LEN) return STATUS_INVALID_PARAMETER;

    ULONG descOffset = 0, descLen = 0;
    if (!ScanForSdpHidDescriptor(buf, bufSize, &descOffset, &descLen))
    {
        // Normal for non-HID SDP attribute responses — not an error.
        return STATUS_NOT_FOUND;
    }

    DbgPrint("M13: SDP 0x0206 found at buf[%lu], existing desc=%lu B, injecting %lu B\n",
             descOffset, descLen, g_HidDescriptorSize);

    ULONG    used = 0;
    NTSTATUS s    = PatchSdpHidDescriptor(buf, bufSize, descOffset, descLen, &used);
    if (!NT_SUCCESS(s))
    {
        DbgPrint("M13: PatchSdpHidDescriptor failed 0x%08X — passthrough unchanged\n", s);
        return STATUS_MORE_PROCESSING_REQUIRED;  // buffer unmodified; caller passthrough
    }

    DbgPrint("M13: Patch OK — SDP buffer %lu -> %lu bytes\n", bufSize, used);
    *newLen = used;
    return STATUS_SUCCESS;
}
