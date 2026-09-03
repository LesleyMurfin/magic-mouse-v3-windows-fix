// SPDX-License-Identifier: MIT
//
// HID report descriptor injected into SDP attribute 0x0206.
//
// Live HID 2026-08-30 21:23 MDT on Apr 30 MagicMouseFix (AD5D244B):
//   COL01 Input 0x12 = X/Y only. Usage Wheel 0x0038 is ABSENT.
//   That is why the pointer moves and scroll does not.
//   COL02 HidD_GetInputReport(0x90) = [90 04 2F ...] → 47% at byte[2].
//   Feature 0x47 fails on COL01 and COL02. Product battery is RID 0x90.
//
// HidBth delivers RID 0x12 to hidclass. Descriptor C (RID 0x02 + Feat 0x47)
// is not what the live stack bound. This blob stays on 0x12 / 0x90 and ADDS
// Wheel (GD 0x38) and AC Pan (Consumer 0x0238) to the 0x12 collection so
// mouhid can see scroll on the same reports HidBth already forwards.
//
// 0x12 report after injection (8 bytes):
//   [0] RID 0x12
//   [1] buttons (bit0 left, bit1 right, bit2 middle)
//   [2..3] X INT16 LE   — same offsets as native / Linux MOUSE2
//   [4..5] Y INT16 LE
//   [6] AC Pan INT8     — synthesized from surface
//   [7] Wheel INT8      — synthesized from surface
//
// Do NOT pad with 0x00 (hidparse STATUS_ILLEGAL_INSTRUCTION).

#include "HidDescriptor.h"

const UCHAR g_HidDescriptor[] = {
    // ---- COL01: Mouse, Report ID 0x12 (what HidBth actually delivers) ----
    0x05, 0x01,             // Usage Page (Generic Desktop)
    0x09, 0x02,             // Usage (Mouse)
    0xA1, 0x01,             // Collection (Application)
    0x85, 0x12,             //   Report ID (0x12)

    0x05, 0x09,             //   Usage Page (Button)
    0x19, 0x01,             //   Usage Minimum (Button 1)
    0x29, 0x03,             //   Usage Maximum (Button 3)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x01,             //   Logical Maximum (1)
    0x95, 0x03,             //   Report Count (3)
    0x75, 0x01,             //   Report Size (1)
    0x81, 0x02,             //   Input (Data, Var, Abs)          — 3 bits
    0x95, 0x01,             //   Report Count (1)
    0x75, 0x05,             //   Report Size (5)
    0x81, 0x03,             //   Input (Constant)                — pad to 8 bits

    0x05, 0x01,             //   Usage Page (Generic Desktop)
    0x09, 0x01,             //   Usage (Pointer)
    0xA1, 0x00,             //   Collection (Physical)
    0x16, 0x00, 0x80,       //     Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,       //     Logical Maximum (32767)
    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x06,             //     Input (Data, Var, Rel)        — 4 bytes

    0x15, 0x81,             //     Logical Minimum (-127)
    0x25, 0x7F,             //     Logical Maximum (127)
    0x05, 0x0C,             //     Usage Page (Consumer)
    0x0A, 0x38, 0x02,       //     Usage (AC Pan 0x0238)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Var, Rel)        — byte[6]

    0x05, 0x01,             //     Usage Page (Generic Desktop)
    0x09, 0x38,             //     Usage (Wheel 0x0038)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Var, Rel)        — byte[7]
    0xC0,                   //   End Collection (Physical)
    0xC0,                   // End Collection (Application)

    // ---- COL02: Battery, Report ID 0x90 Input (live: [90 04 2F ...] = 47%) ----
    0x05, 0x01,             // Usage Page (Generic Desktop)
    0x09, 0x06,             // Usage (Keyboard) — unused; TLC tag only
    0x05, 0x06,             // Usage Page (Generic Device Controls)
    0x09, 0x20,             // Usage (Battery Strength)
    0xA1, 0x01,             // Collection (Application)
    0x85, 0x90,             //   Report ID (0x90)
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x01,             //   Report Count (1)
    0x81, 0x03,             //   Input (Constant)                — byte[1] = 0x04 live
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x64,             //   Logical Maximum (100)
    0x09, 0x20,             //   Usage (Battery Strength)
    0x95, 0x01,             //   Report Count (1)
    0x81, 0x02,             //   Input (Data, Var, Abs)          — byte[2] percent
    0xC0,                   // End Collection
};

const ULONG g_HidDescriptorSize = sizeof(g_HidDescriptor);
