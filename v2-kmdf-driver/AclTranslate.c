// SPDX-License-Identifier: MIT
//
// Rewrite Magic Mouse 0x12 reports on the L2CAP ACL path HidBth uses.
//
// HidBth sits above this filter. hidclass IRP_MJ_READ stops at HidBth, so
// EvtIoRead is not the live pointer path. HidBth posts BRB_L2CA_ACL_TRANSFER
// (IOCTL_INTERNAL_BTH_SUBMIT_BRB) down through us to BthEnum. On IN
// completion the buffer is a Bluetooth HID interrupt payload:
//   raw:        12 <MOUSE2...>
//   HID DATA:   A1 12 <MOUSE2...>
//
// Live HID 2026-08-30 21:23 MDT: COL01 Input 0x12 is X/Y only (no 0x0038).
// Stay on 0x12 and fill Wheel / AC Pan. Do not convert to RID 0x02.
// RID 0x90 (COL02 battery Input) is passed through.

#include "AclTranslate.h"
#include "GestureEngine.h"

#ifndef HID_MSG_DATA_INPUT
#define HID_MSG_DATA_INPUT 0xA1
#endif

BOOLEAN
TranslateAclHidReport(
    _Inout_updates_bytes_(len) PUCHAR buf,
    _In_ ULONG len,
    _Out_ PULONG newLen,
    _Inout_ PDEVICE_CONTEXT ctx)
{
    *newLen = len;

    if (buf == NULL || ctx == NULL || len < 1)
    {
        return FALSE;
    }

    // Battery: live HidD_GetInputReport(0x90) on COL02. Do not rewrite.
    if (buf[0] == MM_REPORT_ID_BATTERY ||
        (buf[0] == HID_MSG_DATA_INPUT && len >= 2 && buf[1] == MM_REPORT_ID_BATTERY))
    {
        return FALSE;
    }

    if (len < 6)
    {
        return FALSE;
    }

    PUCHAR report = buf;
    ULONG  reportLen = len;
    BOOLEAN hidHdr = FALSE;

    if (buf[0] == HID_MSG_DATA_INPUT && len >= 7 &&
        (buf[1] == MM_REPORT_ID_MOUSE || buf[1] == 0x27))
    {
        hidHdr = TRUE;
        report = buf + 1;
        reportLen = len - 1;
    }
    else if (buf[0] != MM_REPORT_ID_MOUSE && buf[0] != 0x27)
    {
        return FALSE;
    }

    UCHAR translated[MM_MOUSE_REPORT_LEN];
    ULONG translatedLen = sizeof(translated);
    NTSTATUS ts = TranslateMouse2ToHid(report, reportLen, translated, &translatedLen, ctx);
    if (!NT_SUCCESS(ts) || translatedLen != MM_MOUSE_REPORT_LEN)
    {
        return FALSE;
    }

    // May grow a 6-byte native X/Y-only 0x12 to 8 bytes (Wheel/AC Pan).
    // ACL buffers are far larger than 8; BufferSize is the received length.
    if (hidHdr)
    {
        buf[0] = HID_MSG_DATA_INPUT;
        RtlCopyMemory(buf + 1, translated, MM_MOUSE_REPORT_LEN);
        *newLen = 1 + MM_MOUSE_REPORT_LEN;
    }
    else
    {
        RtlCopyMemory(buf, translated, MM_MOUSE_REPORT_LEN);
        *newLen = MM_MOUSE_REPORT_LEN;
    }
    return TRUE;
}
