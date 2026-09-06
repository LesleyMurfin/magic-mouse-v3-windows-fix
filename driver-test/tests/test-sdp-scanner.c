// SPDX-License-Identifier: MIT
//
// test-sdp-scanner.c — userland unit tests for the pure-logic functions in
// driver/InputHandler.c (sourced from the BRB-interception rewrite on main).
//
// Functions under test (copied verbatim from main:driver/InputHandler.c to
// avoid pulling in WDF/KMDF kernel headers — the production file is untouched):
//   - ScanForSdpHidDescriptor
//   - PatchSdpHidDescriptor
//   - TranslateReport12  (bonus — tested only if present)
//   - ClampInt8          (bonus)
//   - TouchX / TouchY    (bonus)
//
// Build (see scripts/mm-test.sh for canonical invocation):
//   gcc -Wall -Wextra -Wno-unused-parameter -Wno-type-limits
//       -o /tmp/mm-test-sdp tests/test-sdp-scanner.c
//
// Run:
//   ./scripts/mm-test.sh
//
// Output: one "PASS  <name>" or "FAIL  <name> - <reason>" line per case.
// Exit:   0 if all pass, 1 if any fail.

#include "kernel-stubs.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

// ===========================================================================
// Test harness
// ===========================================================================

static int g_pass = 0;
static int g_fail = 0;

#define PASS(name) do { \
    printf("PASS  %s\n", (name)); \
    g_pass++; \
} while (0)

#define FAIL(name, reason) do { \
    printf("FAIL  %s - %s\n", (name), (reason)); \
    g_fail++; \
} while (0)

#define ASSERT_TRUE(name, expr) do { \
    if (expr) { PASS(name); } \
    else       { FAIL(name, "expected TRUE, got FALSE"); } \
} while (0)

#define ASSERT_FALSE(name, expr) do { \
    if (!(expr)) { PASS(name); } \
    else          { FAIL(name, "expected FALSE, got TRUE"); } \
} while (0)

#define ASSERT_EQ_UL(name, expected, actual) do { \
    unsigned long _e = (unsigned long)(expected); \
    unsigned long _a = (unsigned long)(actual);   \
    if (_e == _a) { PASS(name); }                 \
    else {                                        \
        char _buf[128];                           \
        snprintf(_buf, sizeof(_buf),              \
                 "expected %lu got %lu", _e, _a); \
        FAIL(name, _buf);                         \
    }                                             \
} while (0)

#define ASSERT_MEM_EQ(name, expected, actual, len) do {    \
    if (memcmp((expected), (actual), (len)) == 0) {        \
        PASS(name);                                        \
    } else {                                              \
        FAIL(name, "memory mismatch");                    \
    }                                                     \
} while (0)

// ===========================================================================
// g_HidDescriptor fixture (verbatim from main:driver/HidDescriptor.c)
// 113 bytes (3 TLCs: Mouse 0x01 + Consumer 0x02 + Vendor battery 0x90)
// ===========================================================================

static const UCHAR g_HidDescriptor[] = {
    // TLC1: Generic Desktop Mouse — Report ID 0x01
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x02,        // Usage (Mouse)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x01,        //   Report ID (1)
    0x09, 0x01,        //   Usage (Pointer)
    0xA1, 0x00,        //   Collection (Physical)
    0x05, 0x09,        //     Usage Page (Button)
    0x19, 0x01,        //     Usage Minimum (Button 1)
    0x29, 0x03,        //     Usage Maximum (Button 3)
    0x15, 0x00,        //     Logical Minimum (0)
    0x25, 0x01,        //     Logical Maximum (1)
    0x75, 0x01,        //     Report Size (1)
    0x95, 0x03,        //     Report Count (3)
    0x81, 0x02,        //     Input (Data, Variable, Absolute)
    0x75, 0x05,        //     Report Size (5) padding
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x03,        //     Input (Constant)
    0x05, 0x01,        //     Usage Page (Generic Desktop)
    0x09, 0x30,        //     Usage (X)
    0x09, 0x31,        //     Usage (Y)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x02,        //     Report Count (2)
    0x81, 0x06,        //     Input (Data, Variable, Relative)
    0x09, 0x38,        //     Usage (Wheel)
    0x15, 0x81,        //     Logical Minimum (-127)
    0x25, 0x7F,        //     Logical Maximum (127)
    0x75, 0x08,        //     Report Size (8)
    0x95, 0x01,        //     Report Count (1)
    0x81, 0x06,        //     Input (Data, Variable, Relative)
    0xC0,              //   End Collection (Physical)
    0xC0,              // End Collection (Application)
    // TLC2: Consumer Control — Report ID 0x02
    0x05, 0x0C,        // Usage Page (Consumer Devices)
    0x09, 0x01,        // Usage (Consumer Control)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x02,        //   Report ID (2)
    0x0A, 0x38, 0x02,  //   Usage (AC Pan 0x0238)
    0x15, 0x81,        //   Logical Minimum (-127)
    0x25, 0x7F,        //   Logical Maximum (127)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x01,        //   Report Count (1)
    0x81, 0x06,        //   Input (Data, Variable, Relative)
    0xC0,              // End Collection (Application)
    // TLC3: Vendor-Defined Battery — Report ID 0x90
    0x06, 0x00, 0xFF,  // Usage Page (Vendor-Defined 0xFF00)
    0x09, 0x14,        // Usage (0x14)
    0xA1, 0x01,        // Collection (Application)
    0x85, 0x90,        //   Report ID (0x90)
    0x09, 0x01,        //   Usage (0x01) flags byte
    0x09, 0x02,        //   Usage (0x02) battery% byte
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x02,        //   Report Count (2)
    0x81, 0x02,        //   Input (Data, Variable, Absolute)
    0xC0,              // End Collection
};
static const ULONG g_HidDescriptorSize = sizeof(g_HidDescriptor);

// ===========================================================================
// Functions under test (verbatim from main:driver/InputHandler.c)
// Copied to avoid WDF/KMDF kernel headers. Production source is untouched.
// ===========================================================================

#define SDP_DE_UINT16             0x09
#define SDP_DE_SEQUENCE_1B        0x35
#define SDP_DE_UINT8              0x08
#define SDP_DE_TEXT_1B            0x25
#define SDP_ATTR_HID_DESC_LIST_HI 0x02
#define SDP_ATTR_HID_DESC_LIST_LO 0x06
#define HID_RPT_DESC_TYPE         0x22
#define SDP_SCAN_MIN_LEN          11
#define SDP_DESC_MAX_EXPECTED_LEN 512

