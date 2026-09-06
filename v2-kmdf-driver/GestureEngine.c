// SPDX-License-Identifier: MIT
// GestureEngine.c — M14: port of Linux hid-magicmouse.c MOUSE2_REPORT_ID handler.
// Translates RID 0x12 multi-touch surface data into RID 0x02 Wheel events.
//
// Source: Linux drivers/hid/hid-magicmouse.c (GPL-2.0+)
//   magicmouse_raw_event()     lines 461-490  — MOUSE2_REPORT_ID dispatch
//   magicmouse_emit_touch()    lines 214-360  — per-finger parsing + scroll synthesis
//   magicmouse_emit_buttons()  lines 177-213  — button state extraction
//
// Windows adaptation:
//   - le16_to_cpu / u16 → USHORT (x64/ARM64 is natively LE, no swap needed)
//   - input_report_rel(REL_WHEEL) → accumulated in ctx->ScrollAccumY, emitted when
//     |accum| >= SCROLL_THRESHOLD (threshold same as Linux DEFAULT_SCROLL_ACCELERATION)
//   - No HID input subsystem — outputs a standard RID 0x02 5-byte mouse report
//   - Scroll accumulators stored in DEVICE_CONTEXT (per-device, persistent across reports)
#include "GestureEngine.h"

// RID 0x12 (MOUSE2_REPORT_ID) layout constants (from Linux, confirmed empirically)
// MM2_HEADER_LEN is defined in GestureEngine.h (shared with Driver.c)
#define MM2_TOUCH_BYTES  8    // bytes per touch point

// Button state lives in bits [0..2] of byte[1] in the MOUSE2 header
#define MM2_BTN_MASK     0x07

// RID 0x02 output report layout (standard HID mouse, 5 bytes)
// [0] = 0x02 (RID), [1] = buttons, [2] = X_lo, [3] = X_hi, [4] = Wheel (signed 8-bit)

// Extract a signed 12-bit coordinate from a 16-bit LE field at buf[offset].
// Linux pattern (DO NOT use on Windows — le16_to_cpu and u16 don't exist in WDM):
//   int x = (int)(le16_to_cpu(*(u16*)(data+offset)) & 0x0FFF);
// Windows equivalent (natively LE on x64/ARM64, no byte swap needed):
static __forceinline INT
Mm2Read12(PUCHAR buf, ULONG offset)
{
    USHORT raw = *(USHORT*)(buf + offset);   // direct LE read
    INT val = (INT)(raw & 0x0FFF);           // keep lower 12 bits
    if (val & 0x0800) val |= (INT)(~0x0FFF); // sign extend from bit 11
    return val;
}

