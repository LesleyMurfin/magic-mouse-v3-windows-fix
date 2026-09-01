// SPDX-License-Identifier: MIT
#pragma once

#include <ntddk.h>
#include <wdf.h>

// Scan an SDP attribute response for HIDDescriptorList (0x0206) and replace
// the embedded report descriptor.
//
// Returns:
//   STATUS_SUCCESS                   — patched; *newLen = new byte count
//   STATUS_NOT_FOUND                 — 0x0206 not present (normal)
//   STATUS_MORE_PROCESSING_REQUIRED  — pattern found, patch rejected
//   STATUS_INVALID_PARAMETER         — buf NULL or too small
NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG  bufSize,
    _Out_ PULONG newLen);

NTSTATUS
SdpRewrite_ProcessEx(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG  bufSize,
    _Out_ PULONG newLen,
    _In_reads_bytes_(descSize) const UCHAR *desc,
    _In_  ULONG  descSize);