static BOOLEAN
ScanForSdpHidDescriptor(
    PUCHAR  buf,
    ULONG   bufSize,
    PULONG  outOffset,
    PULONG  outLen)
{
    if (buf == NULL || bufSize < SDP_SCAN_MIN_LEN) {
        return FALSE;
    }

    ULONG limit = bufSize - SDP_SCAN_MIN_LEN;
    for (ULONG i = 0; i <= limit; i++) {
        if (buf[i]   != SDP_DE_UINT16              ) continue;
        if (buf[i+1] != SDP_ATTR_HID_DESC_LIST_HI  ) continue;
        if (buf[i+2] != SDP_ATTR_HID_DESC_LIST_LO  ) continue;
        if (buf[i+3] != SDP_DE_SEQUENCE_1B         ) continue;

        UCHAR outer_len = buf[i+4];
        if (outer_len < 4)                            continue;
        if ((ULONG)(i + 5 + outer_len) > bufSize)     continue;

        if (buf[i+5] != SDP_DE_SEQUENCE_1B)           continue;
        UCHAR inner_len = buf[i+6];
        if (inner_len < 4)                            continue;
        if ((ULONG)(i + 7 + inner_len) > bufSize)     continue;

        if (buf[i+7] != SDP_DE_UINT8)                 continue;
        if (buf[i+8] != HID_RPT_DESC_TYPE)            continue;
        if (buf[i+9] != SDP_DE_TEXT_1B)               continue;

        UCHAR desc_len = buf[i+10];
        if (desc_len == 0)                            continue;
        if (desc_len > SDP_DESC_MAX_EXPECTED_LEN)     continue;
        if ((ULONG)(i + 11 + desc_len) > bufSize)     continue;

        *outOffset = i + 11;
        *outLen    = desc_len;
        return TRUE;
    }
    return FALSE;
}

static BOOLEAN
PatchSdpHidDescriptor(
    PUCHAR buf,
    ULONG  bufSize,
    ULONG  descOffset,
    ULONG  descLen,
    PULONG newBufUsed)
{
    if (descOffset < 6) {
        return FALSE;
    }

    ULONG newDescLen = g_HidDescriptorSize;
    ULONG tailOffset = descOffset + descLen;
    ULONG tailBytes  = bufSize - tailOffset;
    ULONG newBufSize = descOffset + newDescLen + tailBytes;

    if (newBufSize > bufSize) {
        DbgPrint("MagicMouse: SDP patch SKIPPED - buffer too small "
                 "(need %lu, have %lu).\n",
                 newBufSize, bufSize);
        return FALSE;
    }

    if (newDescLen != descLen) {
        ULONG newTailOffset = descOffset + newDescLen;
        if (tailBytes > 0) {
            RtlMoveMemory(buf + newTailOffset, buf + tailOffset, tailBytes);
        }
        if (newDescLen < descLen) {
            ULONG gapStart = newTailOffset + tailBytes;
            ULONG gapLen   = descLen - newDescLen;
            RtlZeroMemory(buf + gapStart, gapLen);
        }
    }

    RtlCopyMemory(buf + descOffset, g_HidDescriptor, newDescLen);

    // SDP TLV length-byte fixups (1-byte length form)
    buf[descOffset - 1] = (UCHAR)newDescLen;
    ULONG innerPayload = 2 + 2 + newDescLen;
    if (innerPayload > 0xFF) {
        DbgPrint("MagicMouse: SDP patch - inner SEQUENCE length overflow (%lu)\n",
                 innerPayload);
    }
    buf[descOffset - 3] = (UCHAR)(innerPayload & 0xFF);
    ULONG outerPayload = 2 + innerPayload;
    if (outerPayload > 0xFF) {
        DbgPrint("MagicMouse: SDP patch - outer SEQUENCE length overflow (%lu)\n",
                 outerPayload);
    }
    buf[descOffset - 5] = (UCHAR)(outerPayload & 0xFF);

    *newBufUsed = descOffset + newDescLen + tailBytes;
    return TRUE;
}

// ---------------------------------------------------------------------------
// Bonus: ClampInt8, TouchX, TouchY, TranslateReport12
// (verbatim from main:driver/InputHandler.c)
// ---------------------------------------------------------------------------

#define TOUCH2_HEADER     7
#define TOUCH2_BLOCK      8
#define TOUCH_START    0x30
#define TOUCH_DRAG     0x40
#define SCALE_POINTER     4
#define SCALE_SCROLL      8
#define MM_REPORT_ID_MOUSE 0x01
#define MM_MOUSE_REPORT_LEN 5

static FORCEINLINE INT8
ClampInt8(INT32 v)
{
    if (v >  127) return  127;
    if (v < -127) return -127;
    return (INT8)v;
}

static FORCEINLINE INT32
TouchX(PUCHAR t)
{
    return (INT32)((((UINT32)t[1] << 28) | ((UINT32)t[0] << 20))) >> 20;
}

static FORCEINLINE INT32
TouchY(PUCHAR t)
{
    return -((INT32)((((UINT32)t[2] << 24) | ((UINT32)t[1] << 16))) >> 20);
}

static BOOLEAN
TranslateReport12(
    PUCHAR  buf,
    ULONG   bufSize,
    INT8   *outWheelH,
    PULONG  outReportLen)
{
    *outReportLen = 0;
    if (outWheelH) *outWheelH = 0;

    if (bufSize < (ULONG)(TOUCH2_HEADER + 1)) {
        return FALSE;
    }

    UCHAR  buttons = buf[1] & 0x03;
    ULONG  nBlocks = (bufSize - TOUCH2_HEADER) / TOUCH2_BLOCK;
    INT8   x = 0, y = 0, wheelV = 0, wheelH = 0;

    if (nBlocks >= 1) {
        PUCHAR t = &buf[TOUCH2_HEADER];
        INT32  rawX = TouchX(t);
        INT32  rawY = TouchY(t);
        UCHAR  state = t[7] & 0xF0;

        if (nBlocks == 1) {
            x = ClampInt8(rawX / SCALE_POINTER);
            y = ClampInt8(rawY / SCALE_POINTER);
        } else {
            if (state == TOUCH_START || state == TOUCH_DRAG) {
                wheelV = ClampInt8(rawY / SCALE_SCROLL);
                wheelH = ClampInt8(rawX / SCALE_SCROLL);
            }
        }
    }

    buf[0] = MM_REPORT_ID_MOUSE;
    buf[1] = buttons;
    buf[2] = (UCHAR)x;
    buf[3] = (UCHAR)y;
    buf[4] = (UCHAR)wheelV;

    if (outWheelH) *outWheelH = wheelH;
    *outReportLen = MM_MOUSE_REPORT_LEN;
    return TRUE;
}

