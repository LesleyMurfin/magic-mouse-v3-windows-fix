// SPDX-License-Identifier: MIT
#pragma once
#include "Driver.h"

// Native v3 overlay, 135 bytes (sizeof == 0x87). No 0x00 pad.
//   COL01 RID 0x12 — buttons, X 0x0030, Y 0x0031,
//     Count 1 AC Pan 0x0238 (byte 6) then Count 1 Wheel 0x0038 (byte 7)
//   COL02 RID 0x90 — battery Input (HidD_GetInputReport; percent at byte[2])
// Keep 0x85 0x90 and 0x09 0x38. Never Feature 0x47; never RID 0x02.
// Do not inherit X/Y Report Count 2 onto Wheel.
extern const UCHAR g_HidDescriptor[];
extern const ULONG g_HidDescriptorSize;
