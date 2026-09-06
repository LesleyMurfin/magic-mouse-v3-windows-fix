// SPDX-License-Identifier: MIT
#pragma once
#include "Driver.h"

// Descriptor C: RID=0x02 scroll mouse TLC + RID=0x90 vendor battery TLC.
// Injected into SDP attribute 0x0206 (HIDDescriptorList) by M13.
extern const UCHAR g_HidDescriptor[];
extern const ULONG g_HidDescriptorSize;