// ===========================================================================
// Helper: build a minimal SDP buffer containing the HIDDescriptorList pattern.
//
// Layout assembled here:
//   [preamble bytes]
//   09 02 06          <- SDP_DE_UINT16, AttrID HIDDescriptorList
//   35 OO             <- outer SEQUENCE_1B, length OO
//     35 II           <- inner SEQUENCE_1B, length II
//       08 22         <- SDP_DE_UINT8, 0x22 (Report descriptor type)
//       25 NN         <- SDP_DE_TEXT_1B, NN bytes follow
//         [NN bytes]  <- descriptor payload
//   [tail bytes]
//
// Returns the byte offset of the descriptor payload within outBuf[].
// ===========================================================================

static ULONG build_sdp_packet(
    UCHAR *outBuf, ULONG bufSize,
    ULONG preamble,
    const UCHAR *desc, ULONG descLen,
    ULONG tailLen)
{
    // innerContent: the payload of the inner SEQUENCE (not counting the 35 II header itself)
    //   = [08 22](2) + [25 NN](2) + desc(descLen)
    ULONG innerContent = 2 + 2 + descLen;
    // outerContent: the payload of the outer SEQUENCE (not counting the 35 OO header itself)
    //   = [35 II](2) + innerContent
    ULONG outerContent = 2 + innerContent;

    // Total bytes written:
    //   preamble + [09 02 06](3) + [35 OO](2) + outerContent + tailLen
    ULONG total = preamble + 3 + 2 + outerContent + tailLen;
    if (total > bufSize) return 0; // caller must size properly

    UCHAR *p = outBuf;
    // preamble fill
    for (ULONG i = 0; i < preamble; i++) *p++ = 0xAA;

    // SDP attribute header
    *p++ = 0x09; // SDP_DE_UINT16
    *p++ = 0x02; // HI
    *p++ = 0x06; // LO

    // outer SEQUENCE_1B
    *p++ = 0x35;
    *p++ = (UCHAR)outerContent;

    // inner SEQUENCE_1B
    *p++ = 0x35;
    *p++ = (UCHAR)innerContent;

    // descriptor type element
    *p++ = 0x08; // SDP_DE_UINT8
    *p++ = 0x22; // 0x22 = Report descriptor

    // text string element
    *p++ = 0x25; // SDP_DE_TEXT_1B
    *p++ = (UCHAR)descLen;

    // descriptor payload
    ULONG descOffset = (ULONG)(p - outBuf);
    memcpy(p, desc, descLen);
    p += descLen;

    // tail bytes
    for (ULONG i = 0; i < tailLen; i++) *p++ = 0xBB;

    return descOffset;
}

// ===========================================================================
// ScanForSdpHidDescriptor tests
// ===========================================================================

// A small fake "old" descriptor for testing (different from g_HidDescriptor)
static const UCHAR OLD_DESC[] = {
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01,  // 6 bytes — simple fake
};
#define OLD_DESC_LEN ((ULONG)sizeof(OLD_DESC))

static void test_scan_null_returns_false(void)
{
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_null_returns_false",
                 ScanForSdpHidDescriptor(NULL, 100, &off, &len));
}

static void test_scan_empty_returns_false(void)
{
    UCHAR buf[1] = {0};
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_empty_returns_false",
                 ScanForSdpHidDescriptor(buf, 0, &off, &len));
}

static void test_scan_below_min_len_returns_false(void)
{
    // SDP_SCAN_MIN_LEN == 11; provide 10 bytes
    UCHAR buf[10];
    memset(buf, 0, sizeof(buf));
    buf[0] = 0x09; buf[1] = 0x02; buf[2] = 0x06; // start of pattern
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_below_min_len_returns_false",
                 ScanForSdpHidDescriptor(buf, 10, &off, &len));
}

static void test_scan_all_zeros_returns_false(void)
{
    UCHAR buf[64];
    memset(buf, 0, sizeof(buf));
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_all_zeros_returns_false",
                 ScanForSdpHidDescriptor(buf, sizeof(buf), &off, &len));
}

static void test_scan_finds_pattern_at_offset0(void)
{
    // Build SDP packet with no preamble and OLD_DESC as payload
    UCHAR buf[128];
    memset(buf, 0, sizeof(buf));
    ULONG descOffset = build_sdp_packet(buf, sizeof(buf), 0,
                                        OLD_DESC, OLD_DESC_LEN, 0);
    if (descOffset == 0) { FAIL("test_scan_finds_pattern_at_offset0", "build failed"); return; }

    ULONG off = 0, len = 0;
    BOOLEAN found = ScanForSdpHidDescriptor(buf, sizeof(buf), &off, &len);
    ASSERT_TRUE("test_scan_finds_pattern_at_offset0 [found]", found);
    ASSERT_EQ_UL("test_scan_finds_pattern_at_offset0 [offset]", descOffset, off);
    ASSERT_EQ_UL("test_scan_finds_pattern_at_offset0 [len]", OLD_DESC_LEN, len);
}

static void test_scan_finds_pattern_with_preamble(void)
{
    // Build SDP packet with 7 bytes of preamble junk
    UCHAR buf[256];
    memset(buf, 0, sizeof(buf));
    ULONG preamble = 7;
    ULONG descOffset = build_sdp_packet(buf, sizeof(buf), preamble,
                                        OLD_DESC, OLD_DESC_LEN, 0);
    if (descOffset == 0) { FAIL("test_scan_finds_pattern_with_preamble", "build failed"); return; }

    ULONG off = 0, len = 0;
    BOOLEAN found = ScanForSdpHidDescriptor(buf, sizeof(buf), &off, &len);
    ASSERT_TRUE("test_scan_finds_pattern_with_preamble [found]", found);
    ASSERT_EQ_UL("test_scan_finds_pattern_with_preamble [offset]", descOffset, off);
    ASSERT_EQ_UL("test_scan_finds_pattern_with_preamble [len]", OLD_DESC_LEN, len);
}

