# Spec 4 — KMDF unique 2.0.4.1 scroll package (PID 0323)

## Current State

**2026-09-01 hardware proof (user: it's working).** Pointer. Battery `0x90`. **2-finger** surface scroll. 1-finger glass does not scroll. oem16 `AD5D244B`. Checkpoint: `v2-kmdf-driver/CHECKPOINT-2026-09-01-SCROLL.md`.

Loaded unique dest `MagicMouseDriver-kmdf-204-scroll.sys` unsigned `E73EC0A8…`, signed `9901390e…`, SCM `MagicMouseDriver204Scroll`, oem50. `MM_SCROLL_STEP` **8** + `TWO_FINGER` (`down < 2`). Do not ship detent 224. After pnputil, sleep 3s then `HidD_SetFeature(F1)` or `LastAclReceived` stays 9.

Gestures = Wheel + AC Pan only (not PTP / macOS). PTP needs a later virtual device, not a larger SDP overlay (0x50). v1/v2 = `PidInfo` after dumps; never 0323 overlay on 030D/0269.

Gate: `test_scroll_threshold.py` quotes `SCROLL_STEP_8` and `TWO_FINGER` against `GestureEngine.c`.

This section is authoritative.


## Summary

Done = unique 2.0.4.1 KMDF source with a **135-byte same-size SDP overlay** (`memcpy` 135 HID bytes only; native prefix `09 02 06 35 8D 35 8B 08 22 25 87` unchanged) + executable gate (`specs/gate_4.py`) + host tests (`v2-kmdf-driver/tests/test_sdp_overlay.py`, `v2-kmdf-driver/tests/test_hid_acl.py`) proving overlay + battery `0x90` passthrough **and** scroll `0x12`+Wheel fail-closed, without PATH-A / live SCM hijack / `SdpWalkStream`.

Unique dest `MagicMouseDriver-kmdf-204-scroll.sys`. Unique SCM `MagicMouseDriver204Scroll`. HID: RID `0x12` X/Y `0x0030`/`0x0031` then **Count 1** Consumer AC Pan `0x0238` (byte 6) then Count 1 Wheel `0x0038` (byte 7); battery Input `0x90` COL02 (`HidD_GetInputReport`; percent at byte[2], 0–100); Feature `0xF1` Count 2 vendor `0xFF00` Usage `0x01` (not GD Wheel); never Feature `0x47`; never RID `0x02`. `g_HidDescriptor` is 135 bytes (`sizeof == 0x87`). Overlay is memcpy-only: no length rewrite. Do **not** leave Wheel inheriting X/Y Count 2.

Fail closed: missing prefix → **no mutation**; `0x90` never rewritten; 6→8 refused without `SdpPatchSuccess`/capacity; Wheel only on 8-byte `0x12` after success. Growing 6→8 without proven capacity is Event 41. PATH-A is `0xD1`. Live SCM hijack of `MagicMouseDriver` (oem16 / SHA `AD5D244B`) is Event 41 / BSOD. Length-rewrite SDP is 0x50.

Draft PR #4 stays draft until this dirty worktree is committed. No `adw:merge` from this node.


## Files to Touch

Spec-overlay slice (AdwSpecOverlay):

1. `specs/4-kmdf-204-unique-scroll.md` — this spec (135-byte memcpy overlay; no `SdpWalkStream`)
2. `specs/gate_4.py` — executable RED-first gate; `FAIL:`/`PASS:` lines; must exit nonzero until overlay + ACL + `v2-kmdf-driver/tests/test_bsod_regress.py` exist. BSOD file must quote dump `090126-18750`, `BSOD_50`, `buf[4]`, HID `0x87` not 108, Event 41 no-grow, PATH-A `applewirelessmouse`. Must **not** pass because unique INF is already present. `test_sdp_walk.py` with `PATCHED_0x25_IS_108` is a FAIL (that rewrite 0x50'd).

Overlay host test (BUILD owns this file; spec-overlay must not edit it):

3. `v2-kmdf-driver/tests/test_sdp_overlay.py` — 351B native fixture; after overlay, prefix `09 02 06 35 8D 35 8B 08 22 25 87` byte-identical; payload 135B (`0x87`) contains Wheel `09 38`, `85 90`, and Feature `85 F1` (`HID_HAS_85_F1`); no `85 47`/`85 02`; no other bytes in the 351B blob change except those 135. Exit 1 → no msbuild, no sign, no pnputil.

Host ACL tests (AdwHostTests owns this file; spec-overlay must not edit it):

4. `v2-kmdf-driver/tests/test_hid_acl.py` — battery `0x90` passthrough (never rewritten); 6-byte no-grow without `SdpPatchSuccess`/capacity; Wheel only on 8-byte RID `0x12` after success; never Feature `0x47`; unique SCM `MagicMouseDriver204Scroll`

BSOD regression (BUILD owns this file; named after the dumps, not a host `SdpWalkStream`):

MT enable (BUILD owns; spec-overlay must not edit kernel in this node):

4c. `v2-kmdf-driver/tests/test_mt_enable.py` — `LastAclBytes` copied from interrupt ACL IN. Missing `MT_ENABLE_ACL_BYTES` is `gate_4.py` RED.

4d. **Removed.** `check_two_finger` is deleted from `specs/gate_4.py`. `TWO_FINGER` / `down < 2` must not be a pass condition. Missing `TWO_FINGER` is not RED (trackpad/PTP-only; Linux mouse is 1-finger).

4e. `v2-kmdf-driver/tests/test_scroll_threshold.py` — quotes `SCROLL_STEP_224` against `GestureEngine.c`. Missing `SCROLL_STEP_224` is `gate_4.py` RED. Host: 14+8 one-slot DRAG `|stepY|=20` → wheel 0; `90` → 0; `224` → ±1; compact 8-byte `[6]/[7]` → 0; 1-finger 224 must be non-zero.

4b. `v2-kmdf-driver/tests/test_bsod_regress.py` — fail-closed vs C/INF/install for the three crash classes: `0x50` dumps `090126-17390-01` / `090126-18750-01` (no length rewrite, HID not 108, no `buf[4]`, `RtlCopyMemory` only); Event 41 (6→8 refused without `SdpPatchSuccess`/capacity; unique SCM; install refuses unsigned); `0xD1` (no PATH-A dest). Delete `test_sdp_walk.py` — it cloned `SdpWalkStream` and gated the 108-byte rewrite.

Already in tree at `7087f4b` (do not re-own from this slice; kernel overlay is a sibling — **no kernel edits this node**):

5. `v2-kmdf-driver/Driver.c` / `Driver.h` — BRB via `bthddi.h`; ACL grow gated on `SdpPatchSuccess` + proven capacity; Diag under `MagicMouseDriver204Scroll`
6. `v2-kmdf-driver/AclTranslate.c` / `AclTranslate.h` — 6→8 only if capacity >= need; `0x90` passthrough
7. `v2-kmdf-driver/InputHandler.c` / `InputHandler.h` — overlay: find 11-byte prefix; memcpy 135 bytes only; missing prefix → no-op (no `0x35`/`0x36`/`buf[4]`/`0x25`)
8. `v2-kmdf-driver/HidDescriptor.c` / `HidDescriptor.h` — `g_HidDescriptor` MUST be 135 bytes (`0x87`)
9. `v2-kmdf-driver/GestureEngine.c` / `GestureEngine.h` — RID `0x12` X/Y + Wheel extra
10. `v2-kmdf-driver/MagicMouseDriver-kmdf-204-scroll.inf` — dest `MagicMouseDriver-kmdf-204-scroll.sys`; AddService/LowerFilters `MagicMouseDriver204Scroll`
11. `v2-kmdf-driver/tests/validate-package.sh` — Linux identity + HID + unique-SCM gate; do not weaken

Do not touch: live `MagicMouseDriver.sys` (SHA `AD5D244B`), `MagicMouseDriver.inf`, PATH-A `applewirelessmouse.sys`, `MAGIC-TRAY.md` (already unique LowerFilters). Do not clone `SdpWalkStream` on the host. **Delete** `test_sdp_walk.py` (108-byte rewrite gate). SDP gate is overlay + `test_bsod_regress.py`.

## Step-by-Step

1. Keep live Apr 30 `MagicMouseDriver.sys` SHA `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B` installed. Fail closed if any script would `Copy-Item` onto System32 or DriverStore, or `/delete-driver` oem16. Do not bind the existing unique DriverStore folder, the System32 unique `ea1f80b4…` sys, or PATH-A. Do not load a kernel driver from this spec-overlay slice. Do not HID-open.
2. Unique identity stays: INF `MagicMouseDriver-kmdf-204-scroll.inf`, dest/ServiceBinary `MagicMouseDriver-kmdf-204-scroll.sys`, DriverVer `09/01/2026,2.0.4.1`. Fail if DriverVer is `08/30/2026,2.0.4.0` or `08/31/2026,2.0.4.0` (oem26 / PR #3 collision).
3. Unique SCM: AddService and LowerFilters MUST be `MagicMouseDriver204Scroll`. MUST NOT be `MagicMouseDriver` — that is live oem16. Hijack rewrites ImagePath without replacing `AD5D244B` on disk; a bugcheck is Event 41 / BSOD. SHOWSTOPPER if INF still names `MagicMouseDriver`.
4. Refuse PATH-A `applewirelessmouse.sys` (known BSOD `0xD1`). Refuse SHA `845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3`. Refuse dest `MagicMouseDriver.sys` / `MagicMouseDriver.inf`. Refuse unsigned activate (`pr3-activate`). Event 41 / 0x50 / 0xD1 → restore **oem16 `AD5D244B`**, not PATH-A.
5. HID blob = 135 bytes, not 108. `g_HidDescriptor[]` so `sizeof == 0x87`. Keep native COL01 RID `0x12` buttons + X/Y `0x0030`/`0x0031`. After X/Y Input, **reset Report Count to 1** and Logical Min/Max to **-127..127**, then Consumer AC Pan `0A 38 02` (report byte 6) then Generic Desktop Wheel `09 38` (report byte 7). Stay 135: drop X/Y Physical Min/Max/Unit/Exponent and shrink Feature `0x55` (`15 00` + `75 08` + `26 FF 00`→`25 FF`). Keep COL02 RID `0x90` Input percent at byte[2]; never Feature `0x47`; never RID `0x02`. If short, add valid HID items (not `0x00`). Do **not** ship `75 08 09 38 81 06` with Count still 2.
6. Kernel overlay, **memcpy only** (no walk): on SDP complete, find the exact 11-byte prefix `09 02 06 35 8D 35 8B 08 22 25 87`. If missing or following string length ≠ 135, **no-op** (native SDP unchanged — pointer + `0x90`, no Wheel, `SdpPatchSuccess` stays 0). If present, `RtlCopyMemory` 135 bytes over the string only. Do not write `0x35`/`0x36`/`buf[4]`/`0x25`. Δ = 0. Fail-closed is **no mutation**, not `SdpPatchSuccess` skip after rewrite. Do **not** implement `SdpWalkStream`.
7. ACL fail-closed: 6→8 grow only if `SdpPatchSuccess` AND proven capacity >= need (8, or 9 with `0xA1`). Else no-op: native 6-byte `0x12` X/Y stays (pointer lives, wheel omitted). Do not treat `BufferSize` as allocation. Growing an 8-byte payload into a 6-byte hidparse report is Event 41.
8. Battery fail-closed: RID `0x90` COL02 is passthrough. `HidD_GetInputReport` `0x90` percent at byte[2] (0–100). Never rewrite `0x90`. Never Feature `0x47`.
9. Scroll: 8-byte RID `0x12` after SDP/capacity success: `[6]` AC Pan `0x0238`, `[7]` Wheel `0x0038` (`GestureEngine.c` / `HID-CONTRACT.md`). Wheel/AC Pan bytes only on that 8-byte report. Never RID `0x02`.
10. Executable gate: `specs/gate_4.py` prints `FAIL:`/`PASS:` lines and exits nonzero on the current tree because `v2-kmdf-driver/tests/test_sdp_overlay.py` is missing **or** does not quote prefix `09 02 06 35 8D 35 8B 08 22 25 87` unchanged after overlay **and** HID `sizeof == 0x87`. Keep 0x90 passthrough + 6-byte no-grow asserts against `AclTranslate.c` / `Driver.c`. Do **not** green the gate because unique INF is already present. Do **not** green the gate on a Python self-model.
11. Overlay host test (sibling BUILD): `python3 v2-kmdf-driver/tests/test_sdp_overlay.py` must prove prefix byte-identical after overlay and payload 135B (`0x87`). Exit 1 → no msbuild, no sign, no pnputil.
12. Host ACL tests (sibling): `python3 v2-kmdf-driver/tests/test_hid_acl.py` must prove `0x90` never rewritten; 6→8 refused without `SdpPatchSuccess`/capacity; Wheel only on 8-byte `0x12` after success.
13. Linux identity gate stays: `bash v2-kmdf-driver/tests/validate-package.sh`. Non-zero is a BUILD fail. Do not skip. It is not a substitute for `specs/gate_4.py`.
14. Hardware (Windows, after overlay test green **and** signed unique pnputil only; not this spec-overlay slice): pointer still moves; finger scroll produces Wheel `0x0038` on report `0x12`; battery `HidD_GetInputReport` `0x90` percent at byte[2] in 0–100; Feature `0x47` keeps failing. Event 41 or `0xD1` or `0x50` or timeout → restore oem16 `AD5D244B`, do not retry unsigned, do not bind PATH-A. Then `owner_approval`. No `adw:merge`. Draft PR #4 stays draft.

## Verification

Linux identity (keep; must not be weakened):

```bash
bash v2-kmdf-driver/tests/validate-package.sh
```

ADW executable gate (must be RED on current tree — `test_sdp_overlay.py` missing or does not quote prefix `09 02 06 35 8D 35 8B 08 22 25 87` unchanged after overlay and HID `sizeof == 0x87`; unique INF present is not a pass; a Python self-model is not a pass; keep 0x90 / 6-byte C-source asserts):

```bash
python3 specs/gate_4.py
```

Host ACL/battery tests (Linux in scope):

```bash
python3 v2-kmdf-driver/tests/test_hid_acl.py
```

SDP same-size overlay (Linux; required before any new `.sys` load). Fixture is native v3 CachedServices 351B from `bthport-discovery-d0c050cc8c4d.txt` (`36 01 5C` … `09 02 06 35 8D 35 8B 08 22 25 87`, string length `0x87`=135). After overlay: prefix **byte-identical**; memcpy 135 HID bytes only; no other bytes in the 351B blob change. Do **not** walk with `SdpWalkStream`. Exit nonzero (RED) until that holds. Do not pnputil if this fails.

```bash
python3 v2-kmdf-driver/tests/test_sdp_overlay.py
```

Host scroll detent (Linux; `check_two_finger` removed — TWO_FINGER is not a pass). Host-only until director queues WDK. Overlay 135 still green. Unique SCM `MagicMouseDriver204Scroll`. No PTP overlay. No 030D/0269 this slice. No oem16 overwrite.

```bash
python3 v2-kmdf-driver/tests/test_scroll_threshold.py
```

- 1-slot DRAG `|stepY|=20` → wheel 0
- 1-slot DRAG `|stepY|=90` → wheel 0 (`SCROLL_HR_THRESHOLD` redundant on 8-bit)
- 1-slot DRAG `|stepY|=224` → wheel ±1
- compact 8-byte garbage `[6]/[7]` → wheel/hwheel 0
- 1-finger 224 **non-zero** (proves TWO_FINGER is gone)

Host tests must fail closed:

- Overlay: prefix `09 02 06 35 8D 35 8B 08 22 25 87` unchanged; HID `sizeof == 0x87`; missing prefix → **no mutation**.
- Battery: `HidD_GetInputReport` `0x90` percent at byte[2] (0–100); `0x90` never rewritten; never Feature `0x47`.
- Scroll: Count 1 AC Pan then Count 1 Wheel on RID `0x12`; overlay test must quote `95 01`, `0A 38 02`, `09 38`; Wheel only on 8-byte `0x12` after `SdpPatchSuccess` + capacity. Count-2 Wheel (inherit X/Y) is a FAIL.
- 6→8 refused without `SdpPatchSuccess`/capacity (native 6-byte `0x12` X/Y stays).
- Fail closed Event 41 (ACL grow / live SCM hijack) / `0xD1` (PATH-A) / `0x50` (length-rewrite SDP; overlay is the fix).

Live restore hash must remain (do not hash-copy or overwrite):

```bash
sha256sum /mnt/c/Windows/System32/drivers/MagicMouseDriver.sys
```

Expected: `ad5d244b176d650961594eded153c46f9a52004c424dabfd86e50844e447546b`. Any other hash after this session is an error.

Hardware (Windows, after signed unique pnputil only **and** after `test_sdp_overlay.py` exits 0; Linux cannot claim this): pointer still moves; Wheel `0x0038` on `0x12`; battery percent at `0x90` byte[2] in 0–100. Timeout, Event 41, `0x50`, or `0xD1` → restore oem16 `AD5D244B`, not PATH-A; do not retry unsigned. `owner_approval` only after that proof.

## Notes for Next Agent

- ADW lane: feature. Gates: specs_present, acceptance_gate_red_first, spec_substantive, test_plan_present, owner_approval.
- Blast: kernel filter. Never auto-merge. No `adw:merge`. No pnputil / Copy-Item onto System32/DriverStore / bcdedit/testsigning / HID-open from this slice. Do not bind DriverStore `magicmousedriver-kmdf-204-scroll.inf_amd64_d15405a7dda3e10e` or System32 unique `ea1f80b4…`.
- Unique SCM `MagicMouseDriver204Scroll` for AddService and LowerFilters. Live name `MagicMouseDriver` is oem16 — hijack is Event 41 / BSOD.
- PATH-A `applewirelessmouse.sys` is BSOD `0xD1` ship-blocker. Refuse SHA `845435CE…` and dest `MagicMouseDriver.sys` / `MagicMouseDriver.inf`. Rollback is oem16 `AD5D244B`, **not** PATH-A.
- HID: `g_HidDescriptor` is 135 bytes (`0x87`); keep X/Y `0x0030`/`0x0031` on `0x12`; add Wheel `0x0038` extra; battery Input `0x90` COL02 percent at byte[2]; never RID `0x02` / Feature `0x47`.
- SDP overlay: find `09 02 06 35 8D 35 8B 08 22 25 87`; memcpy 135 bytes only; missing prefix → no mutation. Do not write `0x35`/`0x36`/`buf[4]`/`0x25`. Do **not** implement `SdpWalkStream` (host or kernel). Fail-closed is no mutation, not `SdpPatchSuccess` skip after rewrite.
- Host tests fail closed: overlay prefix unchanged + HID `0x87`; `0x90` never rewritten; 6→8 refused without `SdpPatchSuccess`/capacity; Wheel only on 8-byte `0x12` after success.
- `specs/gate_4.py` is the ADW executable gate. `validate-package.sh` is the identity gate. Unique INF already present must not green `gate_4.py`. Overlay test `test_sdp_overlay.py` is owned by BUILD.
- `MAGIC-TRAY.md` already unique LowerFilters=`MagicMouseDriver204Scroll`. Do not edit `MAGIC-TRAY.md`.
- Giveaway artifact name: `MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys` after freeze-hash. Not `MagicMouseDriver.sys`.
- Design already in `v2-kmdf-driver/HID-CONTRACT.md` and `SIGN-AND-INSTALL.md`. Authoritative overlay plan: PRD-188 v2.6.0 section "2026-09-01 Same-size SDP overlay (0x50)".
- GitHub PR #4 is the unique-package PR (draft, do not merge). Hardware signed pnputil + pointer/wheel/battery proof still required before `owner_approval`. No load until overlay test is green.
- 0x50 (2026-09-01): `BTHport!SdpWalkStream+57` ← `hidbth!HidBthParseSdpRecord` ← `HidBthInitDevice`. Unique KMDF was loaded. Cause: 108-byte `g_HidDescriptor` + length rewrite. Fix: 135-byte same-size overlay (memcpy only). Native fixture: 351B CachedServices `d0c050cc8c4d` with `25 87`. Mac PacketLogger `.pklg` not in-tree and not required for this 0x50.
