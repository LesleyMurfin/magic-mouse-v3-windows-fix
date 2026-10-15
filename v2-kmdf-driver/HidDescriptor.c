// SPDX-License-Identifier: MIT
//
// Native v3 HID overlay, 135 bytes (0x87). No 0x00 pad.
// Peer-review 2026-09-01: do NOT inherit X/Y Report Count 2 onto Wheel.
// After X/Y: Count 1, Logical -127..127, AC Pan (byte 6) then Wheel (byte 7).
// Stay 0x87: drop X/Y Physical/Unit; Feature 0xF1 Count 2 vendor FF00
// Usage 01 Logical Min 0 (not GD Wheel). Keep 0x85 0x90. No 0x85 0x47 / 0x85 0x02.
//
// COL01 RID 0x12: buttons, X 0x0030, Y 0x0031, AC Pan 0x0238, Wheel 0x0038.
// COL02 RID 0x90: battery Input (HidD_GetInputReport; percent at byte[2]).
// Same-size overlay only — SDP prefix 09 02 06 35 8D 35 8B 08 22 25 87
// stays untouched; this blob replaces the 135-byte TEXT_STRING body.

#include "HidDescriptor.h"

const UCHAR g_HidDescriptor[] = {
    // ---- COL01: Mouse, Report ID 0x12 ----
    0x05, 0x01,             // Usage Page (Generic Desktop)
    0x09, 0x02,             // Usage (Mouse)
    0xA1, 0x01,             // Collection (Application)
    0x85, 0x12,             //   Report ID (0x12)

    0x05, 0x09,             //   Usage Page (Button)
    0x19, 0x01,             //   Usage Minimum (Button 1)
    0x29, 0x02,             //   Usage Maximum (Button 2)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x01,             //   Logical Maximum (1)
    0x95, 0x02,             //   Report Count (2)
    0x75, 0x01,             //   Report Size (1)
    0x81, 0x02,             //   Input (Data, Var, Abs)
    0x95, 0x01,             //   Report Count (1)
    0x75, 0x06,             //   Report Size (6)
    0x81, 0x03,             //   Input (Constant)

    0x05, 0x01,             //   Usage Page (Generic Desktop)
    0x09, 0x01,             //   Usage (Pointer)
    0xA1, 0x00,             //   Collection (Physical)
    0x16, 0x01, 0xF8,       //     Logical Minimum (-2047)
    0x26, 0xFF, 0x07,       //     Logical Maximum (2047)
    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x75, 0x10,             //     Report Size (16)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x06,             //     Input (Data, Var, Rel)

    0x15, 0x81,             //     Logical Minimum (-127)
    0x25, 0x7F,             //     Logical Maximum (127)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1) — reset; do not inherit 2
    0x05, 0x0C,             //     Usage Page (Consumer)
    0x0A, 0x38, 0x02,       //     Usage (AC Pan) — report byte 6
    0x81, 0x06,             //     Input (Data, Var, Rel)
    0x05, 0x01,             //     Usage Page (Generic Desktop)
    0x09, 0x38,             //     Usage (Wheel) — report byte 7
    0x81, 0x06,             //     Input (Data, Var, Rel)
    0xC0,                   //   End Collection (Physical)

    0x06, 0x00, 0xFF,       //   Usage Page (Vendor 0xFF00)
    0x09, 0x01,             //   Usage (1)
    0x85, 0xF1,             //   Report ID (0xF1) Linux feature_mt_mouse2
    0x15, 0x00,             //   Logical Minimum (0)
    0x95, 0x02,             //   Report Count (2)
    0xB1, 0x02,             //   Feature (Data, Var, Abs)
    0xC0,                   // End Collection (Application)

    // ---- COL02: Battery, Report ID 0x90 Input ----
    0x06, 0x00, 0xFF,       // Usage Page (Vendor 0xFF00)
    0x09, 0x14,             // Usage (0x14)
    0xA1, 0x01,             // Collection (Application)
    0x85, 0x90,             //   Report ID (0x90)
    0x05, 0x84,             //   Usage Page (Power Device)
    0x75, 0x01,             //   Report Size (1)
    0x95, 0x03,             //   Report Count (3)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x01,             //   Logical Maximum (1)
    0x09, 0x61,             //   Usage (Present)
    0x05, 0x85,             //   Usage Page (Battery System)
    0x09, 0x44,             //   Usage (Charging)
    0x09, 0x46,             //   Usage (Discharging)
    0x81, 0x02,             //   Input (Data, Var, Abs)
    0x95, 0x05,             //   Report Count (5)
    0x81, 0x01,             //   Input (Constant)
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x01,             //   Report Count (1)
    0x15, 0x00,             //   Logical Minimum (0)
    0x26, 0xFF, 0x00,       //   Logical Maximum (255)
    0x09, 0x65,             //   Usage (Relative State of Charge)
    0x81, 0x02,             //   Input (Data, Var, Abs)
    0xC0,                   // End Collection
};

C_ASSERT(sizeof(g_HidDescriptor) == 0x87);

const ULONG g_HidDescriptorSize = sizeof(g_HidDescriptor);
