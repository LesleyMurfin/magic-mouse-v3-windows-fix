// SPDX-License-Identifier: MIT
//
// Magic Trackpad → Windows Precision Touchpad.
// Linux hid-magicmouse.c: report IDs, 4+9N / 12+9N layout, 13-bit x/y,
// v1 vs v2 id/down packing, surface min/max. No GPL code.
//
// Injected COL01 is Digitizer/Touch Pad RID 0x01 with 3 fingers so Windows
// can 1/2/3-finger tap. COL02 RID 0x90 battery matches 0323. Descriptor
// length must be ≤ 249 (SDP 1-byte TEXT_STRING: 6+N ≤ 255).

#include "TrackpadPtp.h"

#define TP_V1_MIN_X   (-2909)
#define TP_V1_MAX_X   3167
#define TP_V1_MIN_Y   (-2456)
#define TP_V1_MAX_Y   2565

#define TP_V2_MIN_X   (-3678)
#define TP_V2_MAX_X   3934
#define TP_V2_MIN_Y   (-2478)
#define TP_V2_MAX_Y   2587

#define TP_X_LOG_MAX  7612  /* 3934 - (-3678) */
#define TP_Y_LOG_MAX  5065  /* 2587 - (-2478) */

#define TP_STATE_MASK 0xF0u
#define TP_V2_DOWN    0x80u
#define TP_V2_STATE   0xC0u

#define TP_FINGER_COLLECTION \
    0x09, 0x22, \
    0xA1, 0x02, \
    0x15, 0x00, \
    0x25, 0x01, \
    0x75, 0x01, \
    0x95, 0x02, \
    0x09, 0x42, \
    0x09, 0x47, \
    0x81, 0x02, \
    0x95, 0x06, \
    0x81, 0x03, \
    0x75, 0x08, \
    0x95, 0x01, \
    0x25, 0x0F, \
    0x09, 0x51, \
    0x81, 0x02, \
    0x05, 0x01, \
    0x75, 0x10, \
    0x26, 0xBC, 0x1D, \
    0x09, 0x30, \
    0x81, 0x02, \
    0x26, 0xC9, 0x13, \
    0x09, 0x31, \
    0x81, 0x02, \
    0x05, 0x0D, \
    0xC0

const UCHAR g_PtpHidDescriptor[] = {
    0x05, 0x0D,
    0x09, 0x05,
    0xA1, 0x01,
    0x85, 0x01,

    TP_FINGER_COLLECTION,
    TP_FINGER_COLLECTION,
    TP_FINGER_COLLECTION,

    0x09, 0x54,
    0x75, 0x08,
    0x95, 0x01,
    0x25, 0x03,
    0x81, 0x02,

    0x09, 0x56,
    0x75, 0x10,
    0x81, 0x02,

    0x05, 0x09,
    0x09, 0x01,
    0x15, 0x00,
    0x25, 0x01,
    0x75, 0x01,
    0x95, 0x01,
    0x81, 0x02,
    0x95, 0x07,
    0x81, 0x03,

    0x05, 0x0D,
    0x09, 0x55,
    0x25, 0x03,
    0x75, 0x08,
    0x95, 0x01,
    0xB1, 0x03,
    0xC0,

    0x05, 0x01,
    0x09, 0x06,
    0x05, 0x06,
    0x09, 0x20,
    0xA1, 0x01,
    0x85, 0x90,
    0x75, 0x08,
    0x95, 0x01,
    0x81, 0x03,
    0x15, 0x00,
    0x25, 0x64,
    0x09, 0x20,
    0x95, 0x01,
    0x81, 0x02,
    0xC0,
};

const ULONG g_PtpHidDescriptorSize = sizeof(g_PtpHidDescriptor);

BOOLEAN
MmIsTrackpadPid(_In_ USHORT pid)
{
    return (BOOLEAN)(pid == MM_PID_TRACKPAD_V1 ||
                     pid == MM_PID_TRACKPAD_V2 ||
                     pid == MM_PID_TRACKPAD_V3);
}

