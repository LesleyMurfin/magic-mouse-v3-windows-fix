// SPDX-License-Identifier: MIT
//
// Stay on RID 0x12 (MOUSE2_REPORT_ID). Do not convert to RID 0x02.
//
// Live HID 2026-08-30 21:23 MDT (Apr 30 MagicMouseFix AD5D244B):
//   COL01 Input 0x12 is X/Y only. No Wheel usage 0x0038.
//   That is why the pointer moves and scroll does not.
//   HidBth delivers 0x12. Product battery is RID 0x90 Input on COL02,
//   not Feature 0x47 (fails on COL01 and COL02).
//
// Layout from Linux drivers/hid/hid-magicmouse.c (GPL-2.0-or-later):
//   magicmouse_raw_event() MOUSE2_REPORT_ID — size 8 or (14 + 8*N)
//   magicmouse_emit_touch() surface-scroll (0323 uses the Mouse 2 path)
//
// Output (8 bytes) matches the injected COL01 0x12 descriptor:
//   [0] RID 0x12
//   [1] buttons (bit0 left, bit1 right)
//   [2..3] X INT16 LE  — native / Linux MOUSE2 optical (keep pointer)
//   [4..5] Y INT16 LE
//   [6] AC Pan INT8    — horizontal surface scroll
//   [7] Wheel INT8     — vertical surface scroll (usage 0x0038)
#pragma once
#include "Driver.h"

// 1-byte RID + 13-byte header = 14 bytes with zero touch points.
// Linux also accepts a compact 8-byte MOUSE2 report (no touch block).
#define MM2_HEADER_LEN 14
#define MM2_COMPACT_LEN 8
#define MM2_TOUCH_BYTES 8

#define MM_REPORT_ID_MOUSE    0x12
#define MM_REPORT_ID_BATTERY  0x90

// Surface drag distance (touch units) per Wheel detent.
// Hardware 2026-09-01: 224 (Linux default) produced zero wheel on live 0323.
// Proven working detent is 8. Do not ship 224 without a new glass proof.
#define MM_SCROLL_STEP 8

#define SCROLL_HR_THRESHOLD 90


// TranslateMouse2ToHid
//
// Accepts RID 0x12 (MOUSE2) or RID 0x27. Always produces an 8-byte RID 0x12
// with Wheel / AC Pan filled from the 14+8*N touch block when present.
// Optical X/Y stay INT16 so the Apr 30 pointer path is not clamped to INT8.
NTSTATUS TranslateMouse2ToHid(
    _In_reads_bytes_(inLen)     PUCHAR in,
    _In_                        SIZE_T inLen,
    _Out_writes_bytes_all_(MM_MOUSE_REPORT_LEN) PUCHAR out,
    _Inout_                     PULONG outLen,
    _Inout_                     PDEVICE_CONTEXT ctx
);
