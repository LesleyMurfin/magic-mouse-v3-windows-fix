// SPDX-License-Identifier: MIT
//
// Slice tests for TrackpadPtp.c (PTP descriptor + Apple to PTP translate).
//
// gcc -Wall -Wextra -Werror -DMM_USERLAND_TEST -I tests -I .
//     -o /tmp/test-trackpad-ptp tests/test-trackpad-ptp.c TrackpadPtp.c
// /tmp/test-trackpad-ptp

#define MM_USERLAND_TEST 1
#include "kernel-stubs.h"
#include "TrackpadPtp.h"

#include <stdio.h>
#include <string.h>

static int g_pass;
static int g_fail;

#define PASS(name) do { printf("PASS  %s\n", (name)); g_pass++; } while (0)
#define FAIL(name, reason) do { printf("FAIL  %s - %s\n", (name), (reason)); g_fail++; } while (0)

#define ASSERT_TRUE(name, expr) do { \
    if (expr) { PASS(name); } else { FAIL(name, "expected TRUE"); } \
} while (0)

#define ASSERT_EQ_UL(name, expected, actual) do { \
    unsigned long _e = (unsigned long)(expected); \
    unsigned long _a = (unsigned long)(actual); \
    if (_e == _a) { PASS(name); } \
    else { \
        char _buf[96]; \
        snprintf(_buf, sizeof(_buf), "expected %lu got %lu", _e, _a); \
        FAIL(name, _buf); \
    } \
} while (0)

static INT16
ReadI16Le(const UCHAR *p)
{
    return (INT16)((USHORT)p[0] | ((USHORT)p[1] << 8));
}

static BOOLEAN
DescContains(const UCHAR *d, ULONG n, UCHAR a, UCHAR b)
{
    ULONG i;
    if (n < 2) { return FALSE; }
    for (i = 0; i + 1 < n; i++)
    {
        if (d[i] == a && d[i + 1] == b) { return TRUE; }
    }
    return FALSE;
}

static VOID
PackV1Touch(UCHAR *t, UCHAR id, INT x, UCHAR state)
{
    memset(t, 0, 9);
    t[0] = (UCHAR)(x & 0xFF);
    t[1] = (UCHAR)((x >> 8) & 0x1F);
    t[6] = (UCHAR)((id & 0x03) << 6);
    t[7] = (UCHAR)((id >> 2) & 0x3F);
    t[8] = state;
}

static VOID
PackV2Touch(UCHAR *t, UCHAR id, INT x, BOOLEAN down)
{
    memset(t, 0, 9);
    t[0] = (UCHAR)(x & 0xFF);
    t[1] = (UCHAR)((x >> 8) & 0x1F);
    if (down) { t[3] = 0x80; }
    t[8] = (UCHAR)(id & 0x0F);
}

