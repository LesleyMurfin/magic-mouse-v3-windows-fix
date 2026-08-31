// SPDX-License-Identifier: MIT
//
// HID report descriptor injected into SDP attribute 0x0206 (HIDDescriptorList).
//
// Source: Apple applewirelessmouse.sys SHA-256 08F33D7E... offset 0xA850,
// 116 bytes, plus 19-byte valid vendor Feature padding so the SDP blob stays
// the native size (in-place swap). Verified 2026-04-30 via Ghidra of
// FUN_14000A440.
//
// RID 0x02 input (5 data bytes after Report ID):
//   [1] 2 buttons + pad
//   [2] X INT8 relative
//   [3] Y INT8 relative
//   [4] AC Pan INT8 relative
//   [5] Wheel INT8 relative
//
// Do NOT pad with 0x00. hidparse.sys returns STATUS_ILLEGAL_INSTRUCTION
// (0xC000001D) for reserved Main-item tag 0 — that was the 2.0.0.0
// CM_PROB_FAILED_START. 2.0.2.0 fixed parse; this package adds report
// translation so the pointer actually moves.

#include "HidDescriptor.h"

const UCHAR g_HidDescriptor[] = {
    0x05, 0x01,             // Usage Page (Generic Desktop)
    0x09, 0x02,             // Usage (Mouse)
    0xA1, 0x01,             // Collection (Application)
    0x85, 0x02,             //   Report ID (2)

    0x05, 0x09,             //   Usage Page (Button)
    0x19, 0x01,             //   Usage Minimum (Button 1)
    0x29, 0x02,             //   Usage Maximum (Button 2)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x01,             //   Logical Maximum (1)
    0x95, 0x02,             //   Report Count (2)
    0x75, 0x01,             //   Report Size (1)
    0x81, 0x02,             //   Input (Data, Var, Abs)

    0x95, 0x01,             //   Report Count (1)
    0x75, 0x05,             //   Report Size (5)
    0x81, 0x03,             //   Input (Constant)

    0x06, 0x02, 0xFF,       //   Usage Page (Vendor 0xFF02)
    0x09, 0x20,             //   Usage (0x20)
    0x95, 0x01,             //   Report Count (1)
    0x75, 0x01,             //   Report Size (1)
    0x81, 0x03,             //   Input (Constant)

    0x05, 0x01,             //   Usage Page (Generic Desktop)
    0x09, 0x01,             //   Usage (Pointer)
    0xA1, 0x00,             //   Collection (Physical)
    0x15, 0x81,             //     Logical Minimum (-127)
    0x25, 0x7F,             //     Logical Maximum (127)
    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x06,             //     Input (Data, Var, Rel)

    0x05, 0x0C,             //     Usage Page (Consumer)
    0x0A, 0x38, 0x02,       //     Usage (AC Pan)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Var, Rel)

    0x05, 0x01,             //     Usage Page (Generic Desktop)
    0x09, 0x38,             //     Usage (Wheel)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Var, Rel)
    0xC0,                   //   End Collection (Physical)

    0x05, 0x06,             //   Usage Page (Generic Device Controls)
    0x09, 0x20,             //   Usage (Battery Strength)
    0x85, 0x47,             //   Report ID (0x47)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x64,             //   Logical Maximum (100)
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x01,             //   Report Count (1)
    0xB1, 0xA2,             //   Feature (Data, Var, Abs, NoPreferred)

    0x05, 0x06,             //   Usage Page (Generic Device Controls)
    0x09, 0x01,             //   Usage (0x01)
    0x85, 0x27,             //   Report ID (0x27)
    0x15, 0x01,             //   Logical Minimum (1)
    0x25, 0x41,             //   Logical Maximum (65)
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x2E,             //   Report Count (46)
    0x81, 0x06,             //   Input (Data, Var, Rel)

    // 19-byte vendor Feature — keeps total 135 bytes. Valid HID items only.
    0x06, 0x00, 0xFF,       //   Usage Page (Vendor 0xFF00)
    0x09, 0x01,             //   Usage (0x01)
    0x09, 0x02,             //   Usage (0x02)
    0x85, 0x67,             //   Report ID (0x67)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0xFF,             //   Logical Maximum (255)
    0x95, 0x07,             //   Report Count (7)
    0x75, 0x08,             //   Report Size (8)
    0xB1, 0x03,             //   Feature (Constant)

    0xC0,                   // End Collection
};

const ULONG g_HidDescriptorSize = sizeof(g_HidDescriptor);
