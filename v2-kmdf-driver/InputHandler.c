// SPDX-License-Identifier: MIT
//
// SdpRewrite — same-size overlay of SDP attribute 0x0206 HID report
// descriptor. Called from OnSdpQueryComplete after
// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE (0x410210) completes.
//
// Native v3 prefix (11 bytes, never modified):
//   09 02 06    UINT16 attribute ID = 0x0206
//   35 8D       outer SEQUENCE length 141
//   35 8B       inner SEQUENCE length 139
//   08 22       UINT8 HID Report Descriptor type
//   25 87       TEXT_STRING length 135
//
// Overlay copies 135 HID bytes after that prefix. No SEQ / string /
// AttributeLists length stores (writing 0x35 / 0x36 / 0x25 / buf[4]
// is the 0x50 bug). Missing prefix → no-op, buffer unchanged.

#include "InputHandler.h"
#include "HidDescriptor.h"

#define SDP_HID_PREFIX_LEN  11
#define SDP_HID_OVERLAY_LEN 0x87

static const UCHAR g_SdpHidPrefix[SDP_HID_PREFIX_LEN] = {
    0x09, 0x02, 0x06, 0x35, 0x8D, 0x35, 0x8B, 0x08, 0x22, 0x25, 0x87
};

NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(allocLen) PUCHAR  buf,
    _In_  ULONG  usedLen,
    _In_  ULONG  allocLen,
    _Out_ PULONG newLen)
{
    *newLen = usedLen;

    if (buf == NULL || allocLen < usedLen)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (g_HidDescriptorSize != SDP_HID_OVERLAY_LEN)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (usedLen < SDP_HID_PREFIX_LEN)
    {
        return STATUS_NOT_FOUND;
    }

    ULONG foundAt = 0;
    BOOLEAN found = FALSE;
    ULONG limit = usedLen - SDP_HID_PREFIX_LEN;
    for (ULONG i = 0; i <= limit; i++)
    {
        ULONG n;
        for (n = 0; n < SDP_HID_PREFIX_LEN; n++)
        {
            if (buf[i + n] != g_SdpHidPrefix[n]) { break; }
        }
        if (n == SDP_HID_PREFIX_LEN)
        {
            foundAt = i;
            found   = TRUE;
            break;
        }
    }

    if (!found)
    {
        return STATUS_NOT_FOUND;
    }

    ULONG descOffset = foundAt + SDP_HID_PREFIX_LEN;
    if (descOffset + SDP_HID_OVERLAY_LEN > usedLen ||
        descOffset + SDP_HID_OVERLAY_LEN > allocLen)
    {
        return STATUS_BUFFER_TOO_SMALL;
    }

    RtlCopyMemory(buf + descOffset, g_HidDescriptor, SDP_HID_OVERLAY_LEN);
    *newLen = usedLen;
    DbgPrint("MM: SDP overlay 135 B at buf[%lu] (len unchanged %lu)\n",
             descOffset, usedLen);
    return STATUS_SUCCESS;
}
