// SPDX-License-Identifier: MIT
#pragma once
#include "Driver.h"

// Descriptor C: RID 0x02 mouse (X/Y/AC Pan/Wheel) + RID 0x47 battery Feature
// + RID 0x27 touch Input. Injected into SDP attribute 0x0206.
extern const UCHAR g_HidDescriptor[];
extern const ULONG g_HidDescriptorSize;