static void test_scan_truncated_outer_sequence_returns_false(void)
{
    // Build a valid-looking packet but truncate so outer SEQUENCE overflows bufSize
    UCHAR buf[128];
    memset(buf, 0, sizeof(buf));
    ULONG descOffset = build_sdp_packet(buf, sizeof(buf), 0,
                                        OLD_DESC, OLD_DESC_LEN, 0);
    if (descOffset == 0) { FAIL("test_scan_truncated_outer_sequence_returns_false", "build failed"); return; }
    // Truncate the buffer right after the outer length byte (byte index 4)
    // so the outer SEQUENCE content is cut off
    ULONG truncLen = 5; // 09 02 06 35 LL — LL present but content cut
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_truncated_outer_sequence_returns_false",
                 ScanForSdpHidDescriptor(buf, truncLen, &off, &len));
}

static void test_scan_0x36_two_byte_sequence_returns_false(void)
{
    // Use 0x36 (2-byte length form) instead of 0x35 for the outer SEQUENCE.
    // The scanner only handles 1-byte (0x35) — 0x36 should yield FALSE.
    UCHAR buf[64];
    memset(buf, 0, sizeof(buf));
    //   09 02 06  <- attribute header
    //   36 00 10  <- 2-byte length form (not handled)
    buf[0] = 0x09; buf[1] = 0x02; buf[2] = 0x06;
    buf[3] = 0x36; buf[4] = 0x00; buf[5] = 0x10;  // 2-byte length, content = 16 bytes
    // Fill remaining with valid-looking inner data
    buf[6]  = 0x35; buf[7]  = 0x08;  // inner SEQUENCE_1B
    buf[8]  = 0x08; buf[9]  = 0x22;  // UINT8, 0x22
    buf[10] = 0x25; buf[11] = 0x04;  // TEXT_1B, 4 bytes
    buf[12] = 0x01; buf[13] = 0x02; buf[14] = 0x03; buf[15] = 0x04; // descriptor

    ULONG off = 0, len = 0;
    // outer byte at position 3 is 0x36, which != SDP_DE_SEQUENCE_1B (0x35)
    // → scanner skips → returns FALSE
    ASSERT_FALSE("test_scan_0x36_two_byte_sequence_returns_false",
                 ScanForSdpHidDescriptor(buf, 64, &off, &len));
}

static void test_scan_desc_len_zero_skipped(void)
{
    // Construct a pattern where desc_len byte is 0 — must be skipped.
    UCHAR buf[64];
    memset(buf, 0, sizeof(buf));
    buf[0] = 0x09; buf[1] = 0x02; buf[2] = 0x06; // attr header
    buf[3] = 0x35; buf[4] = 0x08;                 // outer SEQUENCE_1B length=8
    buf[5] = 0x35; buf[6] = 0x06;                 // inner SEQUENCE_1B length=6
    buf[7] = 0x08; buf[8] = 0x22;                 // UINT8 0x22
    buf[9] = 0x25; buf[10] = 0x00;                // TEXT_1B, length=0 ← rejected
    // (remaining bytes don't matter)
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_desc_len_zero_skipped",
                 ScanForSdpHidDescriptor(buf, 64, &off, &len));
}

static void test_scan_desc_overflows_buffer_returns_false(void)
{
    // Build a valid packet but hand a bufSize that's exactly 1 byte short of
    // containing the full descriptor payload.
    UCHAR buf[256];
    memset(buf, 0, sizeof(buf));
    ULONG descOffset = build_sdp_packet(buf, sizeof(buf), 0,
                                        OLD_DESC, OLD_DESC_LEN, 0);
    if (descOffset == 0) { FAIL("test_scan_desc_overflows_buffer_returns_false", "build failed"); return; }
    // required size = descOffset + OLD_DESC_LEN; trim by 1
    ULONG needed = descOffset + OLD_DESC_LEN;
    ULONG off = 0, len = 0;
    ASSERT_FALSE("test_scan_desc_overflows_buffer_returns_false",
                 ScanForSdpHidDescriptor(buf, needed - 1, &off, &len));
}

static void test_scan_multiple_attributes_finds_first_valid(void)
{
    // Two SDP attributes concatenated: first is NOT the HIDDescriptorList
    // (different attribute ID); second is the correct one. Scanner must skip
    // the first and return the second.
    UCHAR buf[256];
    memset(buf, 0, sizeof(buf));

    // First "attribute" — wrong attribute ID (0x0200 instead of 0x0206)
    // Uses same SEQUENCE structure but different attr bytes → scanner will
    // skip at the buf[i+2] != 0x06 check.
    UCHAR *p = buf;
    *p++ = 0x09; *p++ = 0x02; *p++ = 0x00; // wrong attr id
    *p++ = 0x35; *p++ = 0x08;
    *p++ = 0x35; *p++ = 0x06;
    *p++ = 0x08; *p++ = 0x22;
    *p++ = 0x25; *p++ = 0x04;
    *p++ = 0xDE; *p++ = 0xAD; *p++ = 0xBE; *p++ = 0xEF; // fake desc

    ULONG preamble2 = (ULONG)(p - buf);

    // Now build the real attribute
    ULONG descOffset = build_sdp_packet(p, sizeof(buf) - preamble2, 0,
                                        OLD_DESC, OLD_DESC_LEN, 0);
    if (descOffset == 0) {
        FAIL("test_scan_multiple_attributes_finds_first_valid", "build failed");
        return;
    }
    descOffset += preamble2; // adjust for the prefix we wrote directly

    ULONG totalLen = preamble2 + 3 + 2 + 2 + 2 + 2 + OLD_DESC_LEN + 0;
    // compute actual used length from build_sdp_packet result
    // (easier: use the full buf, let the scanner stop at first match)
    ULONG off = 0, len = 0;
    BOOLEAN found = ScanForSdpHidDescriptor(buf, sizeof(buf), &off, &len);
    (void)totalLen;
    ASSERT_TRUE("test_scan_multiple_attributes_finds_first_valid [found]", found);
    ASSERT_EQ_UL("test_scan_multiple_attributes_finds_first_valid [offset]", descOffset, off);
    ASSERT_EQ_UL("test_scan_multiple_attributes_finds_first_valid [len]", OLD_DESC_LEN, len);
}

// ===========================================================================
// PatchSdpHidDescriptor tests
// ===========================================================================

// Helper: build a full SDP buffer, return descOffset; caller may patch it.
static ULONG make_patch_buffer(UCHAR *buf, ULONG bufSize,
                                const UCHAR *oldDesc, ULONG oldDescLen,
                                ULONG tailLen)
{
    return build_sdp_packet(buf, bufSize, 0, oldDesc, oldDescLen, tailLen);
}