int
main(void)
{
    UCHAR out[TP_PTP_REPORT_LEN];
    ULONG outLen;
    NTSTATUS st;
    UCHAR mt[4];
    ULONG mtLen;
    UCHAR v1[4 + 9];
    UCHAR v1three[4 + 27];
    UCHAR v2two[4 + 18];
    ULONG scan;
    INT xPtp;

    ASSERT_TRUE("ptp desc size <= 249",
                g_PtpHidDescriptorSize > 0 &&
                g_PtpHidDescriptorSize <= TP_PTP_DESC_MAX);
    ASSERT_TRUE("ptp desc Touch Pad 0x09 0x05",
                DescContains(g_PtpHidDescriptor, g_PtpHidDescriptorSize, 0x09, 0x05));
    ASSERT_TRUE("ptp desc RID 0x85 0x01",
                DescContains(g_PtpHidDescriptor, g_PtpHidDescriptorSize, 0x85, 0x01));
    ASSERT_TRUE("ptp desc battery RID 0x90",
                DescContains(g_PtpHidDescriptor, g_PtpHidDescriptorSize, 0x85, 0x90));
    ASSERT_TRUE("ptp desc Contact Count Max feature const",
                DescContains(g_PtpHidDescriptor, g_PtpHidDescriptorSize, 0x09, 0x55) &&
                DescContains(g_PtpHidDescriptor, g_PtpHidDescriptorSize, 0xB1, 0x03));

    ASSERT_TRUE("030E is trackpad", MmIsTrackpadPid(0x030E));
    ASSERT_TRUE("0265 is trackpad", MmIsTrackpadPid(0x0265));
    ASSERT_TRUE("0324 is trackpad", MmIsTrackpadPid(0x0324));
    ASSERT_TRUE("0323 is not trackpad", !MmIsTrackpadPid(0x0323));
    ASSERT_TRUE("030D is not trackpad", !MmIsTrackpadPid(0x030D));

    mtLen = sizeof(mt);
    ASSERT_TRUE("v1 MT enable", TrackpadFillMtEnable(0x030E, mt, &mtLen));
    ASSERT_EQ_UL("v1 MT len", 2, mtLen);
    ASSERT_EQ_UL("v1 MT b0", 0xD7, mt[0]);
    ASSERT_EQ_UL("v1 MT b1", 0x01, mt[1]);

    mtLen = sizeof(mt);
    ASSERT_TRUE("v2 MT enable", TrackpadFillMtEnable(0x0265, mt, &mtLen));
    ASSERT_EQ_UL("v2 MT len", 3, mtLen);
    ASSERT_EQ_UL("v2 MT b0", 0xF1, mt[0]);
    ASSERT_EQ_UL("v2 MT b1", 0x02, mt[1]);
    ASSERT_EQ_UL("v2 MT b2", 0x01, mt[2]);

    mtLen = sizeof(mt);
    ASSERT_TRUE("v3 MT enable same as v2", TrackpadFillMtEnable(0x0324, mt, &mtLen));
    ASSERT_EQ_UL("v3 MT b0", 0xF1, mt[0]);

    memset(v1, 0, sizeof(v1));
    v1[0] = TP_RID_V1;
    v1[1] = 0x00;
    PackV1Touch(v1 + 4, 1, 100, 0x40);
    outLen = sizeof(out);
    scan = 0;
    st = TranslateTrackpadToPtp(v1, sizeof(v1), out, &outLen, 0x030E, &scan);
    ASSERT_TRUE("v1 one contact STATUS_SUCCESS", NT_SUCCESS(st));
    ASSERT_EQ_UL("v1 out len 23", TP_PTP_REPORT_LEN, outLen);
    ASSERT_EQ_UL("v1 RID 0x01", TP_PTP_RID, out[0]);
    ASSERT_EQ_UL("v1 contact count 1", 1, out[19]);
    ASSERT_EQ_UL("v1 tip+conf", 0x03, out[1]);
    ASSERT_EQ_UL("v1 contact id 1", 1, out[2]);
    xPtp = ReadI16Le(out + 3);
    ASSERT_TRUE("v1 X 0-based (100 - MIN_X)", xPtp == (100 - (-2909)));
    ASSERT_EQ_UL("v1 button 0", 0, out[22]);
    ASSERT_EQ_UL("scan time +10", 10, scan);

    memset(v1three, 0, sizeof(v1three));
    v1three[0] = TP_RID_V1;
    v1three[1] = 0x01;
    PackV1Touch(v1three + 4, 0, 10, 0x40);
    PackV1Touch(v1three + 13, 1, 20, 0x40);
    PackV1Touch(v1three + 22, 2, 30, 0x40);
    outLen = sizeof(out);
    st = TranslateTrackpadToPtp(v1three, sizeof(v1three), out, &outLen, 0x030E, NULL);
    ASSERT_TRUE("v1 three contacts ok", NT_SUCCESS(st));
    ASSERT_EQ_UL("v1 three → count 3", 3, out[19]);
    ASSERT_EQ_UL("v1 three ids 0,1,2", 0, out[2]);
    ASSERT_EQ_UL("v1 finger1 id 1", 1, out[8]);
    ASSERT_EQ_UL("v1 finger2 id 2", 2, out[14]);
    ASSERT_EQ_UL("v1 physical click → button1", 1, out[22]);
    ASSERT_EQ_UL("v1 finger2 tip", 0x03, out[13]);

    memset(v2two, 0, sizeof(v2two));
    v2two[0] = TP_RID_V2_BT;
    PackV2Touch(v2two + 4, 3, 50, TRUE);
    PackV2Touch(v2two + 13, 4, 60, TRUE);
    outLen = sizeof(out);
    st = TranslateTrackpadToPtp(v2two, sizeof(v2two), out, &outLen, 0x0265, NULL);
    ASSERT_TRUE("v2 two contacts ok", NT_SUCCESS(st));
    ASSERT_EQ_UL("v2 count 2", 2, out[19]);
    ASSERT_EQ_UL("v2 id0", 3, out[2]);
    ASSERT_EQ_UL("v2 id1", 4, out[8]);

    {
        UCHAR bat[3] = { 0x90, 0x04, 0x2F };
        outLen = sizeof(out);
        st = TranslateTrackpadToPtp(bat, sizeof(bat), out, &outLen, 0x0324, NULL);
        ASSERT_TRUE("0x90 not PTP", st == STATUS_NO_MORE_ENTRIES);
    }
    {
        UCHAR mouse[8] = { 0x12, 0x01, 0, 0, 0, 0, 0, 0 };
        outLen = sizeof(out);
        st = TranslateTrackpadToPtp(mouse, sizeof(mouse), out, &outLen, 0x030E, NULL);
        ASSERT_TRUE("0x12 not PTP", st == STATUS_NO_MORE_ENTRIES);
    }
    {
        UCHAR tooSmall[4];
        ULONG tiny = 4;
        memset(v1, 0, sizeof(v1));
        v1[0] = TP_RID_V1;
        PackV1Touch(v1 + 4, 1, 1, 0x40);
        st = TranslateTrackpadToPtp(v1, sizeof(v1), tooSmall, &tiny, 0x030E, NULL);
        ASSERT_TRUE("short out BUFFER_TOO_SMALL", st == STATUS_BUFFER_TOO_SMALL);
    }

    printf("%d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
