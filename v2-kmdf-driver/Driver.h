// SPDX-License-Identifier: MIT
//
// MagicMouseDriver — KMDF lower filter for Apple Magic Mouse PID 0x0323 only.
//
// Stack:
//   hidclass.sys → HidBth.sys → [this filter] → BthEnum PDO
//
// Two jobs:
//   1. SDP: rewrite HIDDescriptorList (0x0206) to Descriptor C (RID 0x02 mouse)
//      so hidclass/mouhid bind a standard mouse. Same IOCTL Apple uses
//      (IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE = 0x410210).
//   2. Reports: Magic Mouse 2/USB-C (0323) sends MOUSE2_REPORT_ID 0x12, not
//      RID 0x02. Live 2.0.2.0 injected the descriptor then left 0x12 untouched,
//      so HID started and the pointer did not move. Translate 0x12 → 6-byte
//      RID 0x02 (buttons, X, Y, AC Pan, Wheel) on:
//        - IRP_MJ_READ completions (backup; hidclass reads usually stop at HidBth)
//        - BRB_L2CA_ACL_TRANSFER completions (the path HidBth actually uses)
//
// Sole filter. Do not stack with applewirelessmouse (v1 binary is a 0xD1
// ship-blocker). This package does not bind PID 0x030D / 0x0269.

#pragma once

#include <ntddk.h>
#include <wdf.h>

#define MM_POOL_TAG 'DMgm'

// Magic Mouse 2024 / Magic Mouse 2 USB-C — the only PID this package binds.
#define MM_PID_V3  0x0323u

// IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE
// CTL_CODE(FILE_DEVICE_BLUETOOTH=0x41, Function=0x84, METHOD_BUFFERED, FILE_ANY_ACCESS)
#define IOCTL_BTH_SDP_SERVICE_SEARCH_ATTRIBUTE 0x00410210UL

// IOCTL_INTERNAL_BTH_SUBMIT_BRB (bthioctl.h) — METHOD_NEITHER.
#ifndef IOCTL_INTERNAL_BTH_SUBMIT_BRB
#define IOCTL_INTERNAL_BTH_SUBMIT_BRB 0x00410003UL
#endif

// BRB_L2CA_ACL_TRANSFER (bthddi.h). Defined here so the source builds against
// a WDK that has bthddi.h and so reviewers can see the constant without
// opening the SDK.
#ifndef BRB_L2CA_ACL_TRANSFER
#define BRB_L2CA_ACL_TRANSFER 0x0105
#endif

#ifndef ACL_TRANSFER_DIRECTION_IN
#define ACL_TRANSFER_DIRECTION_IN 0x00000001UL
#endif

// Injected RID 0x02 report: [RID][buttons][X][Y][AC Pan][Wheel] = 6 bytes.
#define MM_MOUSE_REPORT_LEN 6

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
