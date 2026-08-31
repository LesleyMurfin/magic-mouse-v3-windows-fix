// SPDX-License-Identifier: MIT
#pragma once
#include "Driver.h"

// Live-aligned descriptor (2026-08-30 HID on Apr 30 MagicMouseFix):
//   COL01 Input RID 0x12 — buttons, X, Y, AC Pan, Wheel
//   COL02 Input RID 0x90 — battery (HidD_GetInputReport; percent at byte[2])
// Do not inject RID 0x02 / Feature 0x47 — hidclass never bound those.
extern const UCHAR g_HidDescriptor[];
extern const ULONG g_HidDescriptorSize;
