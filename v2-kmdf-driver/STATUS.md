# Status — unique 2.0.4.1 KMDF (PID 0323)

Branch `ai/kmdf-204-unique-pkg-7748` (PR #4, **draft**). This PC is the only lab. Community how-to-test: `COMMUNITY-TESTING.md`. Ship mechanics: `SHIPPING.md`.

## Working (user-confirmed 2026-09-01)

| Item | State |
|------|--------|
| Pointer | Optical X/Y on RID `0x12` |
| Battery | COL02 `HidD_GetInputReport(0x90)` |
| Surface scroll | **2-finger** → HID Wheel + AC Pan |
| 1-finger on glass | Does **not** scroll (`TWO_FINGER` / `down < 2`) |
| Detent | `MM_SCROLL_STEP` **8** (224 produced zero wheel) |
| Overlay | 135-byte memcpy; prefix `09 02 06 35 8D 35 8B 08 22 25 87` |
| ACL | HidBth IN cap 9; scratch to see 23–31 byte `A1 12`; write 8-byte `0x12` back |
| Bind | oem50, SCM `MagicMouseDriver204Scroll`, dest `MagicMouseDriver-kmdf-204-scroll.sys` |
| Loaded SHA | signed `9901390e…` / unsigned freeze `E73EC0A8…` / thumb **16940C0F** |
| oem16 | `AD5D244B` **not** overwritten |
| After bind | `HidD_SetFeature(F1)` → HidBth 4-byte `0x53` |
| Host gates | `specs/gate_4.py`, overlay/hid_acl/bsod/scroll_threshold, `validate-package.sh` |
| This PC policy | testsigning Yes, Secure Boot off, Memory integrity off |

## Incident — 2026-09-08 scroll died after tray "Enabled on this PC" toggle

**Trigger:** Magic Tray (`magic-tray-authority` / `MagicMouseTray/DeviceEnable.cs`) has a per-device
**"Enabled on this PC"** checkbox. Unchecking it, then rechecking it, calls
`DeviceEnable.Apply(pid, enable)`, which writes a temp `.ps1` and runs (elevated):
`pnputil /disable-device <id>` then `/enable-device <id>` against every BTHENUM/HID/USB
registry entry whose device ID contains `PID_0323`/`PID&0323`. User ran this as part of a
Magic Tray test. Result: **2-finger surface scroll stopped.** Pointer kept working.

**Diagnosis (this session, via `mm-queue-submit.sh RUN`):**

1. Wrote an ad-hoc `Get-PnpDevice` probe (should have reused an existing script — did not have one for PnP-status-by-PID; corrected after, see below).
2. All **live** nodes were `Status=OK / CM_PROB_NONE`:
   `BTHENUM\{...1124...}_VID&0001004C_PID&0323\...` (HIDClass, FriendlyName "Apple Magic Mouse (PID 0323) KMDF 2.0.4 scroll"), its `COL01`/`COL02` HID children, service `MagicMouseDriver204Scroll` **Running**, `LowerFilters=MagicMouseDriver204Scroll` on the BTHENUM parent.
   The only `CM_PROB_PHANTOM` entries were stale `VID_05AC` USB nodes (a different, historic connection) — irrelevant, expected to fail `Enable-PnpDevice` (no such device exists), not the bug.
3. `dump-204-diag.ps1` (existing script) on the Diag registry key:
   `LastAclReceived=9`, `LastAclCapacity=9`, `MtEnableStatus=0`, `SdpPatchSuccess=1`.
   **9-byte ACL = compact report only.** The pnputil disable/enable cycle re-enumerated the
   Bluetooth HID connection and dropped it back to non-multitouch mode. Driver, binding, and
   files were never touched — this was a live protocol-state problem, not a corrupted package.

**Fix:** ran the existing `mm-f1-once.ps1` (`HidD_SetFeature([0xF1,0x02,0x01])` on COL01) via
`mm-queue-submit.sh RUN`. Log showed `SetFeature ok=True err=203 len=3` (the `err=203` /
later `Try-F1 : ... UInt32` line is the known PowerShell-uint32 script bug on the second,
harmless retry — ignore it). **User confirmed scroll working again** without any reinstall.

**Files untouched throughout:** unique dest SHA stayed `9901390ECA723517E1C33B92769846584BC0F6B900C694F50A0C3D5597B1A5C9`, oem16 stayed `AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B` (`dump-204-diag.ps1` hash check).

**Standing gap this proves:** anything that re-enumerates the Bluetooth HID device — the
tray's disable/enable toggle, unpair/re-pair, sleep/wake, or a reboot — can silently drop MT
to compact 9-byte reports and kill 2-finger scroll until `mm-f1-once.ps1` runs. There is
**no automatic F1 on reconnect** yet. This is leftover item 4 below, now proven to bite in
practice, not just theory. Recommended real fix: `MagicMouseTray` should call the F1
SetFeature itself right after `DeviceEnable.Apply(pid, true)` succeeds, and again on any
detected reconnect/wake — not leave it to a manual script.

**Tooling correction:** during triage this session wrote two throwaway diagnostic scripts
(`mm-recover-0323.ps1`, `mm-diag-quick.ps1`) instead of reusing `dump-204-diag.ps1`, which
already reads the Diag key. Both were deleted from the queue after the duplication was
caught. Rule going forward: **check `/mnt/c/mm-dev-queue/*.ps1` for an existing script before
writing a new one.**

## Why the kernel doesn't already auto-send F1 (2026-09-08 analysis)

`Driver.c:762-834` (`MmSendMtEnable`) already tries, automatically, every bind: a 1-second
periodic timer (`Driver.c:139,714,848`, 3 retries) attempts to send the F1 enable itself.
Two independent reasons it doesn't help here:

1. It only fires if `ctx->MtControlHandle` was snooped from a `BRB_L2CA_OPEN_CHANNEL` passing
   through the filter (`Driver.c:529-533`). This reconnect (tray disable/enable) apparently
   didn't produce that BRB where the filter could see it — handle stayed `NULL`, so
   `MmSendMtEnable` early-returned every time (`Driver.c:784-787`). Diag showed
   `MtEnableStatus=0` (untouched default), not the usual `0xC0000206` — proof it never even
   attempted, not that it attempted and failed.
2. Even with a handle, the current code forges a raw **66-byte** `BRB_L2CA_ACL_TRANSFER`
   (`MM_MT_OUT_LEN`, `Driver.c:726,814`) straight to the Bluetooth stack. Per
   `CHECKPOINT-2026-09-01-SCROLL.md:177,152` this **always** returns `0xC0000206` — "ignore"
   is the existing, deliberate stance. The working path (`HidD_SetFeature` from userspace)
   is 4 bytes, but that number alone isn't the fix: it works because it goes through
   HidBth's own SET_REPORT-to-wire translation (hidclass → HidBth → real L2CAP framing).
   Our filter sits **below** HidBth (`LowerFilters` on the BTHENUM PDO) — it can only forge
   raw ACL transfers to the Bluetooth transport by hand, it cannot ask HidBth to do the
   translation for it. No buffer size we pick from this position reproduces HidBth's actual
   wire format; every size has failed with the same status.
   **Real fix direction:** don't forge ACL frames. From kernel, open a handle to the sibling
   COL01 HID PDO (created by HidBth, same physical device) and issue a real
   `IOCTL_HID_SET_FEATURE` down *that* stack — i.e. do in-kernel exactly what `HidD_SetFeature`
   does in userspace, through the normal HID stack, not around it. Needs the COL01 device's
   symbolic link/PDO reachable from our filter's context — unverified whether that's directly
   obtainable from a BTHENUM-level lower filter; needs real investigation, not a guess flashed
   onto the only mouse unattended.

## Overnight task — 2026-09-08 night (user asleep, PC unattended)

User asked for the F1-automation + investigation to be built and tested overnight. Hard
constraint: **no physical two-finger touch is possible unattended**, so "tested" for anything
touch-dependent means register-state proxies (`SdpPatchSuccess`, `MtEnableStatus`,
`LastAclReceived` pattern), not a real scroll confirmation. Safety order, safest first:

1. **Userspace auto-F1 watcher** — no kernel change, no `.sys` reinstall, cannot brick
   anything. Bind to PID 0323 arrival (`RegisterDeviceNotification`/`WM_DEVICECHANGE` or a
   Scheduled Task on Bluetooth device arrival), call the same `HidD_SetFeature([F1,02,01])`
   `mm-f1-once.ps1` already uses. Deploy and test tonight: repeat the tray's
   disable/enable pnputil cycle N times, confirm diag returns to healthy state automatically
   with **no** manual script run.
2. **`MmSendMtEnable` kernel fix** — investigate the COL01-handle approach above. Build, run
   `specs/gate_4.py` + `v2-kmdf-driver/tests/validate-package.sh`, sign, freeze artifact.
   **Do not `pnputil add-driver` this onto the live PC unless**, after install,
   `Get-PnpDevice` shows COL01/COL02 `CM_PROB_NONE` and the service `Running` within 30s —
   if not, immediately restore `C:\mm-dev-queue\kmdf-204-sign\` (known-good `9901390e…`,
   thumb `16940C0F`) via `kmdf-204-pnputil-once.ps1` before ending the task. If genuinely
   unverified, leave the current known-good driver running and hand off the built artifact
   for a human-supervised install/test in the morning instead.
3. **Scroll-speed tuning** (`GestureEngine.c:110-126`, `MM_SCROLL_STEP`) — prepare a reviewed
   diff only. Do not flash overnight: only known data points are 8 (works, fast) and 224
   (zero output); nothing in between has ever touched real hardware.
4. Never touch oem16 / `MagicMouseDriver.sys`. Never delete oem16. Report exactly what was
   built vs. installed vs. prepared-only, with diag evidence, in a dated report file.

## Incident — 2026-09-08 morning: 2.0.4.2 kernel fix installed live, broke pointer+scroll

Overnight the kernel `MmHidSetFeatureWorkItemFunc` fix (`Driver.c:1100-1176`, self-issued
`IOCTL_HID_SET_FEATURE` against the sibling COL01 PDO) was built, signed, gate-passed, and
deliberately **not** installed live — the overnight agent judged a new system-wide PnP-arrival
hook too risky to flash unattended. Correct call. It was installed live anyway once the user
was awake, on the reasoning that "awake to supervise" resolved the stated risk. **It did not.**

**What happened:** installed `2.0.4.2` (`DEF00FCC…`, signed thumb `16940C0F…`, this hash does
**not** match the `A65DF289…` the overnight report quotes — undiagnosed doc/build discrepancy,
flag for whoever revisits this). Post-install `Get-PnpDevice`/service checks were **healthy**
(`CM_PROB_NONE`, `Running`) — the 30-second install-time safety net passed. `KernelHidF1FireCount=2`,
`KernelHidF1OpenStatus=0` (`WdfIoTargetOpen` succeeded — the architecture is sound),
`KernelHidF1IoctlStatus=0xC00000B5` (`STATUS_IO_TIMEOUT`) — the self-issued `IOCTL_HID_SET_FEATURE`
itself hung. **User then reported pointer and scroll both dead.** The install-time PnP check
cannot see this class of failure — exactly the "asynchronous, not just install-time" risk the
overnight report named as the reason it withheld this from unattended install.

**Root cause [INFERENCE, not fully traced]:** `MmHidSetFeatureWorkItemFunc` does not hold
`ctx->Lock` across the blocking `WdfIoTargetSendIoctlSynchronously` call — that part is clean.
But the self-issued `IOCTL_HID_SET_FEATURE` against sibling COL01 has to travel back down
through **this same filter** (`LowerFilters` on the shared BTHENUM parent PDO) to reach the
Bluetooth control channel this filter already tracks single-slot state for (`MtControlHandle`,
Diag bookkeeping). A self-issued second request contending with normal Input-report BRB
traffic on that same channel is the likely reason the request timed out **and** ordinary
pointer/wheel translation stalled until reinstall — this filter isn't built to share that
channel with a concurrent request it originated itself.

**Fix:** immediate rollback via `kmdf-204-pnputil-once.ps1` to the untouched
`C:\mm-dev-queue\kmdf-204-sign\` package — byte-identical `9901390E…`, thumb `16940C0F`,
2.0.4.1. Verified `CM_PROB_NONE`, service `Running`, watcher fired automatically on the
reconnect (`SetFeature ok=True err=203`, `LastAclReceived=23`). **User confirmed pointer and
scroll both work again.**

**Standing decision: do not reinstall `2.0.4.2` / the kernel auto-F1 approach as-is.** It needs
a redesign that doesn't self-contend on a channel this filter already owns state for — e.g.
route the Feature-enable request through the existing `MtControlHandle`/BRB machinery instead
of opening an independent I/O target into the same physical channel — before it goes near the
live PC again. The proven, safe fix for the original reconnect-drops-MT bug remains **Step 1
only**: the userspace `MmAutoF1Watcher` scheduled task, which has now recovered from this exact
failure class (a live reconnect) automatically, every single time it's been tested, with zero
kernel risk.

**Lesson:** "someone is awake" does not substitute for the actual safety gate a risk was named
against. The overnight agent's stated reason for withholding install (async failure surface,
no install-time check can prove it) was correct and should have been treated as a hold, not a
condition to override once a human was present.

## Not in this package

Windows/macOS **gestures** (no PTP). v1 `0x030D` / v2 `0x0269`. PATH-A (`0xD1`).

## Left to do

1. Community **swap-test** (`SHIPPING.md`) — pnputil of self-signed package not run on this PC.
2. **Reboot:** does MT survive without F1?
3. **RESOLVED, do not repeat:** `DriverVer` bump was done for `2.0.4.2` — but see morning incident: that build is parked, not for live use, until the self-contention bug is fixed.
4. **Tray/reconnect F1 — SOLVED for now.** `MmAutoF1Watcher` scheduled task (userspace, `v2-kmdf-driver/scripts/mm-auto-f1-watcher*.ps1`) auto-recovers MT on any PID_0323 reconnect, proven 2026-09-08 (3/3 overnight cycles + this morning's rollback reconnect). The in-kernel version (`MmHidSetFeatureWorkItemFunc`) is **parked** — self-contends with this filter's own BRB channel state, broke pointer+scroll live. Do not reinstall until redesigned to route through the existing `MtControlHandle` instead of an independent I/O target. `MagicMouseTray/DeviceEnable.cs` calling F1 directly is now optional belt-and-suspenders, not required.
5. Virtual PTP (gestures) — new spec, not this overlay.
6. EV + Partner Center if Secure Boot “just works” is the goal.
7. Keep PR #4 draft until swap-test. Do not merge PR #3.
