// SPDX-License-Identifier: MIT
#pragma once

#include "Driver.h"

// TRUE if buf looks like a Bluetooth HID input carrying MOUSE2 RID 0x12
// (raw 0x12 or HID DATA+INPUT 0xA1 0x12). On TRUE, *newLen is the rewritten
// length (6 or 7). Buffer is mutated in place.
BOOLEAN
TranslateAclHidReport(
    _Inout_updates_bytes_(len) PUCHAR buf,
    _In_ ULONG len,
    _Out_ PULONG newLen,
    _Inout_ PDEVICE_CONTEXT ctx);
