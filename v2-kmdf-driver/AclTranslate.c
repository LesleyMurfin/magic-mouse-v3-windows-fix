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
// We replace that with Descriptor C's RID 0x02 (6 bytes, optional 0xA1).

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

    if (buf == NULL || ctx == NULL || len < 6)
    {
        return FALSE;
    }

    PUCHAR report = buf;
    ULONG  reportLen = len;
    BOOLEAN hidHdr = FALSE;

    // RID 0x02 is the Apr 30 pointer path — do not rewrite it.
    if (buf[0] == 0x02 || (buf[0] == HID_MSG_DATA_INPUT && len >= 2 && buf[1] == 0x02))
    {
        return FALSE;
    }

    if (buf[0] == HID_MSG_DATA_INPUT && len >= 7 &&
        (buf[1] == 0x12 || buf[1] == 0x27))
    {
        hidHdr = TRUE;
        report = buf + 1;
        reportLen = len - 1;
    }
    else if (buf[0] != 0x12 && buf[0] != 0x27)
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
