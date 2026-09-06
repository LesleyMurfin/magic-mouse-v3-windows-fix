// SPDX-License-Identifier: MIT
//
// MagicKbDesc — KMDF lower filter on BTHENUM\{HID-PSM}_VID&05AC_PID&{Apple kb whitelist}.
//
// Patches the HID Report Descriptor returned by hidbth.sys so the
// Windows HID class driver (hidclass.sys) treats RID 0x47 (Battery
// Strength) as BOTH an Input and a Feature report.
//
// 4-byte insert: `09 20 B1 02` immediately before the closing
// `c0 c0` of Col02. Re-emits the Battery Strength Usage (local item,
// consumed by the previous Input main item) and adds a Feature main
// item with the same global attributes (8-bit, count 1, range 0..255).
//
// Empirical proof of approach (2026-05-08):
//   HidD_GetFeature(Col03, RID=0x09, len=4) → SUCCESS [92 12 02 02]
//   Confirms Windows BT HID can issue Feature GET_REPORTs to this
//   firmware over L2CAP — the only blocker for RID 0x47 is the
//   missing Feature declaration in the descriptor.

#pragma once

#include <ntddk.h>
#include <wdf.h>
#include <hidport.h>

EXTERN_C_START

DRIVER_INITIALIZE  DriverEntry;

EVT_WDF_DRIVER_DEVICE_ADD               MagicKbDescEvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL  MagicKbDescEvtIoInternalDeviceControl;

// Completion routine: invoked when the lower stack fills the report
// descriptor buffer; we patch the bytes here.
EVT_WDF_REQUEST_COMPLETION_ROUTINE      MagicKbDescDescriptorCompletion;

// Completion routine for IOCTL_HID_GET_DEVICE_DESCRIPTOR - bumps the
// HID_DESCRIPTOR.DescriptorList[0].wReportLength by the number of bytes
// we are about to insert into the report descriptor, so hidclass.sys
// allocates a large-enough buffer for the subsequent
// IOCTL_HID_GET_REPORT_DESCRIPTOR.
EVT_WDF_REQUEST_COMPLETION_ROUTINE      MagicKbDescDeviceDescriptorCompletion;

// Patch driver: returns the new buffer length, or 0 if no patch was
// applicable (e.g. this collection's descriptor doesn't match Col02).
// Patches in-place if buffer is large enough; otherwise the caller must
// reallocate.
SIZE_T
MagicKbDescPatchDescriptor(
    _Inout_updates_bytes_(BufferCapacity) PUCHAR Buffer,
    _In_                                  SIZE_T OriginalLength,
    _In_                                  SIZE_T BufferCapacity
    );

// The 4-byte payload we insert: re-emit Battery Strength Usage +
// Feature main item with same global attributes carried from previous
// Input declaration.
extern const UCHAR g_FeatureInsertBytes[4];

#define MAGICKBDESC_POOL_TAG  'cDkM'  // "MkDc" reversed (NT pool tags are little-endian)

EXTERN_C_END