BOOLEAN
TrackpadFillMtEnable(
    _In_ USHORT pid,
    _Out_writes_bytes_(*outLen) PUCHAR out,
    _Inout_ PULONG outLen)
{
    if (out == NULL || outLen == NULL)
    {
        return FALSE;
    }

    if (pid == MM_PID_TRACKPAD_V1)
    {
        if (*outLen < 2) { return FALSE; }
        out[0] = 0xD7;
        out[1] = 0x01;
        *outLen = 2;
        return TRUE;
    }

    if (pid == MM_PID_TRACKPAD_V2 || pid == MM_PID_TRACKPAD_V3)
    {
        if (*outLen < 3) { return FALSE; }
        out[0] = 0xF1;
        out[1] = 0x02;
        out[2] = 0x01;
        *outLen = 3;
        return TRUE;
    }

    return FALSE;
}

static INT
TpClamp(_In_ INT v, _In_ INT lo, _In_ INT hi)
{
    if (v < lo) { return lo; }
    if (v > hi) { return hi; }
    return v;
}

static INT
TpReadI13X(_In_reads_(2) const UCHAR *t)
{
    INT v = (INT)(((ULONG)t[1] << 27) | ((ULONG)t[0] << 19));
    return v >> 19;
}

static INT
TpReadI13Y(_In_reads_(3) const UCHAR *t)
{
    INT v = (INT)(((ULONG)t[3] << 30) | ((ULONG)t[2] << 22) | ((ULONG)t[1] << 14));
    return -(v >> 19);
}

static VOID
TpWriteI16Le(_Out_writes_bytes_(2) PUCHAR p, _In_ INT v)
{
    USHORT u = (USHORT)v;
    p[0] = (UCHAR)(u & 0xFF);
    p[1] = (UCHAR)((u >> 8) & 0xFF);
}

static BOOLEAN
TpIsV1Layout(_In_ UCHAR rid, _In_ USHORT pid)
{
    if (rid == TP_RID_V1) { return TRUE; }
    if (rid == TP_RID_V2_BT || rid == TP_RID_V2_USB) { return FALSE; }
    return (BOOLEAN)(pid == MM_PID_TRACKPAD_V1);
}

