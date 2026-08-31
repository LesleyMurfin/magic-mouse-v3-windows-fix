// SPDX-License-Identifier: MIT
//
// RID 0x12 (MOUSE2_REPORT_ID) → RID 0x02 standard mouse report.
// Layout from Linux drivers/hid/hid-magicmouse.c (GPL-2.0-or-later):
//   magicmouse_raw_event() MOUSE2_REPORT_ID case
//   magicmouse_emit_touch() surface-scroll
// Windows output matches the injected Descriptor C (HidDescriptor.c).
#pragma once
#include "Driver.h"

// 1-byte RID + 13-byte header = 14 bytes with zero touch points.
// Linux also accepts a compact 8-byte MOUSE2 report (no touch block).
#define MM2_HEADER_LEN 14
#define MM2_COMPACT_LEN 8
#define MM2_TOUCH_BYTES 8

// Surface drag distance (touch units) per Wheel detent. Conservative start;
// Linux uses (64 - scroll_speed) * scroll_accel with defaults ~224.
#define MM_SCROLL_STEP 64

// TranslateMouse2ToHid
//
// Accepts RID 0x12 (MOUSE2) or RID 0x27 (Descriptor C touch, 46-byte payload
// = 14-byte header + 4×8-byte fingers). Always produces a 6-byte RID 0x02:

//   [0] RID 0x02
//   [1] buttons (bit0 left, bit1 right)
//   [2] X INT8   — optical delta from data[2..3] (LE int16, clamped)
//   [3] Y INT8   — optical delta from data[4..5] (LE int16, clamped)
//   [4] AC Pan   — horizontal surface scroll
//   [5] Wheel    — vertical surface scroll
//
// 2.0.2.0 only emitted this report for 2-finger scroll and used the wrong
// 5-byte X_lo/X_hi/Wheel layout — pointer stayed dead even when translation
// ran. This function always copies optical X/Y.
NTSTATUS TranslateMouse2ToHid(
    _In_reads_bytes_(inLen)     PUCHAR in,
    _In_                        SIZE_T inLen,
    _Out_writes_bytes_all_(MM_MOUSE_REPORT_LEN) PUCHAR out,
    _Inout_                     PULONG outLen,
    _Inout_                     PDEVICE_CONTEXT ctx
);
