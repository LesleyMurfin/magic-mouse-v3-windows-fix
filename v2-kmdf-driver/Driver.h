// SPDX-License-Identifier: MIT
//
// MagicMouseDriver — KMDF lower filter for Apple Magic Mouse PID 0x0323 only.
//
// Stack:
//   hidclass.sys → HidBth.sys → [this filter] → BthEnum PDO
//
// Two jobs:
//   1. SDP: rewrite HIDDescriptorList (0x0206) so COL01 RID 0x12 KEEPS
//      Apr 30 pointer usages X/Y (GD 0x0030 / 0x0031) and ADDS Wheel
//      (GD 0x0038) + AC Pan (Consumer 0x0238) as extras. Live HID
//      2026-08-30 21:23 MDT (Apr 30 MagicMouseFix AD5D244B): COL01 Input
//      0x12 is X/Y only — that is why the pointer moves and scroll does
//      not. HidBth delivers 0x12. Descriptor C (RID 0x02 + Feat 0x47)
//      is not what hidclass bound. Same IOCTL Apple uses
//      (IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE = 0x410210).
//   2. Reports: stay on RID 0x12. Fill Wheel/AC Pan from the 14+8*N touch
//      block (Linux hid-magicmouse MOUSE2). Do not convert to 0x02.
//      Battery is RID 0x90 Input on COL02 (HidD_GetInputReport; percent
//      at byte[2]). Feat 0x47 fails on COL01 and COL02.
//      Paths:
//        - BRB_L2CA_ACL_TRANSFER completions (the path HidBth actually uses)
//        - IRP_MJ_READ completions (backup; hidclass reads usually stop at HidBth)
//
// Sole filter. Do not stack with applewirelessmouse (v1 binary is a 0xD1
// ship-blocker). This package does not bind PID 0x030D / 0x0269.

#pragma once

#include <ntddk.h>
#include <wdf.h>

#define MM_POOL_TAG 'DMgm'

// FileVersion / package label. INF dest is unique so Apr 30 MagicMouseDriver.sys
// (oem16 / AD5D244B) is not replaced or hardlinked.
#define MM_FILE_VERSION_STR     "2.0.4.1"
#define MM_ARTIFACT_SYS_PATTERN "MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys"
#define MM_INF_SYS_NAME         "MagicMouseDriver-kmdf-204-scroll.sys"

// Magic Mouse 2024 / Magic Mouse 2 USB-C — the only PID this package binds.
#define MM_PID_V3  0x0323u

// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE
// CTL_CODE(FILE_DEVICE_BLUETOOTH=0x41, Function=0x84, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE 0x00410210UL

// IOCTL_INTERNAL_BTH_SUBMIT_BRB (bthioctl.h) — METHOD_NEITHER.
#ifndef IOCTL_INTERNAL_BTH_SUBMIT_BRB
#define IOCTL_INTERNAL_BTH_SUBMIT_BRB 0x00410003UL
#endif

// BRB_L2CA_ACL_TRANSFER / ACL_TRANSFER_DIRECTION_IN come from bthddi.h
// (included in Driver.c). Do not #define 14393 literals here — they
// shadow the WDK enum and pick the wrong layout on current Windows 11.

// Injected RID 0x12 report:
//   [RID 0x12][buttons][X i16][Y i16][AC Pan][Wheel] = 8 bytes.
#define MM_MOUSE_REPORT_LEN 8

#define MM_TOUCH_SLOTS 16

typedef struct _DEVICE_CONTEXT
{
    WDFSPINLOCK Lock;

    BOOLEAN EnableInjection;
    USHORT  ProductId;          // 0x0323, or 0 if HardwareId could not be read

    ULONG   IoctlInterceptCount;
    ULONG   SdpScanHits;
    ULONG   SdpPatchSuccess;
    ULONG   LastSdpBufSize;
    ULONG   LastPatchStatus;
    UCHAR   LastSdpBytes[64];

    ULONG   HidReadCount;
    ULONG   Rid12Count;
    ULONG   AclInterceptCount;
    ULONG   AclTranslateCount;

    // Surface-scroll anchors (Linux hid-magicmouse emit_touch style).
    INT16   TouchAnchorY[MM_TOUCH_SLOTS];
    INT16   TouchAnchorX[MM_TOUCH_SLOTS];
    BOOLEAN TouchAnchorValid[MM_TOUCH_SLOTS];

    WDFTIMER    DiagTimer;
    WDFWORKITEM DiagWorkItem;

} DEVICE_CONTEXT, *PDEVICE_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetDeviceContext)

// Per-request stash so BRB completion uses the same PBRB HidBth submitted
// (do not re-read the IRP stack in the completion routine).
typedef struct _MM_REQUEST_CONTEXT
{
    PVOID Brb;   // PBRB, typed as PVOID so Driver.h does not include bthddi.h
} MM_REQUEST_CONTEXT, *PMM_REQUEST_CONTEXT;

WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(MM_REQUEST_CONTEXT, GetRequestContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD               EvtDeviceAdd;
EVT_WDF_IO_QUEUE_IO_INTERNAL_DEVICE_CONTROL EvtIoInternalDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL      EvtIoDeviceControl;
EVT_WDF_IO_QUEUE_IO_DEFAULT             EvtIoDefault;
EVT_WDF_IO_QUEUE_IO_READ                EvtIoRead;
EVT_WDF_REQUEST_COMPLETION_ROUTINE      OnSdpQueryComplete;
EVT_WDF_REQUEST_COMPLETION_ROUTINE      OnReadComplete;
EVT_WDF_REQUEST_COMPLETION_ROUTINE      OnAclTransferComplete;
EVT_WDF_TIMER                           MmDiagTimerFunc;
EVT_WDF_WORKITEM                        MmDiagWorkItemFunc;