static void test_patch_too_small_offset_returns_false(void)
{
    UCHAR buf[256] = {0};
    ULONG newUsed = 0;
    // descOffset < 6 is invalid framing
    ASSERT_FALSE("test_patch_too_small_offset_returns_false",
                 PatchSdpHidDescriptor(buf, sizeof(buf), 5, 10, &newUsed));
}

static void test_patch_replacement_same_size(void)
{
    // Build a buffer where oldDesc has exactly the same byte count as g_HidDescriptor.
    // Patch should succeed, no memmove needed, tail unchanged.
    // Pass the exact used byte count as bufSize (not allocation size) so the
    // function's tailBytes calculation is accurate.
    ULONG newDescLen = g_HidDescriptorSize; // 113
    UCHAR *oldDesc = (UCHAR *)malloc(newDescLen);
    if (!oldDesc) { FAIL("test_patch_replacement_same_size", "alloc failed"); return; }
    memset(oldDesc, 0xFF, newDescLen);

    ULONG tailLen = 8;
    ULONG alloc = 512;
    UCHAR *buf = (UCHAR *)calloc(1, alloc);
    if (!buf) { free(oldDesc); FAIL("test_patch_replacement_same_size", "alloc failed"); return; }

    ULONG descOffset = make_patch_buffer(buf, alloc, oldDesc, newDescLen, tailLen);
    if (descOffset == 0) {
        free(buf); free(oldDesc);
        FAIL("test_patch_replacement_same_size", "build failed"); return;
    }

    // usedSize = exact bytes written by build_sdp_packet
    ULONG usedSize = descOffset + newDescLen + tailLen;

    // Record tail bytes before patch
    UCHAR tailBefore[8];
    memcpy(tailBefore, buf + descOffset + newDescLen, tailLen);

    ULONG newUsed = 0;
    // Pass usedSize as bufSize so tailBytes = tailLen exactly
    BOOLEAN ok = PatchSdpHidDescriptor(buf, usedSize, descOffset, newDescLen, &newUsed);
    ASSERT_TRUE("test_patch_replacement_same_size [returns TRUE]", ok);

    // Descriptor payload replaced with g_HidDescriptor
    ASSERT_MEM_EQ("test_patch_replacement_same_size [descriptor content]",
                  g_HidDescriptor, buf + descOffset, newDescLen);

    // Tail must be unmodified
    ASSERT_MEM_EQ("test_patch_replacement_same_size [tail unchanged]",
                  tailBefore, buf + descOffset + newDescLen, tailLen);

    // newBufUsed = descOffset + newDescLen + tailLen
    ULONG expectedUsed = descOffset + newDescLen + tailLen;
    ASSERT_EQ_UL("test_patch_replacement_same_size [newBufUsed]", expectedUsed, newUsed);

    free(buf); free(oldDesc);
}

static void test_patch_replacement_smaller_memmoves_tail(void)
{
    // oldDesc is LARGER than g_HidDescriptor → replacement makes it smaller.
    // memmove brings tail backward; gap at end is zeroed.
    ULONG oldDescLen = g_HidDescriptorSize + 20; // 20 bytes bigger
    UCHAR *oldDesc = (UCHAR *)malloc(oldDescLen);
    if (!oldDesc) { FAIL("test_patch_replacement_smaller_memmoves_tail", "alloc failed"); return; }
    memset(oldDesc, 0xCC, oldDescLen);

    ULONG tailLen = 12;
    ULONG alloc = 512;
    UCHAR *buf = (UCHAR *)calloc(1, alloc);
    if (!buf) { free(oldDesc); FAIL("test_patch_replacement_smaller_memmoves_tail", "alloc failed"); return; }

    ULONG descOffset = make_patch_buffer(buf, alloc, oldDesc, oldDescLen, tailLen);
    if (descOffset == 0) {
        free(buf); free(oldDesc);
        FAIL("test_patch_replacement_smaller_memmoves_tail", "build failed"); return;
    }

    // usedSize = exact bytes written
    ULONG usedSize = descOffset + oldDescLen + tailLen;

    // Record original tail
    UCHAR tailBefore[12];
    memcpy(tailBefore, buf + descOffset + oldDescLen, tailLen);

    ULONG newUsed = 0;
    // Pass usedSize so tailBytes = tailLen exactly
    BOOLEAN ok = PatchSdpHidDescriptor(buf, usedSize, descOffset, oldDescLen, &newUsed);
    ASSERT_TRUE("test_patch_replacement_smaller [returns TRUE]", ok);

    // New descriptor written at descOffset
    ASSERT_MEM_EQ("test_patch_replacement_smaller [descriptor content]",
                  g_HidDescriptor, buf + descOffset, g_HidDescriptorSize);

    // Tail moved to descOffset + g_HidDescriptorSize
    ULONG newTailOffset = descOffset + g_HidDescriptorSize;
    ASSERT_MEM_EQ("test_patch_replacement_smaller [tail at new position]",
                  tailBefore, buf + newTailOffset, tailLen);

    // Gap bytes zeroed (gap follows new tail)
    ULONG gapStart = newTailOffset + tailLen;
    ULONG gapLen   = oldDescLen - g_HidDescriptorSize;
    UCHAR *gap = buf + gapStart;
    int gapZeroed = 1;
    for (ULONG i = 0; i < gapLen; i++) {
        if (gap[i] != 0) { gapZeroed = 0; break; }
    }
    ASSERT_TRUE("test_patch_replacement_smaller [gap zeroed]", gapZeroed);

    // Length bytes updated
    ASSERT_EQ_UL("test_patch_replacement_smaller [TEXT_STRING len byte]",
                 g_HidDescriptorSize, (ULONG)buf[descOffset - 1]);

    free(buf); free(oldDesc);
}

