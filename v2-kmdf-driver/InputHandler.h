// SPDX-License-Identifier: MIT
// SdpRewrite — SDP attribute 0x0206 (HIDDescriptorList) descriptor injection.
//
// Public entry point called from OnSdpQueryComplete (Driver.c) after
// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE completes. Scans the SDP response
// buffer for attribute 0x0206, replaces the embedded HID descriptor with
// g_HidDescriptor[] (Descriptor C: RID=0x02 scroll + RID=0x90 battery).
#pragma once

#include <ntddk.h>
#include <wdf.h>

// SdpRewrite_Process — scan buf[0..bufSize) for SDP attribute 0x0206 and
// replace the embedded HID descriptor with g_HidDescriptor[].
//
// Returns:
//   STATUS_SUCCESS                 — patch applied; *newLen = new byte count
//   STATUS_NOT_FOUND               — attribute 0x0206 not present; passthrough
//   STATUS_MORE_PROCESSING_REQUIRED — pattern found but patch validation failed
//   STATUS_INVALID_PARAMETER       — buf NULL or bufSize too small to scan
NTSTATUS
SdpRewrite_Process(
    _Inout_updates_bytes_(bufSize) PUCHAR  buf,
    _In_  ULONG  bufSize,
    _Out_ PULONG newLen);
