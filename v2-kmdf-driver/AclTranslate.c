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
// Stay on 0x12. Keep usages 0x0030/0x0031. Fill Wheel / AC Pan as extras.
// Do not convert to RID 0x02. RID 0x90 (COL02 battery Input) is passed through.
//
// Do not write past capacity. Growing a 6-byte report to 8 without a proven
// allocation is an Event 41 / bugcheck candidate. If we cannot grow, leave
// the native 6-byte X/Y intact (pointer-safe, wheel omitted).

#include "AclTranslate.h"
#include "GestureEngine.h"

#ifndef HID_MSG_DATA_INPUT
#define HID_MSG_DATA_INPUT 0xA1
#endif



BOOLEAN
TranslateAclHidReport(
    _Inout_updates_bytes_(capacity) PUCHAR buf,
    _In_ ULONG receivedLen,
    _In_ ULONG capacity,
    _Out_ PULONG newLen,
    _Inout_ PDEVICE_CONTEXT ctx)
{
    *newLen = receivedLen;

    if (buf == NULL || ctx == NULL || receivedLen < 1 || capacity < 1)
    {
        return FALSE;
    }

    ULONG parseLen = receivedLen;
    if (parseLen > capacity)
    {
        parseLen = capacity;
    }

    // Battery: live HidD_GetInputReport(0x90) on COL02. Do not rewrite.
    if (buf[0] == MM_REPORT_ID_BATTERY ||
        (buf[0] == HID_MSG_DATA_INPUT && parseLen >= 2 && buf[1] == MM_REPORT_ID_BATTERY))
    {
        return FALSE;
    }

    if (parseLen < 6)
    {
        return FALSE;
    }

    PUCHAR report = buf;
    ULONG  reportLen = parseLen;
    BOOLEAN hidHdr = FALSE;

    if (buf[0] == HID_MSG_DATA_INPUT && parseLen >= 7 &&
        (buf[1] == MM_REPORT_ID_MOUSE || buf[1] == 0x27))
    {
        hidHdr = TRUE;
        report = buf + 1;
        reportLen = parseLen - 1;
    }
    else if (buf[0] != MM_REPORT_ID_MOUSE && buf[0] != 0x27)
    {
        return FALSE;
    }

    ULONG need = hidHdr ? (1u + MM_MOUSE_REPORT_LEN) : MM_MOUSE_REPORT_LEN;
    if (capacity < need)
    {
        // Cannot grow in-place. Native 6-byte X/Y stays (pointer-safe).
        return FALSE;
    }

    if (reportLen > MM_ACL_MAX_PARSE)
    {
        reportLen = MM_ACL_MAX_PARSE;
    }

    UCHAR translated[MM_MOUSE_REPORT_LEN];
    ULONG translatedLen = sizeof(translated);
    NTSTATUS ts = TranslateMouse2ToHid(report, reportLen, translated, &translatedLen, ctx);
    if (!NT_SUCCESS(ts) || translatedLen != MM_MOUSE_REPORT_LEN)
    {
        return FALSE;
    }

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