static void test_patch_replacement_larger_returns_false(void)
{
    // Design constraint: PatchSdpHidDescriptor cannot expand in-place.
    // When g_HidDescriptor (newDescLen) > oldDescLen, the function must
    // return FALSE regardless of physical buffer allocation because
    // tailBytes = bufSize - tailOffset, so newBufSize always exceeds bufSize
    // when newDescLen > oldDescLen.
    //
    // This is intentional: the BRB ACL buffer is fixed-size (allocated by BthEnum).
    // If the old device descriptor was smaller than our replacement, the user must
    // force re-pair with a larger SDP buffer — we cannot patch in-place.
    ULONG oldDescLen = g_HidDescriptorSize - 10; // strictly smaller than g_HidDescriptor
    UCHAR *oldDesc = (UCHAR *)malloc(oldDescLen);
    if (!oldDesc) { FAIL("test_patch_replacement_larger_returns_false", "alloc failed"); return; }
    memset(oldDesc, 0xDD, oldDescLen);

    ULONG tailLen = 0; // no tail to simplify the math
    ULONG tempAlloc = 512;
    UCHAR *tempBuf = (UCHAR *)calloc(1, tempAlloc);
    if (!tempBuf) { free(oldDesc); FAIL("test_patch_replacement_larger_returns_false", "alloc failed"); return; }
    ULONG descOffset = make_patch_buffer(tempBuf, tempAlloc, oldDesc, oldDescLen, tailLen);
    free(tempBuf);
    if (descOffset == 0) {
        free(oldDesc);
        FAIL("test_patch_replacement_larger_returns_false", "build failed"); return;
    }

    // Allocate generously; pass usedOld as bufSize (exact old content length)
    ULONG usedOld = descOffset + oldDescLen + tailLen;
    UCHAR *buf = (UCHAR *)calloc(1, usedOld);
    if (!buf) { free(oldDesc); FAIL("test_patch_replacement_larger_returns_false", "alloc failed"); return; }
    ULONG d2 = make_patch_buffer(buf, usedOld, oldDesc, oldDescLen, tailLen);
    if (d2 == 0) {
        free(buf); free(oldDesc);
        FAIL("test_patch_replacement_larger_returns_false", "build2 failed"); return;
    }

    // Save original
    UCHAR *orig = (UCHAR *)malloc(usedOld);
    if (!orig) { free(buf); free(oldDesc); FAIL("test_patch_replacement_larger_returns_false", "alloc failed"); return; }
    memcpy(orig, buf, usedOld);

    ULONG newUsed = 0;
    // Pass usedOld as bufSize. Since g_HidDescriptorSize > oldDescLen,
    // newBufSize = descOffset + g_HidDescriptorSize + tailBytes
    //            = descOffset + g_HidDescriptorSize + (usedOld - descOffset - oldDescLen)
    //            = g_HidDescriptorSize - oldDescLen + usedOld  >  usedOld
    // → must return FALSE.
    BOOLEAN ok = PatchSdpHidDescriptor(buf, usedOld, descOffset, oldDescLen, &newUsed);
    ASSERT_FALSE("test_patch_replacement_larger_returns_false [returns FALSE]", ok);
    // Buffer must be unmodified
    ASSERT_MEM_EQ("test_patch_replacement_larger_returns_false [buf unchanged]",
                  orig, buf, usedOld);

    free(buf); free(orig); free(oldDesc);
}

static void test_patch_too_large_buffer_unchanged(void)
{
    // Buffer is exactly one byte too small to hold the expanded replacement.
    // PatchSdpHidDescriptor must return FALSE and leave the buffer unmodified.
    ULONG oldDescLen = 4; // tiny placeholder — much smaller than g_HidDescriptor
    UCHAR *oldDesc = (UCHAR *)malloc(oldDescLen);
    if (!oldDesc) { FAIL("test_patch_too_large_buffer_unchanged", "alloc failed"); return; }
    memset(oldDesc, 0xEE, oldDescLen);

    // g_HidDescriptorSize >> oldDescLen so there will be a buffer-size gap.
    if (g_HidDescriptorSize <= oldDescLen) {
        free(oldDesc);
        FAIL("test_patch_too_large_buffer_unchanged",
             "SKIP: g_HidDescriptorSize <= oldDescLen, test invalid"); return;
    }

    ULONG tailLen = 0;
    // First pass: discover descOffset using a generous temp buffer.
    ULONG tmpAlloc = 512;
    UCHAR *tmpBuf = (UCHAR *)calloc(1, tmpAlloc);
    if (!tmpBuf) { free(oldDesc); FAIL("test_patch_too_large_buffer_unchanged", "alloc failed"); return; }
    ULONG descOffset = make_patch_buffer(tmpBuf, tmpAlloc, oldDesc, oldDescLen, tailLen);
    free(tmpBuf);
    if (descOffset == 0) {
        free(oldDesc);
        FAIL("test_patch_too_large_buffer_unchanged", "build failed"); return;
    }

    // tightSize = exactly the bytes used by the OLD content
    ULONG tightSize = descOffset + oldDescLen + tailLen;
    // The expanded size would be: descOffset + g_HidDescriptorSize + tailLen
    // Since g_HidDescriptorSize > oldDescLen, tightSize < needed → Patch returns FALSE.

    UCHAR *buf = (UCHAR *)calloc(1, tightSize + 16); // +16 for overflow safety in assertions
    if (!buf) { free(oldDesc); FAIL("test_patch_too_large_buffer_unchanged", "alloc failed"); return; }
    ULONG d2 = make_patch_buffer(buf, tightSize, oldDesc, oldDescLen, tailLen);
    if (d2 == 0) {
        free(buf); free(oldDesc);
        FAIL("test_patch_too_large_buffer_unchanged", "build2 failed"); return;
    }

    // Save original buffer
    UCHAR *orig = (UCHAR *)malloc(tightSize);
    if (!orig) { free(buf); free(oldDesc); FAIL("test_patch_too_large_buffer_unchanged", "alloc failed"); return; }
    memcpy(orig, buf, tightSize);

    ULONG newUsed = 0;
    // Pass tightSize as bufSize — too small for g_HidDescriptor replacement
    BOOLEAN ok = PatchSdpHidDescriptor(buf, tightSize, descOffset, oldDescLen, &newUsed);
    ASSERT_FALSE("test_patch_too_large_buffer_unchanged [returns FALSE]", ok);
    // Buffer must be completely unmodified
    ASSERT_MEM_EQ("test_patch_too_large_buffer_unchanged [buf unchanged]",
                  orig, buf, tightSize);

    free(buf); free(orig); free(oldDesc);
}

