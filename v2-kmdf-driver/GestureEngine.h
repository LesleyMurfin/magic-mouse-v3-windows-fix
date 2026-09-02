// SPDX-License-Identifier: MIT
// GestureEngine.h — M14: RID 0x12 (MOUSE2_REPORT_ID) to RID 0x02 scroll translation.
// Port of Linux drivers/hid/hid-magicmouse.c magicmouse_emit_touch() +
// magicmouse_raw_event() MOUSE2 case.
#pragma once
#include "Driver.h"

// MM2_HEADER_LEN: minimum valid RID 0x12 (MOUSE2_REPORT_ID) buffer length.
// Format: 1-byte RID + 13-byte header = 14 bytes with 0 touch points.
#define MM2_HEADER_LEN 14

// SCROLL_THRESHOLD: accumulated Y (or X) delta required to emit one WM_MOUSEWHEEL tick.
// Linux default is 256 (in 1/1000 mm units). Start conservative; tune empirically.
#define SCROLL_THRESHOLD 256

// TranslateMouse2ToHid
//
// Translates a RID 0x12 (MOUSE2_REPORT_ID) buffer from v3 multi-touch surface into
// a standard RID 0x02 mouse report (5 bytes: RID, buttons, X_lo, X_hi, Wheel).
//
// in:       RID 0x12 buffer (from IOCTL_HID_READ_REPORT completion)
// inLen:    buffer length (must be >= 14 for header, 14+8*N for N touch points)
// out:      caller-supplied 5-byte buffer for RID 0x02 output
// outLen:   in = sizeof(out) = 5; out = 5 on success, 0 if no scroll this report
// ctx:      device context (scroll accumulators stored here)
//
// Returns STATUS_SUCCESS if translation produced output (outLen=5).
//         STATUS_NO_MORE_ENTRIES if the report should pass through unchanged (outLen=0).
NTSTATUS TranslateMouse2ToHid(
    _In_reads_bytes_(inLen)     PUCHAR in,
    _In_                        SIZE_T inLen,
    _Out_writes_bytes_all_(5)   PUCHAR out,
    _Inout_                     PULONG outLen,
    _Inout_                     PDEVICE_CONTEXT ctx
);