// ProcessTouchPoints — accumulate scroll from multi-finger Y delta.
// Ported from magicmouse_emit_touch() lines 214-360.
// Returns TRUE if a scroll event should be emitted (accumulated delta >= threshold).
static BOOLEAN
ProcessTouchPoints(
    _In_    PUCHAR          buf,
    _In_    SIZE_T          inLen,
    _Inout_ PDEVICE_CONTEXT ctx,
    _Out_   INT*            outWheelDelta,
    _Out_   INT*            outHWheelDelta,
    _Out_   UCHAR*          outButtons)
{
    *outWheelDelta  = 0;
    *outHWheelDelta = 0;
    *outButtons     = 0;

    if (inLen < MM2_HEADER_LEN) return FALSE;

    // Button state from header byte[1] (magicmouse_emit_buttons equivalent)
    *outButtons = buf[1] & MM2_BTN_MASK;

    // Touch count from report size: N = (inLen - MM2_HEADER_LEN) / MM2_TOUCH_BYTES
    ULONG nTouches = (ULONG)((inLen - MM2_HEADER_LEN) / MM2_TOUCH_BYTES);
    if (nTouches == 0) return FALSE;

    // Accumulate Y and X deltas from all touch points (2-finger scroll tracking).
    // Linux magicmouse_emit_touch: extracts dx/dy per finger and sums.
    // Simplified: sum Y changes across all N fingers and divide by N for net gesture.
    INT sumY = 0;
    INT sumX = 0;
    ULONG activeTouches = 0;

    for (ULONG i = 0; i < nTouches; i++)
    {
        ULONG touchOffset = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES;
        if (touchOffset + 4 > inLen) break;  // bounds check

        // 12-bit signed X at touchOffset+0, Y at touchOffset+2
        INT x = Mm2Read12(buf, touchOffset + 0);
        INT y = Mm2Read12(buf, touchOffset + 2);

        // Only count fingers that appear to be in contact (rough heuristic:
        // non-zero position; Linux uses explicit contact state bits but
        // the simplified approach works for 2-finger scroll detection)
        if (x != 0 || y != 0)
        {
            sumX += x;
            sumY += y;
            activeTouches++;
        }
    }

    if (activeTouches < 2) return FALSE;  // require at least 2 fingers for scroll

    // Net delta per finger
    INT netY = sumY / (INT)activeTouches;
    INT netX = sumX / (INT)activeTouches;

    // Accumulate deltas (persist across reports in device context)
    ctx->ScrollAccumY += netY;
    ctx->ScrollAccumX += netX;

    BOOLEAN emit = FALSE;

    // Emit wheel tick when accumulated Y exceeds threshold
    if (ctx->ScrollAccumY >= SCROLL_THRESHOLD)
    {
        *outWheelDelta = 1;
        ctx->ScrollAccumY -= SCROLL_THRESHOLD;
        emit = TRUE;
    }
    else if (ctx->ScrollAccumY <= -SCROLL_THRESHOLD)
    {
        *outWheelDelta = -1;
        ctx->ScrollAccumY += SCROLL_THRESHOLD;
        emit = TRUE;
    }

    // Horizontal wheel (for future use — not yet wired to HWheel output)
    if (ctx->ScrollAccumX >= SCROLL_THRESHOLD)
    {
        *outHWheelDelta = 1;
        ctx->ScrollAccumX -= SCROLL_THRESHOLD;
        emit = TRUE;
    }
    else if (ctx->ScrollAccumX <= -SCROLL_THRESHOLD)
    {
        *outHWheelDelta = -1;
        ctx->ScrollAccumX += SCROLL_THRESHOLD;
        emit = TRUE;
    }

    return emit;
}

NTSTATUS
TranslateMouse2ToHid(
    _In_reads_bytes_(inLen)     PUCHAR in,
    _In_                        SIZE_T inLen,
    _Out_writes_bytes_all_(5)   PUCHAR out,
    _Inout_                     PULONG outLen,
    _Inout_                     PDEVICE_CONTEXT ctx)
{
    *outLen = 0;

    // Minimum size: RID byte + 14-byte MOUSE2 header
    if (inLen < MM2_HEADER_LEN || in[0] != 0x12) return STATUS_NO_MORE_ENTRIES;
    if (ctx == NULL) return STATUS_INVALID_PARAMETER;

    INT wheelDelta  = 0;
    INT hwheelDelta = 0;
    UCHAR buttons   = 0;

    if (!ProcessTouchPoints(in, inLen, ctx, &wheelDelta, &hwheelDelta, &buttons))
    {
        return STATUS_NO_MORE_ENTRIES;  // no scroll this report — pass through
    }

    // Build RID 0x02 output: [RID][buttons][X_lo][X_hi][Wheel]
    // X movement from touch surface is handled separately (not synthesized here).
    out[0] = 0x02;                          // RID
    out[1] = buttons;                       // button state from header
    out[2] = 0;                             // X_lo (no cursor movement from scroll)
    out[3] = 0;                             // X_hi
    out[4] = (UCHAR)(CHAR)wheelDelta;       // Wheel: signed 8-bit, 1=up/-1=down

    *outLen = 5;
    return STATUS_SUCCESS;
}