static void test_patch_tlv_length_bytes_updated(void)
{
    // Verify the SDP TLV length bytes at [descOffset-1], [descOffset-3], [descOffset-5]
    // are updated correctly after a successful patch.
    //
    // Use oldDescLen == g_HidDescriptorSize (same-size replacement) so that
    // PatchSdpHidDescriptor succeeds — the function only patches in-place when
    // newDescLen <= oldDescLen (BRB buffer is fixed-size by design).
    ULONG oldDescLen = g_HidDescriptorSize; // same size — patch will succeed
    UCHAR *oldDesc = (UCHAR *)malloc(oldDescLen);
    if (!oldDesc) { FAIL("test_patch_tlv_length_bytes_updated", "alloc failed"); return; }
    memset(oldDesc, 0xAB, oldDescLen);
    ULONG tailLen = 4;
    ULONG tempAlloc = 512;
    UCHAR *tmpBuf = (UCHAR *)calloc(1, tempAlloc);
    if (!tmpBuf) { free(oldDesc); FAIL("test_patch_tlv_length_bytes_updated", "alloc failed"); return; }
    ULONG descOffset = make_patch_buffer(tmpBuf, tempAlloc, oldDesc, oldDescLen, tailLen);
    free(tmpBuf);
    if (descOffset == 0) { free(oldDesc); FAIL("test_patch_tlv_length_bytes_updated", "build1 failed"); return; }

    ULONG usedOld = descOffset + oldDescLen + tailLen;
    UCHAR *buf = (UCHAR *)calloc(1, usedOld);
    if (!buf) { free(oldDesc); FAIL("test_patch_tlv_length_bytes_updated", "alloc failed"); return; }
    ULONG d2 = make_patch_buffer(buf, usedOld, oldDesc, oldDescLen, tailLen);
    if (d2 == 0) {
        free(buf); free(oldDesc);
        FAIL("test_patch_tlv_length_bytes_updated", "build2 failed"); return;
    }

    ULONG newUsed = 0;
    BOOLEAN ok = PatchSdpHidDescriptor(buf, usedOld, descOffset, oldDescLen, &newUsed);
    if (!ok) { free(buf); free(oldDesc); FAIL("test_patch_tlv_length_bytes_updated", "patch failed"); return; }

    ULONG newDescLen    = g_HidDescriptorSize;
    UCHAR expectedText  = (UCHAR)newDescLen;
    ULONG innerPayload  = 2 + 2 + newDescLen;
    UCHAR expectedInner = (UCHAR)(innerPayload & 0xFF);
    ULONG outerPayload  = 2 + innerPayload;
    UCHAR expectedOuter = (UCHAR)(outerPayload & 0xFF);

    ASSERT_EQ_UL("test_patch_tlv_length_bytes_updated [TEXT_STRING len]",
                 expectedText,  (ULONG)buf[descOffset - 1]);
    ASSERT_EQ_UL("test_patch_tlv_length_bytes_updated [inner SEQUENCE len]",
                 expectedInner, (ULONG)buf[descOffset - 3]);
    ASSERT_EQ_UL("test_patch_tlv_length_bytes_updated [outer SEQUENCE len]",
                 expectedOuter, (ULONG)buf[descOffset - 5]);

    free(buf);
}

// ===========================================================================
// ClampInt8 tests
// ===========================================================================

static void test_clamp_within_range(void)
{
    ASSERT_EQ_UL("test_clamp_within_range_zero",    0,    (ULONG)(unsigned char)ClampInt8(0));
    ASSERT_EQ_UL("test_clamp_within_range_pos",     50,   (ULONG)(unsigned char)ClampInt8(50));
}

static void test_clamp_max_positive(void)
{
    ASSERT_EQ_UL("test_clamp_max_positive",  127, (ULONG)(unsigned char)ClampInt8(200));
}

static void test_clamp_min_negative(void)
{
    // -127 cast to unsigned char is 129 on two's complement
    INT8 result = ClampInt8(-200);
    ASSERT_TRUE("test_clamp_min_negative", result == -127);
}

static void test_clamp_boundary(void)
{
    ASSERT_EQ_UL("test_clamp_boundary_127",  127, (ULONG)(unsigned char)ClampInt8(127));
    INT8 r = ClampInt8(-127);
    ASSERT_TRUE("test_clamp_boundary_neg127", r == -127);
}

// ===========================================================================
// TouchX / TouchY tests
// (Signed 12-bit values packed across two bytes via Linux formula)
// ===========================================================================

static void test_touch_x_zero(void)
{
    UCHAR t[3] = { 0x00, 0x00, 0x00 };
    INT32 x = TouchX(t);
    ASSERT_EQ_UL("test_touch_x_zero", 0, (ULONG)(unsigned int)x);
}

static void test_touch_x_positive(void)
{
    // Encode +128 into the two-byte 12-bit little-endian field.
    // Formula: result = (t[1]<<28 | t[0]<<20) >> 20 (arithmetic right shift)
    // To encode value V (signed 12-bit): the 12-bit field occupies bits [31:20]
    // after the shift, so we need: (V & 0xFFF) << 20, then split across t[0]/t[1].
    // For V = 128 = 0x080:
    //   packed = 0x080 << 20 = 0x08000000
    //   t[0] = bits [27:20] = 0x00, t[1] = bits [31:28] = 0x08
    // BUT the formula packs differently: t[1]<<28 | t[0]<<20
    //   So t[0] holds bits [27:20], t[1] holds bits [31:28] of the 32-bit word.
    //   For V=128 (0x080): the 12-bit value occupies bits[31:20] of the 32-bit signed int.
    //   We want (t[1]<<28 | t[0]<<20) >> 20 == 128
    //   => (t[1]<<28 | t[0]<<20) == 128 << 20 = 0x08000000
    //   => t[1]<<28 = upper nibble: t[1]=0 (since 0x08000000 has 0 in bits31-28)
    //   Actually 0x08000000: bit31=0, bits[30:28]=000, bits[27:24]=1000
    //   t[1]<<28 covers bits[31:28] → t[1]=0
    //   t[0]<<20 covers bits[27:20] → bits[27:20] of 0x08000000 = 0x80 → t[0]=0x80
    UCHAR t[3] = { 0x80, 0x00, 0x00 };
    INT32 x = TouchX(t);
    ASSERT_EQ_UL("test_touch_x_positive", 128, (ULONG)(unsigned int)(INT32)x);
}

static void test_touch_y_zero(void)
{
    UCHAR t[3] = { 0x00, 0x00, 0x00 };
    INT32 y = TouchY(t);
    ASSERT_EQ_UL("test_touch_y_zero", 0, (ULONG)(unsigned int)y);
}

// ===========================================================================
// TranslateReport12 tests
// ===========================================================================

