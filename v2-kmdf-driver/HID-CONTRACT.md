# HID contract — 2.0.4 scroll (PID 0323)

Authoritative live probe: **2026-08-30 21:23 MDT** on Apr 30 MagicMouseFix
`MagicMouseDriver.sys` SHA256 `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B`
(pointer works, no wheel). Stack is already `HidBth / MagicMouseDriver / BthEnum`.

## Must keep (Apr 30 pointer)

| Item | Value |
|------|--------|
| COL01 report | Input **0x12** |
| Pointer X | Generic Desktop **0x0030** on report 0x12 |
| Pointer Y | Generic Desktop **0x0031** on report 0x12 |
| Optical fields | `[0x12][buttons][X i16 LE][Y i16 LE]` — same offsets as native / Linux MOUSE2 |
| Battery | HID Input **0x90** on **COL02** (`HidD_GetInputReport`; percent at `buf[2]`) |

Do **not** replace X/Y with Wheel. Do **not** convert 0x12 → RID 0x02.

## Must add (scroll)

| Item | Value |
|------|--------|
| Wheel | Generic Desktop **0x0038** on the **same** 0x12 collection, **after** X/Y |
| AC Pan | Consumer **0x0238** on the same 0x12 collection |

Report after injection (8 bytes):

```
[0] RID 0x12
[1] buttons
[2..3] X INT16 LE     — kept
[4..5] Y INT16 LE     — kept
[6] AC Pan INT8       — extra
[7] Wheel INT8        — extra (0x0038)
```

## Must not use

| Item | Why |
|------|-----|
| Feature **0x47** | Fails on COL01 and COL02 on the live Apr 30 stack |
| RID **0x02** / Descriptor C | hidclass never bound that on this PC |
| PATH-A `applewirelessmouse.sys` | SHIPBLOCKER BSOD 0xD1 |

## Event 41 hunch (not fact)

Kernel-Power Event 41 after the 2.0.4 install
`845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3` may have been:

1. **In-place oem26 overwrite** — same INF identity as `magicmousedriver.inf_amd64_79beb68f1da25da4` so System32 `MagicMouseDriver.sys` was a hardlink; unsigned `pr3-activate-204` then the signed install wrote through that link.
2. **DriverEntry / PnP / ACL grow** in that binary — rewriting a 6-byte native 0x12 to 8 bytes without a proven ACL buffer capacity is a bugcheck candidate.

This tree keeps the 0x12 X/Y usages, adds Wheel as extra, and **refuses to write past the ACL buffer**. If capacity is only 6 bytes, native X/Y is left intact (pointer-safe).

Do not treat the hunch as proven. Hardware must confirm pointer **and** scroll after a signed unique-package `pnputil /add-driver`.
