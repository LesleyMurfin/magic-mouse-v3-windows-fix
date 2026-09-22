// SPDX-License-Identifier: MIT
#pragma once

#include <ntddk.h>
#include <wdf.h>

// Same-size SDP overlay. Find the native v3 HIDDescriptorList prefix
//   09 02 06 35 8D 35 8B 08 22 25 87
// and RtlCopyMemory g_HidDescriptor[0x87] over the TEXT_STRING body.
// Never writes 0x35 / 0x36 / 0x25 / buf[4]. Δ = 0.
// Fail-closed is no mutation (buffer unchanged).
//
// Returns:
//   STATUS_SUCCESS           — overlaid; *newLen = usedLen
//   STATUS_NOT_FOUND         — prefix not present (buffer unchanged)
//   STATUS_BUFFER_TOO_SMALL  — prefix found; 135-byte body does not fit
//   STATUS_INVALID_PARAMETER — buf NULL, allocLen < usedLen, or sizeof != 0x87
NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(allocLen) PUCHAR  buf,
    _In_  ULONG  usedLen,
    _In_  ULONG  allocLen,
    _Out_ PULONG newLen);