static void test_translate_too_short_returns_false(void)
{
    // bufSize < TOUCH2_HEADER + 1 (7+1=8) → FALSE
    UCHAR buf[6] = { 0x12, 0x00, 0x00, 0x00, 0x00, 0x00 };
    ULONG repLen = 0;
    ASSERT_FALSE("test_translate_too_short_returns_false",
                 TranslateReport12(buf, 6, NULL, &repLen));
}

static void test_translate_no_touch_blocks_output_mouse(void)
{
    // bufSize = TOUCH2_HEADER + 1 (8) → minimum to pass the guard, 0 complete
    // touch blocks (8 - 7 = 1 byte < TOUCH2_BLOCK=8). Must return TRUE and emit
    // 5-byte Report 0x01 with zero X/Y/wheel (no valid touch blocks parsed).
    UCHAR buf[8] = { 0x12, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    ULONG repLen = 0;
    BOOLEAN ok = TranslateReport12(buf, 8, NULL, &repLen);
    ASSERT_TRUE("test_translate_no_touch_blocks [returns TRUE]", ok);
    ASSERT_EQ_UL("test_translate_no_touch_blocks [report len]", 5, repLen);
    ASSERT_EQ_UL("test_translate_no_touch_blocks [report id]",  0x01, (ULONG)buf[0]);
    // buttons: original buf[1] & 0x03 = 0x01 & 0x03 = 0x01
    ASSERT_EQ_UL("test_translate_no_touch_blocks [buttons]", 0x01, (ULONG)buf[1]);
    // x, y, wheelV must be zero (no touch block decoded)
    ASSERT_EQ_UL("test_translate_no_touch_blocks [x=0]",     0, (ULONG)buf[2]);
    ASSERT_EQ_UL("test_translate_no_touch_blocks [y=0]",     0, (ULONG)buf[3]);
    ASSERT_EQ_UL("test_translate_no_touch_blocks [wheelV=0]",0, (ULONG)buf[4]);
}

static void test_translate_single_touch_block_pointer(void)
{
    // bufSize = TOUCH2_HEADER(7) + TOUCH2_BLOCK(8) = 15 → 1 touch block → pointer move
    UCHAR buf[15];
    memset(buf, 0, sizeof(buf));
    buf[0] = 0x12;  // report ID
    buf[1] = 0x00;  // no buttons
    // Touch block at buf[7..14]:
    //   t[0]=0x80, t[1]=0x00 → TouchX = 128 → x = ClampInt8(128/4) = 32
    //   t[2]=0x00 → TouchY: -((t[2]<<24|t[1]<<16)>>20) = 0 → y = 0
    buf[7] = 0x80; buf[8] = 0x00; // x
    buf[9] = 0x00; // y high
    // rest of block zeros (state=0x00, not TOUCH_START/DRAG so doesn't matter for 1-finger)
    buf[14] = 0x00; // state byte

    ULONG repLen = 0;
    BOOLEAN ok = TranslateReport12(buf, 15, NULL, &repLen);
    ASSERT_TRUE("test_translate_single_touch [returns TRUE]", ok);
    ASSERT_EQ_UL("test_translate_single_touch [report id]",  0x01, (ULONG)buf[0]);
    ASSERT_EQ_UL("test_translate_single_touch [x=32]",       32,   (ULONG)buf[2]);
    ASSERT_EQ_UL("test_translate_single_touch [y=0]",         0,   (ULONG)buf[3]);
}

static void test_translate_two_touch_blocks_scroll_drag(void)
{
    // bufSize = TOUCH2_HEADER(7) + 2*TOUCH2_BLOCK(16) = 23 → 2 touch blocks → scroll
    UCHAR buf[23];
    memset(buf, 0, sizeof(buf));
    buf[0] = 0x12;
    buf[1] = 0x00;
    // First touch block at buf[7]:
    //   t[0]=0x80, t[1]=0x00 → TouchX=128, TouchY=0
    //   state byte t[7] = 0x40 (TOUCH_DRAG) → scroll path
    buf[7]  = 0x80; buf[8]  = 0x00;
    buf[9]  = 0x00;
    buf[14] = 0x40; // state = TOUCH_DRAG

    INT8 wheelH = 0;
    ULONG repLen = 0;
    BOOLEAN ok = TranslateReport12(buf, 23, &wheelH, &repLen);
    ASSERT_TRUE("test_translate_two_touch_scroll [returns TRUE]", ok);
    // wheelH from X: ClampInt8(128/8) = 16
    ASSERT_EQ_UL("test_translate_two_touch_scroll [wheelH=16]", 16, (ULONG)(unsigned char)wheelH);
    // wheelV from Y: 0
    ASSERT_EQ_UL("test_translate_two_touch_scroll [wheelV=0]", 0, (ULONG)buf[4]);
}

// ===========================================================================
// main
// ===========================================================================

int main(void)
{
    printf("=== Magic Mouse SDP/Input unit tests ===\n\n");

    printf("-- ScanForSdpHidDescriptor --\n");
    test_scan_null_returns_false();
    test_scan_empty_returns_false();
    test_scan_below_min_len_returns_false();
    test_scan_all_zeros_returns_false();
    test_scan_finds_pattern_at_offset0();
    test_scan_finds_pattern_with_preamble();
    test_scan_truncated_outer_sequence_returns_false();
    test_scan_0x36_two_byte_sequence_returns_false();
    test_scan_desc_len_zero_skipped();
    test_scan_desc_overflows_buffer_returns_false();
    test_scan_multiple_attributes_finds_first_valid();

    printf("\n-- PatchSdpHidDescriptor --\n");
    test_patch_too_small_offset_returns_false();
    test_patch_replacement_same_size();
    test_patch_replacement_smaller_memmoves_tail();
    test_patch_replacement_larger_returns_false();
    test_patch_too_large_buffer_unchanged();
    test_patch_tlv_length_bytes_updated();

    printf("\n-- ClampInt8 --\n");
    test_clamp_within_range();
    test_clamp_max_positive();
    test_clamp_min_negative();
    test_clamp_boundary();

    printf("\n-- TouchX / TouchY --\n");
    test_touch_x_zero();
    test_touch_x_positive();
    test_touch_y_zero();

    printf("\n-- TranslateReport12 --\n");
    test_translate_too_short_returns_false();
    test_translate_no_touch_blocks_output_mouse();
    test_translate_single_touch_block_pointer();
    test_translate_two_touch_blocks_scroll_drag();

    printf("\n=== Results: %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail > 0 ? 1 : 0;
}
