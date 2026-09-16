# Community testing — Magic Mouse v3 (PID 0323) two-finger scroll, 2.0.4.3

Help wanted. This is a **self-signed kernel filter driver**, not WHQL, and it has only ever run on
the developer's own PC. No second machine has tried it yet — that is exactly what this page is
asking for.

You do **not** need the Windows Driver Kit, Visual Studio, a compiler, or a paid certificate. The
download contains the driver binary **unsigned**; a wizard signs it on your PC with a certificate
your PC creates. That is also why Windows Test Mode is unavoidable here — see
[Why Test Mode](#why-test-mode).

---

## 1. Can you run this?

You need **all** of:

- Windows 10 or 11, **64-bit** (build 14393 / 1607 or newer)
- An **Apple Magic Mouse with Bluetooth PID `0323`** — the 2024 / USB-C model.
  Device Manager → the mouse → Details → Hardware Ids → must contain `PID&0323`.
  v1 (`030D`) and v2 (`0269` / `0310`) are not supported and the driver will not bind to them.
- An Administrator account
- **Secure Boot OFF** (firmware / BIOS setup)
- **Memory integrity OFF** (Windows Security → Device security → Core isolation)
- Willingness to run with **Test Mode on** and to reboot once during setup

If Secure Boot has to stay on — work laptop, corporate policy — stop here. Windows will not load
this driver. That is a Windows rule, not a bug in the package. Also skip this if BitLocker is on and
you do not have the recovery key to hand.

## 2. Install

1. Download the release ZIP, `magic-mouse-v3-scroll-community-2.0.4.3.zip`.
2. **Extract the whole ZIP** to a normal folder (Downloads is fine). Running things straight out of
   the ZIP viewer does not work.
3. **Double-click `Setup-Community.cmd`.**

That is the entire procedure. Do not open PowerShell, do not right-click anything, do not change an
execution policy — the file asks for Administrator itself and everything after that is automatic.

**There is one reboot in the middle.** The wizard turns Test Mode on, tells you to restart, and
stops with exit code `10`. After the restart, **double-click `Setup-Community.cmd` again**; it reads
its own state file and carries on from where it stopped.

`README-FIRST.txt` inside the ZIP says the same thing in plain text for people who never see this
page.

### The seven phases

| # | Phase | What it does |
|---|-------|--------------|
| 1 | `Preflight` | Windows build ≥ 14393, x64, Administrator, a `PID 0323` Magic Mouse paired, all files present, and the `.sys` matching its expected SHA256. Notes whether Fast Startup is on. |
| 2 | `Certificate` | Creates a code-signing certificate **on this PC**, puts it in Trusted Publishers and Trusted Root, records its thumbprint in the state file. |
| 3 | `TestSigning` | `bcdedit /set testsigning on`. **Reboot required** — the wizard exits `10` here and resumes itself on the next run. |
| 4 | `SignPackage` | Builds the driver catalogue and signs `.sys` + `.cat` with the certificate from phase 2. |
| 5 | `InstallDriver` | `pnputil /add-driver … /install`, then restarts the mouse device instance so it picks the filter up. |
| 6 | `EnableTouch` | Sends the multitouch-enable Feature report and installs the `MmAutoF1Watcher` scheduled task, so scroll survives reconnects and reboots. |
| 7 | `Verify` | Checks the service, the driver package, PnP status and the driver's own `Diag` counters, then prints PASS or FAIL. |

Progress lives in `C:\ProgramData\MagicMouseDriver\community-setup-state.json`
(`phase` = the last phase that **completed**) with a detailed log in `install.log` beside it.
Setup stages and signs in `C:\ProgramData\MagicMouseDriver\package` — it never writes into the
folder you extracted the ZIP to, so your download stays byte-for-byte what `SHA256SUMS.txt`
describes and you can always re-run it from a clean copy.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Success / this phase finished |
| `10` | Reboot required — restart, then run `Setup-Community.cmd` again |
| `20` | Preflight failed — something has to be fixed first (see [Troubleshooting](#4-troubleshooting)) |
| `30` | You declined (includes dismissing the UAC prompt) — nothing changed |
| `40` | Hard error — please report it with the log |

`Setup-Community.cmd` translates all of these into plain English on screen and pauses, so a
double-click user never has to know the numbers.

### Switches, if you want them

Not needed for a normal install — double-clicking passes none of these.

| Switch | Effect |
|--------|--------|
| `-DryRun` | Say what would happen and change nothing. No Administrator rights needed, so no UAC prompt. |
| `-Status` | Print the phase reached so far from the state file and stop. No UAC prompt. |
| `-Yes` | Answer the confirmations up front instead of being asked. |
| `-Phase <1-7>` | Run one phase only, by the numbers in the table above. |
| `-NoElevate` | Do not self-elevate; fail instead if not already Administrator. |

They work either way round: `Setup-Community.cmd -Status` or
`powershell -ExecutionPolicy Bypass -File Setup-Community.ps1 -Status`. The `.cmd` passes
everything straight through and only skips the UAC prompt for the read-only switches.

## 3. What to test, and what we need back

On the 2024 / USB-C Magic Mouse (`PID 0323`) only:

| You do | Expected |
|--------|----------|
| Move the mouse on the desk | Pointer moves |
| **Two** fingers swipe on the glass | Vertical scroll, and horizontal pan sideways |
| **One** finger resting or dragging on the glass | **No** scroll at all |
| Battery | Readable in Device Manager |
| Turn the mouse off and on again, then retest | Scroll still works, no manual step |
| Restart Windows, then retest | Scroll still works, no manual step |

**Not expected, do not report as bugs:** Mission Control, swipe between desktops, pinch to zoom,
Precision Touchpad gestures, and anything at all on Magic Mouse v1/v2.

Please report **either** outcome — "it worked" is as useful as a failure, because right now the
sample size is one PC:

<https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix/issues>

Include:

- Windows version (`winver`) and PC model
- Secure Boot and Memory integrity: were they off?
- Did the Test Mode watermark appear after the reboot?
- The phase it reached and the exit code it printed
- `PID` from Hardware Ids, and whether another Apple mouse driver was already installed
- The last ~30 lines of `C:\ProgramData\MagicMouseDriver\install.log`

If scroll misbehaves — one finger scrolls, or two fingers never scroll — also send the driver's own
counters, from an Administrator PowerShell, **while two fingers are on the glass**:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Diag' |
  Select-Object SdpPatchSuccess, LastAclReceived, LastAclCapacity, Rid12Count,
                LastOutHdr, LastOutBufferSize, MtEnableStatus, ScrollStep
```

| Field | Healthy | Broken |
|-------|---------|--------|
| `SdpPatchSuccess` | 1 | 0 = descriptor overlay missed |
| `LastAclReceived` | 23–31 | 9 = compact report, multitouch is off |
| `LastOutHdr` | 83 (`0x53`) after the multitouch enable | 65 = GET_REPORT only |
| `MtEnableStatus` | 0 with 23–31 byte ACLs | 0 with 9-byte ACLs = enable never landed |

### Scroll too sensitive, or too sluggish?

Tunable with no rebuild, no re-sign and no reinstall. `ScrollStep` is how far (in touch units) you
drag per scroll notch, so **higher = less sensitive**. Default `8`, valid `1`–`224`, out-of-range
values fall back to the default.

```powershell
# Administrator PowerShell, from the extracted folder
scripts\mm-scroll-tune.ps1 -ScrollStep 16
```

It writes the value, restarts the `0323` device, re-sends the multitouch enable and then prints what
the driver actually loaded (`driver_ScrollStep`), so you can tell a real change from a silent no-op.
Reference points from the original hardware: `8` is the proven default; `224` (the Linux
`hid-magicmouse` default) produced **zero** wheel movement. Move in small steps.

## 4. Troubleshooting

### Test Mode did not stick

The most common failure by a wide margin. Symptoms: `bcdedit /set testsigning on` appeared to
succeed, you rebooted, there is **no** "Test Mode" watermark in the bottom-right of the desktop, and
the driver refuses to load.

**Secure Boot is still on.** Windows silently ignores test signing while Secure Boot is enabled.
Check it:

```powershell
Confirm-SecureBootUEFI        # $false is what you need; $true means it is still on
bcdedit /enum {current}       # look for: testsigning  Yes
```

Turn Secure Boot off in your firmware setup screen (usually F2 / F10 / Del at power-on, under Boot
or Security), reboot, and run `Setup-Community.cmd` again. Memory integrity — Windows Security →
Device security → Core isolation — blocks self-signed kernel drivers the same way and also has to be
off.

### "Windows cannot verify the digital signature" / the device shows a yellow warning

Test Mode is not active, or the certificate the wizard made is not trusted. Re-run
`Setup-Community.cmd`: phase 2 re-imports the certificate and phase 7 reports which check failed.
If the state file lists a `certThumbprint` that no longer exists in `certlm.msc` — for instance you
cleaned out certificates by hand — delete
`C:\ProgramData\MagicMouseDriver\community-setup-state.json` and run setup again from the start.

### Nothing happens when I double-click Setup-Community.cmd

You are running it from inside the ZIP viewer, or you copied out only that one file. Extract the
whole archive to a real folder first. If a UAC prompt appears and you dismiss it, the script exits
`30` and changes nothing.

### The pointer works but two fingers do not scroll

Multitouch dropped back to compact 9-byte reports. Anything that re-enumerates the Bluetooth HID
device can do this: unpair/re-pair, sleep/wake, or a third-party tray app that disables and
re-enables the device. Re-send the enable by hand:

```powershell
scripts\mm-f1-once.ps1
```

If that fixes it, the `MmAutoF1Watcher` scheduled task should have done it for you — please report
it, with `C:\ProgramData\MagicMouseDriver\auto-f1-watcher.log`, because that watcher is meant to
cover exactly this case (it handles device arrival events *and* reconciles state at startup).

### One finger scrolls

Not expected — report it with the `Diag` output above.

### It was working and stopped after a Windows update

A Windows update can reset Test Mode or Memory integrity. Check both, then re-run
`Setup-Community.cmd`.

## 5. Uninstall

Double-click **`Uninstall-KMDF.cmd`**. It removes only this package — the
`MagicMouseDriver-kmdf-204-scroll` driver package and the `MagicMouseDriver204Scroll` service — and
deliberately leaves any older Apple mouse driver on the PC alone. Your pointer keeps working through
Windows' own Bluetooth mouse driver.

It does **not** undo the two system-wide changes, on purpose; those are yours to reverse when you
want:

```powershell
bcdedit /set testsigning off        # Administrator, then reboot
certlm.msc                         # remove the certificate the wizard created from
                                   # Trusted Publishers and Trusted Root
```

## Why Test Mode

Windows only loads a kernel driver whose signature chains to a certificate it already trusts, and
those are only issued to organisations with a commercial EV code-signing certificate. This project
does not have one, and publishing a kernel binary signed with the maintainer's personal key would be
worse, not better — so the ZIP ships the driver **unsigned** and each user signs it locally with a
certificate generated on their own machine. A locally generated signature is only accepted in Test
Mode, which in turn requires Secure Boot and Memory integrity to be off.

The route out is a commercial EV certificate plus Microsoft Partner Center attestation signing,
which would produce a driver that installs with Secure Boot left **on** and no Test Mode. That is
tracked as **issue #23** and has not been done.

## Do not

- Copy any `.sys` into `C:\Windows\System32\drivers` by hand
- Install `applewirelessmouse.sys` from the v1 route (BSOD `0xD1` — ship-blocker)
- Overwrite an existing `MagicMouseDriver.sys` if you already have an older fix installed
- Expect macOS gestures, or v1/v2 support
- Run this on a PC that must keep Secure Boot on

## Verifying the download

`SHA256SUMS.txt` in the ZIP lists every other file in the ZIP. Check any of them with:

```bat
certutil -hashfile MagicMouseDriver-kmdf-204-scroll.sys SHA256
```

The driver should be **25,600 bytes**, SHA256
`08E91E37AF3B7B9A56E793ADB876BA48FBD61DDFEE446C89A6A1751CABABD6AC`, and **unsigned** — right-click →
Properties will have no "Digital Signatures" tab until your own PC signs it during phase 4.

## Maintainers

Build the release ZIP with `scripts\make-community-zip.ps1` (it regenerates `SHA256SUMS.txt`, refuses
to ship maintainer tooling, signing material or a `.cat`, and prints the ZIP's own SHA256).
Pre-signed developer install path: `Install-KMDF.cmd`. Remaining work and history: `STATUS.md`.
Attestation / swap-test plan: `SHIPPING.md`.
