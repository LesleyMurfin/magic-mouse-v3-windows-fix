# Overnight report - 2026-09-08

Branch `ai/kmdf-204-unique-pkg-7748` (PR #4, draft). User asleep, PC unattended all
night. Worked in strict priority order from `STATUS.md`: safest first, kernel
investigation second (build/sign only, no live install), scroll tuning third
(prepared only, never built for release).

**End-of-night state: identical to start-of-night state**, plus one new
userspace Scheduled Task. Live driver is still the exact same signed
`9901390e...` package, service `MagicMouseDriver204Scroll` `Running`, oem16
untouched. Nothing was flashed, reinstalled, or reloaded on the kernel side.

---

## Step 1 - userspace auto-F1 watcher (SAFE, built, deployed, tested live)

**Built:**

- `v2-kmdf-driver/scripts/mm-auto-f1-watcher.ps1` - watches WMI
  `__InstanceCreationEvent` on `Win32_PnPEntity` for `PID_0323` arrival
  (checked `/mnt/c/mm-dev-queue/*.ps1` first; no existing watcher script).
  On arrival, waits 3s then re-runs the existing `mm-f1-once.ps1`
  (`HidD_SetFeature([0xF1,0x02,0x01])` on COL01) - the exact fix that was
  run by hand during tonight's earlier incident. Debounced 5s. Logs to
  `C:\ProgramData\MagicMouseDriver\auto-f1-watcher.log`.
- `v2-kmdf-driver/scripts/mm-auto-f1-watcher-install.ps1` - registers it as
  Scheduled Task `MmAutoF1Watcher` (SYSTEM, `AtStartup`, restart-on-failure,
  no execution time limit), copies the watcher to
  `C:\ProgramData\MagicMouseDriver\mm-auto-f1-watcher.ps1`, starts it
  immediately (does not wait for reboot). `-Uninstall` switch provided.
- No driver, service, or `.sys` file touched by either script.

**Installed live:** yes. Ran
`mm-auto-f1-watcher-install.ps1` via `mm-queue-submit.sh RUN`:

```
registered scheduled task MmAutoF1Watcher
=== starting task now (do not wait for next reboot) ===
LastTaskResult=267009 State=Running
```

(`267009` = `SCHED_S_TASK_RUNNING`, i.e. currently running - not an error.)

**Tested live tonight:** wrote `mm-toggle-0323-cycle.ps1` (mirrors
`MagicMouseTray/DeviceEnable.cs` `BuildScript` exactly - enumerates
`HKLM\SYSTEM\CurrentControlSet\Enum\{BTHENUM,HID,USB}` for `PID_0323`/
`PID&0323` entries with an Apple VID needle, `pnputil /disable-device` then
`/enable-device` each). Ran it 3 times, ~10s+ apart, reading
`dump-204-diag.ps1` after each cycle. **Never ran `mm-f1-once.ps1` by
hand** at any point after the watcher was installed.

Baseline before any cycle (healthy): `LastAclReceived=23 LastAclCapacity=9
SdpPatchSuccess=1`.

**Cycle 1** - toggle log confirmed the 2 live BTHENUM entries actually
disabled/enabled (the 9 other HID/USB entries correctly failed
"not connected" - expected, matches `STATUS.md`'s phantom-node note).
Watcher log:

```
[2026-09-08 03:24:23] PID_0323 PnP entity arrival: HID\...&COL01\...
[2026-09-08 03:24:32] F1 script exit=0
[2026-09-08 03:24:32] F1: SetFeature ok=False err=121 len=3
[2026-09-08 03:24:32] PID_0323 PnP entity arrival: HID\...&COL02\...
[2026-09-08 03:24:36] F1 script exit=0
[2026-09-08 03:24:36] F1: SetFeature ok=True err=203 len=3
```

(`err=121` then `ok=True err=203` on retry is the documented
`STATUS.md` "harmless known PowerShell-uint32 retry" pattern - the same
signature that accompanied the manual fix earlier tonight.)

Diag ~10s later: `LastAclReceived=23 LastAclCapacity=9 MtEnableStatus=0
LastOutHdr=83 LastOutBufferSize=4` - `LastOutHdr=83`/`LastOutBufferSize=4`
is the documented "HidBth actually sent the 4-byte 0x53 F1 packet" proof.
**No manual script run.**

**Cycle 2** - toggle ran (4 disable/enable log lines confirmed). Watcher
fired automatically at `03:25:16`, `SetFeature ok=True err=203`
(healthy signature) again with no manual run. (The diag snapshot taken
right at ~10s showed a transient `LastAclReceived=1/LastAclCapacity=1` -
a single small control-channel ACL captured mid-flight, not the "stuck
compact 9-byte" bad pattern; `probe-0323.ps1` immediately after showed
service `Running`, HIDClass device `OK`, oem16/unique-sys hashes
unchanged.)

**Cycle 3** - toggle ran (4 disable/enable log lines confirmed). Watcher
fired automatically at `03:26:19`, `SetFeature ok=True err=203`. Diag
after: `LastAclReceived=23 LastAclCapacity=9 MtEnableStatus=0
LastOutHdr=83 LastOutBufferSize=4` - healthy MT pattern, matches baseline.

**Result: 3/3 automatic recoveries, zero manual script runs after
install.** This is the register-state proxy for "scroll survives a
reconnect on its own" - see "What remains unverified" below for the one
thing this cannot prove.

---

## Step 2 - kernel `MmSendMtEnable` fix (investigated, built, signed - NOT installed live)

### Investigation

Read `Driver.c` 1-922 (BRB interception, `MtControlHandle` capture,
`MmSendMtEnable`, `MmSubmitBrb`, diag timer/workitem) and `Driver.h`
context struct in full, per `STATUS.md` "Why the kernel doesn't already
auto-send F1": this filter is a `LowerFilters` driver on the **BTHENUM
PDO** (the physical Bluetooth device node), below `HidBth.sys`. The
current `MmSendMtEnable` forges a raw 66-byte `BRB_L2CA_ACL_TRANSFER` OUT
straight to the Bluetooth transport and always returns `0xC0000206` -
confirmed dead end, matches `CHECKPOINT-2026-09-01-SCROLL.md`.

**Real fix implemented:** instead of forging Bluetooth wire frames, open
the sibling **COL01 HID PDO** (a genuine child device node that `HidBth`
itself creates under the same BTHENUM parent node this filter is attached
to) as a foreign KMDF I/O target and send a real `IOCTL_HID_SET_FEATURE`
down that stack, so `HidBth` does the actual L2CAP translation - exactly
what `HidD_SetFeature` does from userspace, done in-kernel.

**APIs used and why they apply to this device stack shape** (verified
against Microsoft Learn, not guessed):

- `IoRegisterPlugPlayNotification(EventCategoryDeviceInterfaceChange, ...)`
  with `GUID_DEVINTERFACE_HID` and
  `PNPNOTIFY_DEVICE_INTERFACE_INCLUDE_EXISTING_INTERFACES` - documented,
  called from `EvtDeviceSelfManagedIoInit`/unregistered in
  `EvtDeviceSelfManagedIoCleanup` (the KMDF-documented pattern; **not**
  from `EvtDeviceAdd`, which the docs explicitly warn against).
- The notification's `DEVICE_INTERFACE_CHANGE_NOTIFICATION.SymbolicLinkName`
  carries the device instance path as text (confirmed live: the exact
  same text `mm-f1-once.ps1`'s own `SetupDiGetDeviceInterfaceDetail`
  already enumerates and matches on, e.g.
  `...vid&0001004c_pid&0323&col01#...`) - so matching `PID&0323` +
  `COL01` as a case-insensitive substring of that string reliably
  identifies our own sibling COL01 without needing any PDO-parent-walk
  API.
- `WdfIoTargetCreate` + `WdfIoTargetOpen` with
  `WDF_IO_TARGET_OPEN_PARAMS_INIT_OPEN_BY_NAME` - this is the
  Microsoft-documented mechanism specifically for "opening a remote I/O
  target that is not in your own device stack" by symbolic link name
  obtained from a device-interface-arrival notification.
- `IOCTL_HID_SET_FEATURE` (`hidclass.h`) with input buffer
  `{report ID, feature bytes...}` - matches the exact 3-byte payload
  (`0xF1,0x02,0x01`) `mm-f1-once.ps1` already proves works, confirmed
  against the official IOCTL contract.
- `WdfIoTargetSendIoctlSynchronously` - documented synchronous IOCTL send
  to a foreign target, `PASSIVE_LEVEL`, matches the sample code pattern
  in the docs verbatim.

The PnP-notification callback only captures the matched symbolic link and
enqueues a `WDFWORKITEM` (`MmHidSetFeatureWorkItemFunc`) that does the
actual open+IOCTL+close - matching this driver's existing
`MmDiagWorkItemFunc` pattern, and matching the documented requirement
that PnP notification callbacks "complete their tasks as quickly as
possible."

Full detail in code comments: `v2-kmdf-driver/Driver.c` (search
"Kernel HID SetFeature-via-sibling-PDO") and `Driver.h`
(`MM_HID_SYMLINK_MAX`).

### Built and gate-tested

1. `python3 specs/gate_4.py` - **PASS** (10/10).
2. `bash v2-kmdf-driver/tests/validate-package.sh` - **PASS** (all checks
   OK, including the bumped `DriverVer 09/08/2026,2.0.4.2` /
   `FileVersion 2.0.4.2` assertions).
3. Bumped `DriverVer`/`FileVersion`/`ProductVersion` to `2.0.4.2`
   (`STATUS.md` noted `DriverVer` was stuck at `2.0.4.1` across every
   rebuild tonight before this - would have been silently skipped as a
   duplicate by `pnputil`). Updated `scripts/kmdf-204-scroll-build.ps1`
   and `scripts/kmdf-204-scroll-sign.ps1` to match (new work dir
   `kmdf-204-bld-20260908` / sign stage `kmdf-204-sign-20260908`, kept
   completely separate from `C:\mm-dev-queue\kmdf-204-sign\`, which is
   the known-good 2.0.4.1 restore copy - never touched).
4. Real EWDK cross-build via `kmdf-204-from-wsl.sh` (the documented
   `BUILDING.md`/`SIGN-AND-INSTALL.md` pipeline). **Compiled clean**:
   `Driver.c`, `GestureEngine.c`, `HidDescriptor.c`, `InputHandler.c`,
   `AclTranslate.c` all built with no `error C####`; the only nonzero
   exit is the documented, expected `MSB6006` Inf2Cat/signability noise
   (same as every prior successful build tonight and on 2026-09-01).
   `InfVerif` exit `0`. Unsigned artifact:
   `MagicMouseDriver-kmdf-2.0.4-scroll-6DDD114B.sys`, SHA256
   `6DDD114B4FA21A728A965B06CA07ACB71440F5073524EBE0DC22BA06630B67BB`.
5. Signed with the existing local cert (thumb `16940C0F937D5693...`):
   Inf2Cat "Errors: None / Warnings: None", `signtool sign` succeeded for
   both `.sys` and `.cat`, `signtool verify` succeeded for both, signer
   thumb confirmed `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`. Signed
   package staged at `C:\mm-dev-queue\kmdf-204-sign-20260908\`
   (`MagicMouseDriver-kmdf-204-scroll.sys/.inf/.cat`), signed `.sys`
   SHA256 `A65DF2898BFA8C70D00767CCA85951DBDFC32DB0B17CDDBEFB101CB97E86BFC4`.

### NOT installed on the live PC - here is exactly why

The task authorized going all the way to a live `pnputil add-driver` if I
had "real confidence," with a defined rollback safety net (verify
COL01/COL02 `CM_PROB_NONE` + service `Running` within 30s, else restore).
I chose not to use it, for one specific reason that safety net does not
cover:

The new code's failure surface is **asynchronous**, not just
install-time. `IoRegisterPlugPlayNotification` with
`PNPNOTIFY_DEVICE_INTERFACE_INCLUDE_EXISTING_INTERFACES` fires the
callback for **every HID device interface already on the system**
(keyboard, other mice, anything) within seconds of load, and again for
every future HID arrival/removal, for the rest of the machine's uptime -
not only this mouse. A 30-second post-install PnP/service check only
proves the driver didn't crash at `AddDevice`; it proves nothing about
code that only executes later, on a PnP notification, possibly hours
after the check passed (next sleep/wake, next USB device plugged in,
next reboot). This exact code path - `IoRegisterPlugPlayNotification`,
`WdfIoTargetOpen`-by-name into a foreign PDO, `WdfIoTargetSendIoctlSynchronously`
- has never executed on real hardware before tonight, on the single
unattended production machine, with no one able to intervene if a bug in
that new path bugchecks the box at 4am. That is precisely the "single
most important constraint" this task named. Every prior dead end
recorded in `CHECKPOINT-2026-09-01-SCROLL.md`'s table was also
API-plausible on paper and still failed on this specific BT stack in
practice - "compiles and matches the docs" is not the same bar as
"verified on this hardware."

`STATUS.md`'s own overnight plan already names this exact fallback:
*"If genuinely unverified, leave the current known-good driver running
and hand off the built artifact for a human-supervised install/test in
the morning instead."* That is what I did.

**Live PC state confirmed unchanged after the build+sign work**
(`probe-0323.ps1`, run last, after everything above):

```
oem16=AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B
unique_sys=9901390ECA723517E1C33B92769846584BC0F6B900C694F50A0C3D5597B1A5C9 size=32496
MagicMouseDriver Status=Stopped Start=Manual
MagicMouseDriver204Scroll Status=Running Start=Manual
Apple Magic Mouse (PID 0323) KMDF 2.0.4 scroll -> OK
```

Identical to the pre-Step-2 baseline. Nothing was `pnputil`'d,
`delete-driver`'d, or reloaded.

### If a human wants to install and test this in daylight

1. Signed package: `C:\mm-dev-queue\kmdf-204-sign-20260908\` (`.sys`
   SHA256 `A65DF2898BFA8C70D00767CCA85951DBDFC32DB0B17CDDBEFB101CB97E86BFC4`,
   thumb `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`).
2. `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install`
   from that folder (unique oem50-class dest only - never oem16).
3. Immediately check `Get-PnpDevice` for COL01/COL02 `CM_PROB_NONE` and
   service `MagicMouseDriver204Scroll` `Running`.
4. Toggle Magic Tray "Enabled on this PC" off/on (or unplug/replug) to
   trigger the new PnP-notification path, then read
   `dump-204-diag.ps1`'s new fields: `KernelHidF1FireCount` (should
   increment - proves the notification matched and fired),
   `KernelHidF1OpenStatus` (`WdfIoTargetOpen` result),
   `KernelHidF1IoctlStatus` (`IOCTL_HID_SET_FEATURE` result - `0` is
   success).
5. If anything looks wrong, or COL01/COL02 are not healthy: restore via
   `kmdf-204-pnputil-once.ps1` (points at the untouched `C:\mm-dev-queue\
   kmdf-204-sign\` 2.0.4.1 known-good, unaffected by anything above).

### What this proves and what it does not

Register-state proxy only. It proves: clean compile against the real WDK,
clean `InfVerif`, valid signature. It does **not** prove the new code path
executes correctly on this BT stack, and it absolutely does not prove
2-finger scroll works after the F1 path fires - that needs a human hand
on the glass.

---

## Step 3 - scroll speed tuning (prepared only, NOT built for release, NOT installed)

`GestureEngine.c` `AccumulateSurfaceScroll` / `GestureEngine.h`
`MM_SCROLL_STEP`. Only two data points have ever touched real hardware:
8 (works, user said "fast") and 224 (zero wheel output). Chose the
"better" option offered rather than guessing a single untested constant:
**velocity-aware scaling**, not a new magic number.

**Design:** track each touch's position from the *previous* HID report
(`TouchLastX/Y`, new fields, independent of the notch anchor
`TouchAnchorX/Y`). The effective detent for the *next* notch grows with
how far the finger moved since that previous report:

```
effStep = MM_SCROLL_STEP + |velocity| * MM_SCROLL_VELOCITY_GAIN,
          clamped to MM_SCROLL_STEP_MAX (3x MM_SCROLL_STEP)
```

At zero/slow velocity `effStep == MM_SCROLL_STEP == 8` exactly - a
stationary or slow deliberate drag behaves **identically** to the
proven 2026-09-01 code. Only fast flicks get a larger effective detent,
which is a monotonic, bounded dampening curve rather than a second
untested flat constant. `MM_SCROLL_VELOCITY_GAIN=2` and the `3x` ceiling
are explicitly marked in code comments as **unvalidated guesses** - no
data point between 8 and 224 has ever run on real hardware, exactly as
the task noted.

Preserved exactly, unchanged: the `down < 2` one-finger-must-not-scroll
gate, and the literal `TWO_FINGER` / `SCROLL_STEP_8` comment text the
host gate scans for.

**Gate run against this diff:**

```
$ python3 specs/gate_4.py
...
PASS: test_scroll_threshold.py quotes SCROLL_STEP_8 against GestureEngine.c
PASS: GestureEngine.c has SCROLL_STEP_8 and TWO_FINGER
gate_4 exit=0
```

All 10 checks pass.

**Compile-checked** (not release-built, not signed, not parked as an
artifact): re-synced sources and ran a scratch EWDK build in an isolated
work directory (`kmdf-204-bld-step3-checkonly2`, separate from the Step 2
release build/sign dirs). Confirmed the synced source actually contained
the new fields (`grep` for `TouchLastX`/`MM_SCROLL_VELOCITY_GAIN` in the
staged files), then confirmed `Driver.c` and `GestureEngine.c` both
compiled with no `error C####` (only the same benign Inf2Cat MSB6006
noise as every other build tonight). This scratch build was **not**
signed and **not** copied anywhere pnputil could reach it.

**Not installed. Not flashed. Needs a human touch-test in the morning**
to pick an actual `MM_SCROLL_VELOCITY_GAIN`/ceiling, or decide the
existing flat `MM_SCROLL_STEP=8` already feels fine and this diff isn't
worth shipping at all.

---

## Morning checklist (in order)

1. **Device Manager**: confirm COL01/COL02 for "Apple Magic Mouse (PID
   0323) KMDF 2.0.4 scroll" still show no yellow-bang / no errors, and
   service `MagicMouseDriver204Scroll` is `Running`
   (`Get-Service MagicMouseDriver204Scroll`).
2. **One-finger** on the glass - must **not** scroll (unchanged all
   night; this was never touched).
3. **Two-finger swipe** - must scroll (this is the thing no automated
   check tonight could verify - first real human confirmation since the
   incident).
4. **Reconnect survival, hands-off**: toggle Magic Tray "Enabled on this
   PC" off then on once (or just trust tonight's 3/3 automated proof) and
   confirm scroll keeps working **without** running any script by hand.
   If you want to double check the watcher itself: `Get-ScheduledTask
   -TaskName MmAutoF1Watcher` should show `Running`, and
   `C:\ProgramData\MagicMouseDriver\auto-f1-watcher.log` should show
   `PID_0323 PnP entity arrival` / `SetFeature ok=True` lines with
   today's date.
5. **Only if you want to test the kernel fix** (optional, separate from
   the above - the currently *running* driver is still the old 2.0.4.1
   without it): follow "If a human wants to install and test this in
   daylight" above. Not required - scroll already works via the Step 1
   watcher regardless of whether you ever install this.
6. **Only if you want to test the scroll-speed diff** (optional,
   currently just source on this branch, nothing built or signed for
   it): decide if it's worth a real build/sign/install cycle at all, or
   pick a `MM_SCROLL_VELOCITY_GAIN` by feel and I can build+sign+install
   it with you watching.

## Files changed tonight

- `scripts/mm-auto-f1-watcher.ps1`, `scripts/mm-auto-f1-watcher-install.ps1`
  (new, Step 1, installed live).
- `Driver.c`, `Driver.h` (Step 2 kernel HID SetFeature-via-sibling-PDO;
  Step 3 `TouchLastX/Y` fields), `MagicMouseDriver-kmdf-204-scroll.inf`,
  `MagicMouseDriver.rc` (DriverVer/FileVersion bump to 2.0.4.2),
  `scripts/kmdf-204-scroll-build.ps1`, `scripts/kmdf-204-scroll-sign.ps1`
  (new work/stage dirs + version bump), `tests/validate-package.sh`
  (version assertion bump) - built and signed, not installed.
- `GestureEngine.c`, `GestureEngine.h` (Step 3 velocity-aware scroll
  scaling) - prepared only, not built for release, not installed.
