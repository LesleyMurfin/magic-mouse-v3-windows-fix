// SPDX-License-Identifier: MIT
//
// M14 — RID=0x27 raw byte capture layer (on top of M13 SDP injection).
//
// Stack position (lower filter between BTHENUM and HidBth):
//   HidClass → HidBth → [M13 (this)] → BTHENUM
//
// Mechanism (confirmed 2026-04-30 by Ghidra RE of applewirelessmouse.sys
// SHA-256 08F33D7E... FUN_14000A440):
//
//   Apple's driver intercepts IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE (0x410210)
//   in a completion routine and rewrites SDP attribute 0x0206 (HIDDescriptorList)
//   with its own 116-byte descriptor. M13 replicates this mechanism but injects
//   Descriptor C — RID=0x02 scroll mouse + RID=0x90 vendor battery — giving
//   both scroll AND battery readout on Magic Mouse 2024 (PID 0x0323).
//
// Why M12 failed:
//   M12 intercepted IOCTL_INTERNAL_BTH_SUBMIT_BRB (0x410003). BRB submits carry
//   L2CAP connection/transfer traffic but NOT the SDP attribute response that
//   carries the HID descriptor. The SDP layer is above that. Wrong IOCTL.

#pragma once

#include <ntddk.h>
#include <wdf.h>

// 'M13D' little-endian — pool tag for all M13 allocations
#define M13_POOL_TAG 'D31M'

// Known Apple Magic Mouse Bluetooth Product IDs.
// Used by ProductId PID guard in OnSdpQueryComplete (PR-SS-1).
#define MM_PID_V3   0x0323u   // Magic Mouse 2024 (USB-C) — Descriptor C target
#define MM_PID_V1A  0x030Du   // Magic Mouse 2 (Lightning, batch A)
#define MM_PID_V1B  0x0310u   // Magic Mouse 2 (Lightning, batch B)

// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE
// CTL_CODE(FILE_DEVICE_BLUETOOTH=0x41, Function=0x84, METHOD_BUFFERED=0, FILE_ANY_ACCESS=0)
// Confirmed via RE: FUN_14000A440 checks Irp+0xB8+0x18 (IoControlCode) against this value.
#define IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE 0x00410210UL

// --------------------------------------------------------------------------
// Device context — per-device state
// --------------------------------------------------------------------------

typedef struct _DEVICE_CONTEXT
{
    WDFSPINLOCK Lock;   // protects all mutable fields below

    // Configuration: read from Services\MagicMouseDriver\Parameters at AddDevice.
    // Default TRUE (inject) if Parameters key or value is absent.
    BOOLEAN EnableInjection;

    // BT Product ID — populated at AddDevice via IoGetDeviceProperty on PDO.
    // 0x0323 = Magic Mouse 2024 (v3) — receives Descriptor C injection.
    // 0x030D / 0x0310 = Magic Mouse 2 (v1) — pass through native descriptor.
    // 0 = unknown (PID could not be read) — injection allowed (safe fallback,
    //     preserves prior behaviour for any device not positively identified as v1).
    USHORT  ProductId;

    // Diagnostic counters (inspectable via Services\MagicMouseDriver\Diag).
    ULONG   IoctlInterceptCount;   // 0x410210 IOCTLs intercepted
    ULONG   SdpScanHits;           // attribute 0x0206 pattern found in buffer
    ULONG   SdpPatchSuccess;       // descriptor replacement succeeded
    ULONG   LastSdpBufSize;        // size of most recent SDP output buffer
    ULONG   LastPatchStatus;       // NTSTATUS of most recent PatchSdpHidDescriptor
    UCHAR   LastSdpBytes[64];      // first 64 raw bytes of most recent SDP buffer

    // M14: HID READ intercept counters + ring buffer (flushed to registry by DiagWorkItem)
    ULONG   HidReadCount;          // total IRP_MJ_READ completions seen
    ULONG   Rid27Count;            // completions where buf[0] == 0x27
    ULONG   Rid27LoggedCount;      // how many RID=0x27 reports were DbgPrinted

    // Ring buffer: last 8 RID=0x27 raw reports (48 bytes each).
    // Work item flushes as Rid27RingBuf REG_BINARY (8×48=384 bytes).
    // PowerShell reads without needing DebugView.
#define RID27_RING_SLOTS 8
#define RID27_BYTES_PER_SLOT 48
    UCHAR   Rid27Ring[RID27_RING_SLOTS][RID27_BYTES_PER_SLOT];
    ULONG   Rid27RingNext;         // next write slot (0..7, wraps mod 8)

    // M14: scroll accumulators — persistent across RID 0x12 reports (GestureEngine.c)
    INT ScrollAccumY;   // accumulated Y delta, reset by SCROLL_THRESHOLD
    INT ScrollAccumX;   // accumulated X delta (horizontal scroll)
    ULONG Rid12Count;   // RID 0x12 reports seen (replaces legacy Rid27Count naming)

    WDFTIMER    DiagTimer;         // 1 Hz periodic
    WDFWORKITEM DiagWorkItem;      // PASSIVE_LEVEL flush to registry

} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetDeviceContext)

// --------------------------------------------------------------------------
// Function declarations
// --------------------------------------------------------------------------

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD               EvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL EvtIoInternalDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL      EvtIoDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEFAULT             EvtIoDefault;
EVT_WDF_IO_QUEUE_IO_READ                EvtIoRead;
EVT_WDF_REQUEST_COMPLETION_ROUTINE      OnSdpQueryComplete;
EVT_WDF_REQUEST_COMPLETION_ROUTINE      OnReadComplete;
EVT_WDF_TIMER                           M13_DiagTimerFunc;
EVT_WDF_WORKITEM                        M13_DiagWorkItemFunc;
