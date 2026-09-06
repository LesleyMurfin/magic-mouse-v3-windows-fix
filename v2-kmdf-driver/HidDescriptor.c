// SPDX-License-Identifier: MIT
//
// HID report descriptor injected into SDP attribute 0x0206 (HIDDescriptorList).
//
// Source: extracted byte-for-byte from Apple's applewirelessmouse.sys
//   SHA-256 08F33D7E...  offset 0xA850, 116 bytes.
//   Verified 2026-04-30 by Ghidra RE of FUN_14000A440.
//
// Layout (RID=0x02 report — 5 bytes of data after Report ID):
//   byte[0]  Report ID 0x02
//   byte[1]  2 buttons (bits 0-1) + 5-bit pad + 1-bit vendor pad (Page FF02)
//   byte[2]  X delta  INT8 relative
//   byte[3]  Y delta  INT8 relative
//   byte[4]  AC Pan   INT8 relative  (Consumer 0x0238, horizontal scroll)
//   byte[5]  Wheel    INT8 relative  (GD 0x38, vertical scroll)
//
// Additional reports (inside same Application collection):
//   RID=0x47  Feature, 1 byte — Battery Strength 0-100 (GDC page 0x06)
//   RID=0x27  Input,  46 bytes — Touch/gesture data (GDC page 0x06)
//
// Size: Apple's descriptor is 116 bytes. Padded to 135 bytes with reserved
// zero short items (HID spec §6.2.2.4: size specifier 0 = 0 bytes, tag 0 =
// reserved, safely ignored by all HID parsers). This matches the native
// Magic Mouse 2024 SDP HIDDescriptorList descriptor size exactly, so
// PatchSdpHidDescriptor operates as an in-place swap (delta=0) — no SDP
// sequence length fields need updating.
//
// Why 135 bytes (native size):
//   The SDP output buffer contains a Windows BTH_SDP_STREAM_RESPONSE header
//   (8 bytes: requiredSize + responseSize as two LE ULONGs) before the raw
//   SDP data. PatchSdpHidDescriptor's top-level length fix checks buf[0] for
//   0x35/0x36, but buf[0] is the first byte of the Windows header (0x09),
//   not the SDP sequence header (which is at buf[8]). With delta=0 (same
//   size swap) this fix is never needed — no SDP length fields change.

#include "HidDescriptor.h"

const UCHAR g_HidDescriptor[] = {
    // ---- Apple's original 116-byte descriptor (from applewirelessmouse.sys 0xA850) ----

    // TLC: Generic Desktop Mouse (0x01/0x02), Report ID 0x02
    0x05, 0x01,             // Usage Page (Generic Desktop)
    0x09, 0x02,             // Usage (Mouse)
    0xA1, 0x01,             // Collection (Application)
    0x85, 0x02,             //   Report ID (2)

    // 2 buttons — 2 × 1-bit fields
    0x05, 0x09,             //   Usage Page (Button)
    0x19, 0x01,             //   Usage Minimum (Button 1)
    0x29, 0x02,             //   Usage Maximum (Button 2)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x01,             //   Logical Maximum (1)
    0x95, 0x02,             //   Report Count (2)
    0x75, 0x01,             //   Report Size (1)
    0x81, 0x02,             //   Input (Data, Variable, Absolute)   — 2 bits

    // 5-bit generic padding
    0x95, 0x01,             //   Report Count (1)
    0x75, 0x05,             //   Report Size (5)
    0x81, 0x03,             //   Input (Constant)                   — 5 bits

    // 1-bit vendor padding (page FF02 usage 0x20) — total button byte = 8 bits
    0x06, 0x02, 0xFF,       //   Usage Page (Vendor 0xFF02)
    0x09, 0x20,             //   Usage (0x20)
    0x95, 0x01,             //   Report Count (1)
    0x75, 0x01,             //   Report Size (1)
    0x81, 0x03,             //   Input (Constant)                   — 1 bit

    // Pointer: X, Y (INT8 relative)
    0x05, 0x01,             //   Usage Page (Generic Desktop)
    0x09, 0x01,             //   Usage (Pointer)
    0xA1, 0x00,             //   Collection (Physical)
    0x15, 0x81,             //     Logical Minimum (-127)
    0x25, 0x7F,             //     Logical Maximum (127)
    0x09, 0x30,             //     Usage (X)
    0x09, 0x31,             //     Usage (Y)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x02,             //     Report Count (2)
    0x81, 0x06,             //     Input (Data, Variable, Relative) — 2 bytes

    // AC Pan (Consumer 0x0238) — horizontal scroll, INT8 relative
    0x05, 0x0C,             //     Usage Page (Consumer Devices)
    0x0A, 0x38, 0x02,       //     Usage (AC Pan 0x0238)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Variable, Relative) — 1 byte

    // Vertical Wheel (GD 0x38) — INT8 relative
    0x05, 0x01,             //     Usage Page (Generic Desktop)
    0x09, 0x38,             //     Usage (Wheel)
    0x75, 0x08,             //     Report Size (8)
    0x95, 0x01,             //     Report Count (1)
    0x81, 0x06,             //     Input (Data, Variable, Relative) — 1 byte

    0xC0,                   //   End Collection (Physical)

    // Battery Strength — Feature report RID=0x47 (GDC page 0x06, Usage 0x20)
    // Read via HidD_GetFeature; value 0-100 = battery percent.
    0x05, 0x06,             //   Usage Page (Generic Device Controls)
    0x09, 0x20,             //   Usage (Battery Strength)
    0x85, 0x47,             //   Report ID (0x47)
    0x15, 0x00,             //   Logical Minimum (0)
    0x25, 0x64,             //   Logical Maximum (100)
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x01,             //   Report Count (1)
    0xB1, 0xA2,             //   Feature (Data, Var, Abs, NoPreferredState)

    // Touch/gesture input — RID=0x27, 46 bytes (GDC page 0x06, Usage 0x01)
    // Raw touch surface data; consumed by higher-level gesture processing.
    0x05, 0x06,             //   Usage Page (Generic Device Controls)
    0x09, 0x01,             //   Usage (0x01)
    0x85, 0x27,             //   Report ID (0x27)
    0x15, 0x01,             //   Logical Minimum (1)
    0x25, 0x41,             //   Logical Maximum (65)
    0x75, 0x08,             //   Report Size (8)
    0x95, 0x2E,             //   Report Count (46)
    0x81, 0x06,             //   Input (Data, Variable, Relative)   — 46 bytes

    0xC0,                   // End Collection (Application)

    // ---- 19-byte padding to reach 135 bytes (native SDP descriptor size) ----
    // HID spec §6.2.2.4: size specifier 0 = 0 data bytes, type/tag 0 = reserved.
    // All compliant HID parsers (HidBth, mouhid, hid.sys) ignore these items.
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00,
};

const ULONG g_HidDescriptorSize = sizeof(g_HidDescriptor);
