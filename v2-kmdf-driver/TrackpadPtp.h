// SPDX-License-Identifier: MIT
#pragma once

#ifdef MM_USERLAND_TEST
#include "kernel-stubs.h"
#else
#include "Driver.h"
#endif

// Magic Trackpad Bluetooth PIDs. INF binds these; 0323 mouse is not a trackpad.
#ifndef MM_PID_TRACKPAD_V1
#define MM_PID_TRACKPAD_V1  0x030Eu
#define MM_PID_TRACKPAD_V2  0x0265u
#define MM_PID_TRACKPAD_V3  0x0324u
#endif

// Linux hid-magicmouse.c report IDs (numeric facts only).
#define TP_RID_V1           0x28
#define TP_RID_V2_BT        0x31
#define TP_RID_V2_USB       0x02
#define TP_RID_DOUBLE       0xF7
#define TP_RID_BATTERY      0x90

#define TP_PTP_RID          0x01
#define TP_PTP_REPORT_LEN   23
#define TP_PTP_CONTACTS     3
#define TP_TOUCH_BYTES      9
#define TP_BT_HEADER        4
#define TP_USB_HEADER       12

#define TP_PTP_DESC_MAX     249

extern const UCHAR g_PtpHidDescriptor[];
extern const ULONG g_PtpHidDescriptorSize;

BOOLEAN MmIsTrackpadPid(_In_ USHORT pid);

// Feature bytes Linux sends to start 0x28/0x31 (not transmitted this vertical).
BOOLEAN TrackpadFillMtEnable(
    _In_ USHORT pid,
    _Out_writes_bytes_(*outLen) PUCHAR out,
    _Inout_ PULONG outLen);

// Apple 0x28/0x31/0x02/0xF7 → PTP RID 0x01 (23 bytes). 0x90 and mouse 0x12: no.
NTSTATUS TranslateTrackpadToPtp(
    _In_reads_bytes_(inLen) PUCHAR in,
    _In_ SIZE_T inLen,
    _Out_writes_bytes_(*outLen) PUCHAR out,
    _Inout_ PULONG outLen,
    _In_ USHORT productId,
    _Inout_opt_ PULONG scanTime);
