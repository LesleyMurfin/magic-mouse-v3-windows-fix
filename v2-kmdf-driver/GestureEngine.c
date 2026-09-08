// SPDX-License-Identifier: MIT
// GestureEngine.c — stay on MOUSE2_REPORT_ID 0x12; add Wheel / AC Pan.
//
// Optical X/Y and buttons come from the 0x12 header (Linux hid-magicmouse.c
// magicmouse_raw_event, MOUSE2 case). Surface scroll is a simplified port of
// magicmouse_emit_touch() TOUCH_STATE_DRAG handling for 0323 / Mouse 2.
#include "GestureEngine.h"

#define MM2_BTN_MASK      0x03
#define TOUCH_STATE_MASK  0xF0
#define TOUCH_STATE_START 0x30
#define TOUCH_STATE_DRAG  0x40

static __forceinline CHAR
ClampI8(_In_ INT value)
{
    if (value > 127)  { return (CHAR)127; }
    if (value < -127) { return (CHAR)-127; }
    return (CHAR)value;
}

// Linux: x = (int)((data[3] << 24) | (data[2] << 16)) >> 16
static __forceinline INT16
ReadI16Le(_In_reads_(2) const UCHAR* p)
{
    USHORT raw = (USHORT)p[0] | (USHORT)((USHORT)p[1] << 8);
    return (INT16)raw;
}

static VOID
WriteI16Le(
    _Out_writes_bytes_(2) PUCHAR p,
    _In_ INT16 value
    )
{
    p[0] = (UCHAR)((USHORT)value & 0xFF);
    p[1] = (UCHAR)(((USHORT)value >> 8) & 0xFF);
}

// Linux: x = (tdata[1] << 28 | tdata[0] << 20) >> 20  (signed 12-bit)
static __forceinline INT
ReadI12Le(_In_reads_(2) const UCHAR* p)
{
    INT v = (INT)(((ULONG)p[1] << 28) | ((ULONG)p[0] << 20));
    return v >> 20;
}

