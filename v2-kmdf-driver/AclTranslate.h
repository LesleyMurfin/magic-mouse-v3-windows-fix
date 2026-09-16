// SPDX-License-Identifier: MIT
#pragma once

#include "Driver.h"

// TRUE if buf looks like a Bluetooth HID input carrying MOUSE2 RID 0x12
// (raw 0x12 or HID DATA+INPUT 0xA1 0x12). On TRUE, *newLen is the rewritten
// length (8, or 9 with 0xA1) and is always <= capacity. Buffer is mutated
// in place only when capacity can hold the 8-byte (or 9-byte) report.
// Native 6-byte X/Y is left intact when there is no room to grow (pointer-safe).
// RID 0x90 is not rewritten.
BOOLEAN
TranslateAclHidReport(
    _Inout_updates_bytes_(capacity) PUCHAR buf,
    _In_ ULONG receivedLen,
    _In_ ULONG capacity,
    _Out_ PULONG newLen,
    _Inout_ PDEVICE_CONTEXT ctx);
