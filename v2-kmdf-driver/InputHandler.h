// SPDX-License-Identifier: MIT
#pragma once

#include <ntddk.h>
#include <wdf.h>

// Scan an SDP attribute response for HIDDescriptorList (0x0206) and replace
// the embedded report descriptor with g_HidDescriptor[].
//
// Returns:
//   STATUS_SUCCESS                   — patched; *newLen = new byte count
//   STATUS_NOT_FOUND                 — 0x0206 not present (normal)
//   STATUS_BUFFER_TOO_SMALL          — pattern found; injected blob cannot fit
//   STATUS_MORE_PROCESSING_REQUIRED  — pattern found, other patch rejection
//   STATUS_INVALID_PARAMETER         — buf NULL or too small
NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(allocLen) PUCHAR  buf,
    _In_  ULONG  usedLen,
    _In_  ULONG  allocLen,
    _Out_ PULONG newLen);