static VOID
AccumulateSurfaceScroll(
    _In_reads_bytes_(inLen) PUCHAR in,
    _In_ SIZE_T inLen,
    _Inout_ PDEVICE_CONTEXT ctx,
    _Out_ INT* outWheel,
    _Out_ INT* outHWheel)
{
    *outWheel  = 0;
    *outHWheel = 0;

    if (inLen < MM2_HEADER_LEN) { return; }

    ULONG nTouches = (ULONG)((inLen - MM2_HEADER_LEN) / MM2_TOUCH_BYTES);
    if (nTouches == 0) { return; }

    ULONG down = 0;
    for (ULONG i = 0; i < nTouches; i++)
    {
        ULONG off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES;
        if (off + MM2_TOUCH_BYTES > inLen) { break; }
        UCHAR st = (UCHAR)((in + off)[7] & TOUCH_STATE_MASK);
        if (st == TOUCH_STATE_START || st == TOUCH_STATE_DRAG)
        {
            down++;
        }
    }

    WdfSpinLockAcquire(ctx->Lock);

    for (ULONG i = 0; i < nTouches; i++)
    {
        ULONG off = MM2_HEADER_LEN + i * MM2_TOUCH_BYTES;
        if (off + MM2_TOUCH_BYTES > inLen) { break; }

        PUCHAR t = in + off;
        ULONG id = ((ULONG)t[6] << 2 | ((ULONG)t[5] >> 6)) & 0xFu;
        if (id >= MM_TOUCH_SLOTS) { continue; }

        // Linux magicmouse_emit_touch (Magic Mouse / Mouse 2 / 0323):
        //   x = (tdata[1] << 28 | tdata[0] << 20) >> 20
        //   y = -((tdata[2] << 24 | tdata[1] << 16) >> 20)
        INT x = ReadI12Le(t + 0);
        INT yPacked = (INT)(((ULONG)t[2] << 24) | ((ULONG)t[1] << 16));
        INT y = -(yPacked >> 20);
        UCHAR state = (UCHAR)(t[7] & TOUCH_STATE_MASK);

        if (state == TOUCH_STATE_START)
        {
            ctx->TouchAnchorX[id] = (INT16)x;
            ctx->TouchAnchorY[id] = (INT16)y;
            ctx->TouchAnchorValid[id] = TRUE;
            ctx->TouchLastX[id] = (INT16)x;
            ctx->TouchLastY[id] = (INT16)y;
            ctx->TouchLastValid[id] = TRUE;
            continue;
        }

        if (state != TOUCH_STATE_DRAG || !ctx->TouchAnchorValid[id])
        {
            if (state == 0x00)
            {
                ctx->TouchAnchorValid[id] = FALSE;
                ctx->TouchLastValid[id] = FALSE;
            }
            continue;
        }

        // TWO_FINGER + SCROLL_STEP_8: 1-finger START/DRAG must not emit Wheel.
        if (down < 2)
        {
            continue;
        }

        // 2026-09-08 prepare-only velocity-scaling diff (NOT INSTALLED):
        // per-report speed (this sample vs the previous one, independent
        // of the notch anchor) grows the effective detent so a fast flick
        // needs more raw distance per notch than a slow deliberate drag.
        // Floor is still exactly MM_SCROLL_STEP - a stationary/slow finger
        // behaves identically to the proven 2026-09-01 constant-step code.
        INT velY = 0;
        INT velX = 0;
        if (ctx->TouchLastValid[id])
        {
            velY = (INT)ctx->TouchLastY[id] - y;
            if (velY < 0) { velY = -velY; }
            velX = (INT)ctx->TouchLastX[id] - x;
            if (velX < 0) { velX = -velX; }
        }
        ctx->TouchLastX[id] = (INT16)x;
        ctx->TouchLastY[id] = (INT16)y;
        ctx->TouchLastValid[id] = TRUE;

        INT effStepY = MM_SCROLL_STEP + velY * MM_SCROLL_VELOCITY_GAIN;
        if (effStepY > MM_SCROLL_STEP_MAX) { effStepY = MM_SCROLL_STEP_MAX; }
        INT effStepX = MM_SCROLL_STEP + velX * MM_SCROLL_VELOCITY_GAIN;
        if (effStepX > MM_SCROLL_STEP_MAX) { effStepX = MM_SCROLL_STEP_MAX; }

        INT stepY = (INT)ctx->TouchAnchorY[id] - y;
        INT stepX = (INT)ctx->TouchAnchorX[id] - x;

        if (stepY >= effStepY || stepY <= -effStepY)
        {
            *outWheel += (stepY > 0) ? 1 : -1;
            ctx->TouchAnchorY[id] = (INT16)y;
        }
        if (stepX >= effStepX || stepX <= -effStepX)
        {
            *outHWheel += (stepX > 0) ? -1 : 1;
            ctx->TouchAnchorX[id] = (INT16)x;
        }
    }

    WdfSpinLockRelease(ctx->Lock);
}

NTSTATUS
TranslateMouse2ToHid(
    _In_reads_bytes_(inLen)     PUCHAR in,
    _In_                        SIZE_T inLen,
    _Out_writes_bytes_all_(MM_MOUSE_REPORT_LEN) PUCHAR out,
    _Inout_                     PULONG outLen,
    _Inout_                     PDEVICE_CONTEXT ctx)
{
    *outLen = 0;

    if (in == NULL || out == NULL || ctx == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }
    if (inLen < 6 || (in[0] != MM_REPORT_ID_MOUSE && in[0] != 0x27))
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    // Compact (8) or full (14 + 8*N). Still accept >=6 so a short header
    // yields buttons + X/Y rather than a dropped report.
    BOOLEAN sizedOk =
        (inLen == MM2_COMPACT_LEN) ||
        (inLen >= MM2_HEADER_LEN && ((inLen - MM2_HEADER_LEN) % MM2_TOUCH_BYTES) == 0) ||
        (inLen >= 6 && inLen < MM2_HEADER_LEN);
    if (!sizedOk)
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    UCHAR buttons = (UCHAR)(in[1] & MM2_BTN_MASK);
    INT16 x16 = (inLen >= 4) ? ReadI16Le(in + 2) : 0;
    INT16 y16 = (inLen >= 6) ? ReadI16Le(in + 4) : 0;

    INT wheel  = 0;
    INT hwheel = 0;
    if (inLen >= MM2_HEADER_LEN)
    {
        AccumulateSurfaceScroll(in, inLen, ctx, &wheel, &hwheel);
    }

    out[0] = MM_REPORT_ID_MOUSE;
    out[1] = buttons;
    WriteI16Le(out + 2, x16);
    WriteI16Le(out + 4, y16);
    out[6] = (UCHAR)ClampI8(hwheel);
    out[7] = (UCHAR)ClampI8(wheel);

    *outLen = MM_MOUSE_REPORT_LEN;
    return STATUS_SUCCESS;
}