static NTSTATUS
TpTranslateOne(
    _In_reads_bytes_(inLen) PUCHAR in,
    _In_ SIZE_T inLen,
    _Out_writes_bytes_(*outLen) PUCHAR out,
    _Inout_ PULONG outLen,
    _In_ USHORT productId,
    _Inout_opt_ PULONG scanTime)
{
    UCHAR rid;
    ULONG header;
    BOOLEAN v1;
    INT minX, maxX, minY, maxY;
    ULONG npoints;
    ULONG i;
    ULONG count;
    USHORT scan;
    UCHAR clicks;

    if (in == NULL || out == NULL || outLen == NULL)
    {
        return STATUS_INVALID_PARAMETER;
    }
    if (*outLen < TP_PTP_REPORT_LEN)
    {
        return STATUS_BUFFER_TOO_SMALL;
    }
    if (inLen < 1)
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    rid = in[0];
    if (rid == TP_RID_BATTERY || rid == 0x12 || rid == 0x27)
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    if (rid == TP_RID_V2_USB)
    {
        header = TP_USB_HEADER;
    }
    else if (rid == TP_RID_V1 || rid == TP_RID_V2_BT)
    {
        header = TP_BT_HEADER;
    }
    else
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    if (inLen < header || ((inLen - header) % TP_TOUCH_BYTES) != 0)
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    npoints = (ULONG)((inLen - header) / TP_TOUCH_BYTES);
    if (npoints > 15)
    {
        return STATUS_NO_MORE_ENTRIES;
    }

    v1 = TpIsV1Layout(rid, productId);
    if (v1)
    {
        minX = TP_V1_MIN_X; maxX = TP_V1_MAX_X;
        minY = TP_V1_MIN_Y; maxY = TP_V1_MAX_Y;
    }
    else
    {
        minX = TP_V2_MIN_X; maxX = TP_V2_MAX_X;
        minY = TP_V2_MIN_Y; maxY = TP_V2_MAX_Y;
    }

    clicks = (inLen >= 2) ? (UCHAR)(in[1] & 0x01) : 0;

    RtlZeroMemory(out, TP_PTP_REPORT_LEN);
    out[0] = TP_PTP_RID;

    count = 0;
    for (i = 0; i < npoints && count < TP_PTP_CONTACTS; i++)
    {
        PUCHAR t = in + header + i * TP_TOUCH_BYTES;
        UCHAR id;
        BOOLEAN down;
        INT x;
        INT y;
        INT xPtp;
        INT yPtp;
        ULONG base;

        if (v1)
        {
            id = (UCHAR)((((ULONG)t[7] << 2) | ((ULONG)t[6] >> 6)) & 0xFu);
            down = (BOOLEAN)((t[8] & TP_STATE_MASK) != 0);
        }
        else
        {
            id = (UCHAR)(t[8] & 0x0Fu);
            down = (BOOLEAN)((t[3] & TP_V2_STATE) == TP_V2_DOWN);
        }

        if (!down)
        {
            continue;
        }

        x = TpReadI13X(t);
        y = TpReadI13Y(t);
        xPtp = TpClamp(x - minX, 0, TP_X_LOG_MAX);
        yPtp = TpClamp(maxY - y, 0, TP_Y_LOG_MAX);
        (void)maxX;
        (void)minY;

        base = 1 + count * 6;
        out[base + 0] = 0x03;
        out[base + 1] = id;
        TpWriteI16Le(out + base + 2, xPtp);
        TpWriteI16Le(out + base + 4, yPtp);
        count++;
    }

    out[19] = (UCHAR)count;

    scan = 0;
    if (scanTime != NULL)
    {
        *scanTime += 10;
        scan = (USHORT)(*scanTime);
    }
    out[20] = (UCHAR)(scan & 0xFF);
    out[21] = (UCHAR)((scan >> 8) & 0xFF);
    out[22] = clicks;

    *outLen = TP_PTP_REPORT_LEN;
    return STATUS_SUCCESS;
}

NTSTATUS
TranslateTrackpadToPtp(
    _In_reads_bytes_(inLen) PUCHAR in,
    _In_ SIZE_T inLen,
    _Out_writes_bytes_(*outLen) PUCHAR out,
    _Inout_ PULONG outLen,
    _In_ USHORT productId,
    _Inout_opt_ PULONG scanTime)
{
    if (in == NULL || inLen < 1)
    {
        return STATUS_INVALID_PARAMETER;
    }

    if (in[0] == TP_RID_DOUBLE && inLen >= 2)
    {
        UCHAR firstLen = in[1];
        ULONG innerOff;
        ULONG innerLen;

        if ((ULONG)firstLen + 2u > (ULONG)inLen)
        {
            return STATUS_NO_MORE_ENTRIES;
        }

        innerOff = 2u + (ULONG)firstLen;
        innerLen = (ULONG)inLen - innerOff;
        if (innerLen >= 1 &&
            (in[innerOff] == TP_RID_V1 ||
             in[innerOff] == TP_RID_V2_BT ||
             in[innerOff] == TP_RID_V2_USB))
        {
            return TpTranslateOne(in + innerOff, innerLen, out, outLen,
                                  productId, scanTime);
        }
        if (firstLen >= 1)
        {
            return TpTranslateOne(in + 2, firstLen, out, outLen,
                                  productId, scanTime);
        }
        return STATUS_NO_MORE_ENTRIES;
    }

    return TpTranslateOne(in, inLen, out, outLen, productId, scanTime);
}
