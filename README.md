# Magic Mouse 2024 (v3) Windows Driver — Scroll Fix for PID 0323

A free, MIT-licensed **Magic Mouse v3 Windows driver** for the USB-C **Apple Magic Mouse 2024** (Bluetooth **PID 0323**) on **Windows 10/11**. Apple ships no Windows driver for PID `0x0323` and its Boot Camp INF has no `0323` entry, so two-finger scroll dies after a Bluetooth idle disconnect while the cursor keeps working. This project restores and protects scroll by keeping the HID collection stack from collapsing. Not v1 (`030D`) or v2 (`0269`).

**Read the guides:**
[Magic Mouse v3 Windows driver site](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/) ·
[Install the driver on Windows 11](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/install.html) ·
[Fix Magic Mouse scroll not working](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/scroll-fix.html) ·
[Magic Mouse battery percentage on Windows](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/battery.html) ·
[Magic Mouse v3 driver FAQ](https://lesleymurfin.github.io/magic-mouse-v3-windows-fix/faq.html)

**Start with Magic Tray:** [Magic Tray (Windows app)](https://github.com/LesleyMurfin/magic-tray) — a Windows system-tray utility (software, not a physical desk tray) that **detects which of the three driver states you are on** (Apple/Microsoft default, patched Apple driver, or KMDF), tells you whether pointer, scroll and battery are working, and reports battery in each. Site: [Magic Tray (Windows app) home](https://magictray.app/).

**This repo ships TWO separate, working drivers** — the patched Apple driver and the KMDF driver. Different drivers, built different ways, different tradeoffs: pick one, do not install both. See [Which driver](#which-driver-three-states-two-fixes) below.

If this helped, **star this repo** and **[Magic Tray](https://github.com/LesleyMurfin/magic-tray)**. Signing goal (Stripe, not GitHub Sponsors): [funding](https://magictray.app/funding.html).

## Contents

- [Which driver — three states, two fixes](#which-driver-three-states-two-fixes)
- [What you actually get: scroll and battery](#what-you-actually-get-scroll-and-battery)
- [Magic Tray works with all three states](#magic-tray-works-with-all-three-states)
- [Driver 1 — Apple driver, registry-bound](#driver-1--apple-driver-registry-bound-applewirelessmousesys)
- [Driver 2 — KMDF driver](#driver-2--kmdf-driver-magicmousedriver-kmdf-204-scrollsys)
- [What this fixes](#what-this-fixes)
- [Supported hardware](#supported-hardware)
- [Quick install](#quick-install-3-steps)
- [How it works](#how-it-works)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [License](#license)

## Which driver? Three states, two fixes

Your mouse is always in **one of three driver states**. Two of them are fixes shipped here, and
they are **independent** — separate binaries, separate installers, separate documentation. Install
**one**, not both: they attach to the same Bluetooth HID stack.

| | **State 0 — Apple/Microsoft default** | **Driver 1 — Apple driver, registry-bound** | **Driver 2 — KMDF driver** |
|---|---|---|---|
| What it is | What Windows gives you with no fix installed | Apple's **own, unmodified** `applewirelessmouse.sys` from Boot Camp, bound to the mouse by registry | `MagicMouseDriver-kmdf-204-scroll.sys`, written from scratch |
| Folder | — | [`v1-binary-patch/`](v1-binary-patch/) | [`v2-kmdf-driver/`](v2-kmdf-driver/) |
| Pointer | Works | Works | Works |
| Two-finger scroll | **Missing / dies** — Windows has no multi-touch filter for this mouse | Apple's filter translates the multi-touch surface into scroll | Generated directly from the touch surface (Wheel + AC Pan) |
| Scroll sensitivity | n/a | Apple's behaviour (Mac-style direction) | Tunable, no reinstall (`ScrollStep`) |
| Battery in Magic Tray | Reported as-is | Read via a temporary **Mode A ⇄ Mode B flip**, then flipped back | Read directly from HID Input `0x90` on COL02 |
| Install | Nothing to do | Copy `.sys`, create service, add `LowerFilters`, restart device | Self-sign script, then `pnputil` the driver package |
| Build needed | — | No — Apple's binary, nothing compiled | Source + build scripts included; building needs the EWDK |
| Signing | Microsoft-signed | **Apple-signed, Microsoft WHQL-countersigned — unmodified, so the signature is intact** | A local cert you generate — `Setup-Community.ps1` does it |
| **Windows Test Mode** | Not needed | **Not needed** | **Required** — `Setup-Community.ps1` can enable it for you |
| Secure Boot / memory integrity | Unchanged | **Can stay ON** | Must be off |
| Touches Apple's driver? | — | Uses Apple's driver as-is; no bytes changed | No — Apple's `MagicMouseDriver.sys` is left untouched |
| Survives reconnect / reboot | Scroll does not | Filter persists; re-run if the device InstanceId changes after re-pairing | Yes — re-arms multitouch automatically on both |
| Status | Baseline (the problem) | **Production ready** | **2.0.4.3, live and confirmed on hardware** |

**Why Driver 1 needs no signing:** the fix is *registry work, not a binary patch*. Apple's Boot Camp
INF simply has no entry for this mouse's Bluetooth PID, so the driver is registered manually as a
`LowerFilters` entry on the device instead. The `.sys` itself is byte-for-byte Apple's, so its
Apple + Microsoft WHQL signatures still verify and Windows loads it normally — Secure Boot on,
memory integrity on, no Test Mode watermark. Verified on this machine:
`Get-AuthenticodeSignature` returns **Valid**, signer `CN=Microsoft Windows Hardware Compatibility
Publisher`.

### What you actually get: scroll and battery

These are the two things people care about, so here they are side by side.

| | **State 0 — default** | **Driver 1 — Apple driver** | **Driver 2 — KMDF driver** |
|---|---|---|---|
| **Pointer** | ✅ works | ✅ works | ✅ works |
| **Two-finger scroll** | ❌ none | ✅ Apple's own multi-touch translation | ✅ generated from the touch surface (HID Wheel + AC Pan) |
| Scroll direction / feel | — | Apple's, Mac-style | Windows-style, **sensitivity tunable** via `ScrollStep` |
| One finger resting on glass | — | Apple's behaviour | ✅ deliberately does **not** scroll |
| Scroll after Bluetooth reconnect | ❌ | Filter stays bound | ✅ multitouch re-armed automatically |
| Scroll after reboot | ❌ | Filter stays bound | ✅ multitouch re-armed automatically |
| **Battery %** | Via Magic Tray | Via Magic Tray, using a brief **Mode A ⇄ B flip** | Via Magic Tray, **direct read** of HID Input `0x90` on COL02 |
| Battery needs a mode flip? | — | Yes — momentary | No |

Neither driver puts a battery percentage in Windows itself — Windows has no UI for it on this
mouse. Battery always comes from **Magic Tray**; what changes between the drivers is *how* Magic
Tray has to get it.

### Magic Tray works with all three states

[Magic Tray](https://github.com/LesleyMurfin/magic-tray) ([magictray.app](https://magictray.app/))
is the companion Windows tray app, and it supports **all three states**. It detects which driver
you are currently on — Apple/Microsoft default, Apple driver, or KMDF — and tells you whether
**pointer, scroll and battery** are working in that state. Start there if you are not sure what you
have: you do not need to read registry keys or check signatures yourself.

It adapts how it reads battery to the state you are in:

- **On the Apple driver** the battery report is not directly readable while the stack is in the
  mode that serves scroll, so Magic Tray performs a temporary **Mode A ⇄ Mode B flip**, takes the
  reading, and **flips you back**. Momentary, and you keep scroll.
- **On the KMDF driver** no flip is needed — the driver keeps the multitouch collection alive, so
  battery comes straight from HID Input `0x90` on COL02.
- **On the Apple/Microsoft default** it still reports what the stack exposes, and tells you scroll
  is missing plus which of the two drivers to install.

You do not have to pick a driver to use Magic Tray, and installing either driver does not stop
Magic Tray from working.

### Test Mode: only Driver 2 needs it

Windows will not load a kernel driver unless it carries a signature it trusts. The two drivers sit
on opposite sides of that line:

- **Driver 1 — no Test Mode.** The `.sys` is Apple's own, unmodified, Apple-signed and Microsoft
  WHQL-countersigned. Windows loads it exactly as it would on a Mac running Boot Camp. Secure Boot
  and memory integrity can stay **on**. Nothing is patched, so nothing needs re-signing.
- **Driver 2 — Test Mode required.** It is a new driver that has never been through Microsoft
  signing, so it must be self-signed:

  ```powershell
  bcdedit /set testsigning on   # admin, then reboot
  ```

  A "Test Mode" watermark appears on the desktop, and Secure Boot plus memory integrity must be off
  for `testsigning` to stick. `Setup-Community.ps1` generates the certificate
  (`CN=MagicMouseDriver Community`, private key never leaves your PC), trusts it, signs the package
  and runs `pnputil`.

**For Driver 2 only, removing that requirement is a money problem, not a code problem:** a
commercial EV code-signing certificate plus Microsoft Partner Center attestation signing, renewed
annually. See [funding](https://magictray.app/funding.html). Driver 1 is unaffected — it already
has a Microsoft signature, because it is Apple's binary.

> **Note on the byte-patched variant.** Earlier work in this repo also produced a *modified*
> `applewirelessmouse.sys` (66 KB, SHA256 `370A5555…`, re-signed with a project certificate
> `CN=MagicMouseFix`). Patching the file breaks Apple's Microsoft countersignature, which is why
> that variant needs Test Mode. It is **not** the recommended route and is not what Driver 1 above
> describes — see [`v1-binary-patch/README.md`](v1-binary-patch/README.md).

**Honest expectations, per driver:**

- **Driver 1** is the lighter touch: Apple's own signed driver, no build, no certificate, **no Test
  Mode, Secure Boot can stay on**. You get Apple's scroll behaviour. Re-run the installer if
  re-pairing changes the device InstanceId.
- **Driver 2** does more — surface scroll generation, tunable detent, automatic multitouch recovery
  after reconnect *and* after reboot, battery data for Magic Tray — at the cost of generating a
  cert and running a build if you want it from source.

If you want the least system change — no Test Mode, Secure Boot untouched: **Driver 1**.
If you want full surface scroll, tunable sensitivity and automatic recovery: **Driver 2**.

## Driver 1 — Apple driver, registry-bound (`applewirelessmouse.sys`)

**Status: v1.0.0, production ready.** Full instructions: [`v1-binary-patch/README.md`](v1-binary-patch/README.md).

Apple's own `applewirelessmouse.sys` — the multi-touch filter Boot Camp uses on Macs — installed as
a lower filter on the Bluetooth HID stack. Windows has no equivalent filter, which is why scroll
does not work out of the box. The `.sys` is **not modified**; the fix is registry work, because
Apple's INF has no entry for this mouse's Bluetooth PID.

What the installer does: copy the `.sys` into `System32\drivers`, create the kernel service, add
`applewirelessmouse` to the device's `LowerFilters`, restart the Bluetooth HID device.

- **No build, no certificate, no Test Mode.** The binary keeps Apple's signature and Microsoft's
  WHQL countersignature, so Windows loads it with **Secure Boot and memory integrity on**.
- **Scroll feel is Apple's**, including Mac-style scroll direction.
- **Re-run after re-pairing.** The filter is registered against the device's InstanceId, which can
  change when you unpair and pair again.
- Uninstaller included (`installer/Uninstall-MagicMousePatch.ps1`): removes `LowerFilters`, deletes
  the service, removes the file.
- **Where the driver comes from:** Apple's publicly available Boot Camp Support Software. It is
  Apple's proprietary binary, redistributed under Apple's licence terms — see `DMCA-NOTICE.md`.
- Credit: this route is [`sbagirici/apple-magic-mouse-scroll-fix-windows`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows),
  proven on Magic Mouse v1/v2.

## Driver 2 — KMDF driver (`MagicMouseDriver-kmdf-204-scroll.sys`)

**Status: 2.0.4.3, live and user-confirmed on hardware.** Details: [`v2-kmdf-driver/README.md`](v2-kmdf-driver/README.md), current state in `v2-kmdf-driver/STATUS.md`.

A KMDF lower-filter driver written from scratch. It installs as its **own** driver package
alongside Apple's, and never overwrites `MagicMouseDriver.sys`. Instead of protecting Apple's
scroll path, it reads the touch surface directly and generates scroll itself.

- **Two-finger surface scroll** → HID Wheel + AC Pan. One finger resting or dragging on the glass
  correctly does **not** scroll.
- **Tunable sensitivity.** `ScrollStep` is a registry value: change it and restart the device, no
  rebuild and no reinstall (`v2-kmdf-driver/scripts/mm-scroll-tune.ps1`).
- **Automatic recovery.** Multitouch is re-armed after a Bluetooth reconnect *and* after a reboot,
  both verified on hardware.
- **Battery percentage** via HID Input `0x90` on COL02, surfaced by
  [Magic Tray](https://github.com/LesleyMurfin/magic-tray).
- **Ships its own signing tooling.** `Setup-Community.cmd` / `Setup-Community.ps1` generates a
  local code-signing certificate (`CN=MagicMouseDriver Community`, 10-year, private key never
  leaves your PC), trusts it, enables Test Mode if needed, signs the package and runs `pnputil`.
  Build-from-source path is in `v2-kmdf-driver/BUILDING.md` (needs the EWDK); signing and install
  mechanics in `v2-kmdf-driver/SIGN-AND-INSTALL.md`.
- **What to expect:** self-signed, so it needs Windows Test Mode with Secure Boot and memory
  integrity off — same requirement as Driver 1, just self-generated rather than shipped. That goes
  away only with paid Microsoft driver signing (EV certificate + Partner Center attestation,
  annual). Community testing on a second PC is still wanted — see
  `v2-kmdf-driver/COMMUNITY-TESTING.md`.

## What This Fixes

Apple Magic Mouse v3 on Windows 10/11 loses scroll capability after a Bluetooth idle disconnect
followed by DeviceSetupManager property synchronization. Apple ships no Windows driver for PID
`0x0323` and its Boot Camp INF has no `0323` entry.

Each driver in this repo addresses that differently, and they are not two stages of one thing:

- **Driver 1** keeps Apple's scroll path from collapsing (protects the HID collection structure
  during DSM init).
- **Driver 2** does not rely on Apple's scroll path at all — it translates the raw touch reports
  into scroll itself.

**Affected hardware:**
- Apple Magic Mouse v3 (2024), Bluetooth PID 0x0323
- Windows 10 build 14393 or later / Windows 11 any build

> **Have a Magic Mouse v1 or v2?** This repo is v3-only. For v1/v2 scroll fix on Windows, see [`sbagirici/apple-magic-mouse-scroll-fix-windows`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) — the project this work builds on.

**Symptoms before patch:**
- Scroll wheel works immediately after pairing
- After ~15–30 min idle + Bluetooth disconnect, scroll stops responding
- Cursor movement continues normally
- Issue does not self-recover; requires driver reinstall or device repair

## Supported Hardware

| Model | Year | Bluetooth PID | Supported? |
|-------|------|---------------|------------|
| Magic Mouse v1 | 2009 | `0x030D` | ❌ Not supported — see [sbagirici's repo](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) |
| Magic Mouse v2 | 2015 | `0x0269` | ❌ Not supported — see [sbagirici's repo](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) |
| Magic Mouse v3 | 2024 | `0x0323` | ✅ This repo |

**Verify your PID:** Device Manager → Human Interface Devices → Apple Magic Mouse → Properties → Details → Hardware Ids. Look for `PID&030D`, `PID&0269`, or `PID&0323`.

## System Requirements

Common to both drivers:

- Windows 10 build 14393 or later, or Windows 11 any version
- Apple Magic Mouse v3 (PID `0x0323`) paired over Bluetooth
- Administrator account for installation
- Reboot access

**Driver 2 only:** **Windows Test Mode on** (`bcdedit /set testsigning on`), with **Secure Boot
off** and **memory integrity off**. Driver 1 needs none of that — Apple's binary is
Microsoft-countersigned, so Secure Boot and memory integrity can stay on.

## Quick Install (3 Steps) — Driver 1, Apple driver

> This section installs **Driver 1** only. For **Driver 2** (KMDF), follow
> [`v2-kmdf-driver/README.md`](v2-kmdf-driver/README.md) instead — it is a `pnputil` driver-package
> install, not this installer, and it needs test signing enabled. Do not run both.

### Step 1: Download & Verify

```powershell
# Download v1.0.0 release
# Extract to C:\Program Files\MagicMousePatch\

# Verify binary integrity (mandatory)
$sys = "C:\Program Files\MagicMousePatch\v1-binary-patch\applewirelessmouse.sys"
(Get-FileHash $sys -Algorithm SHA256).Hash
# Expected: 370A5555AEBF673C3156EA5B5FBABD8030F2EE7A3A6BD0FCB1B4B6C93FA56A03
```

### Step 2: Run Installer

```powershell
# Open PowerShell as Administrator
cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
.\Install-MagicMousePatch.ps1

# Accept certificate trust prompt when prompted
```

### Step 3: Reboot

```powershell
# Follow on-screen instructions, or manually:
shutdown /r /t 60 /c "MagicMousePatch installer - rebooting"
```

## What Changes on Your System

| Item | Change |
|------|--------|
| Certificate | MagicMouseFix cert imported to LocalMachine\TrustedPublisher and Root store |
| Driver file | C:\Windows\System32\drivers\applewirelessmouse.sys (66 KB) |
| Service | applewirelessmouse service created, demand-start (Type 1, Start 3) |
| Registry | HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\...\Device Parameters\LowerFilters |
| Backup | Original driver backed up to C:\ProgramData\MagicMousePatch\backup\ |

The patch acts as a WDM lower filter on the Bluetooth HID stack, intercepting device initialization before HID collection structures can collapse.

## Verify It Worked

After reboot:

```powershell
# Check driver is loaded
Get-PnpDevice -Class Mouse | Where-Object {$_.Name -match "Apple"}

# Check service is running
sc query applewirelessmouse
# Should show STATE        : 4 RUNNING

# Event log confirmation (optional)
Get-WinEvent -LogName "Microsoft-Windows-Kernel-PnP/Configuration" -MaxEvents 20 `
  | Where-Object {$_.Message -match "applewirelessmouse"}
```

Test scroll functionality:
1. Open any application with scrollable content
2. Move mouse over content and scroll
3. Disconnect Magic Mouse (turn off), wait 2 minutes, turn back on
4. Verify scroll still works

## Uninstall

```powershell
# Open PowerShell as Administrator
cd "C:\Program Files\MagicMousePatch\v1-binary-patch\installer"
.\Uninstall-MagicMousePatch.ps1

# Follow prompts; reboot when complete
```

Uninstall restores the original driver and removes all Windows registry entries and certificates.

## How It Works — Driver 1 (patched Apple driver)

> Driver 2's design is documented separately in [`v2-kmdf-driver/README.md`](v2-kmdf-driver/README.md)
> and `v2-kmdf-driver/HID-CONTRACT.md`. The mechanism below is Driver 1's.

### The Problem: Mode A → Mode B Collapse

After ~15–30 min idle, Windows DeviceSetupManager writes 35 property descriptors to the
Magic Mouse device container. BTHPORT rewrites its internal service cache, collapsing the
dual HID collection structure:

```
MODE A (working)                      MODE B (broken — after DSM trigger)
────────────────────────────────      ────────────────────────────────────
  Magic Mouse v3 (BT paired)            Magic Mouse v3 (BT paired)
    |                                     |
    +-- COL01  <-- scroll + cursor        +-- TLC (unified)  <-- scroll LOST
    |   (HID\VID_004C&PID_0323&COL01)         cursor still works
    |
    +-- COL02  <-- battery / diag
        (HID\VID_004C&PID_0323&COL02)

  DynamicCachedServices:                DynamicCachedServices:
    Entry 0: COL01  0x00110000            Entry 0: TLC    0x00110000
    Entry 1: COL02  0x00020000            Entry 1: empty  0x00000000
                                          (COL02 gone)
```

Mode B is **permanent** — device reconnect, sleep/wake, and restart do not recover it.
Only fix without this patch: unpair and repair the device.

### The Fix: WDM Lower Filter Driver

`applewirelessmouse.sys` is inserted as a lower filter in the Bluetooth HID stack,
intercepting initialization before the collapse can take hold:

```
  Application (scroll events)
       |
  Windows Input Manager
       |
  hidclass.sys          (HID Class Driver)
       |
  HidBth.sys            (Bluetooth HID miniport)
       |
  applewirelessmouse.sys  <-- LOWER FILTER (this patch)
       |                     intercepts DSM descriptor rewrite
  BTHENUM PDO           (Magic Mouse device node)
       |
  BTHPORT.SYS           (Bluetooth port driver)
       |
  Magic Mouse v3 hardware
```

Registered via:
```
HKLM\SYSTEM\CurrentControlSet\Enum\BTHENUM\
  {00001124-...}_VID&0001004C_PID&0323\...\
    LowerFilters  REG_MULTI_SZ  "applewirelessmouse"
```

**Test evidence:**
- Test 1 (power off/on): scroll persists — PASS
- Test 2 (idle + DSM replay): held Mode A for 69 min vs historical 22 min before flip — PASS
- Test 3 (pnputil rescan): scroll stable — PASS
- Test 4 (sleep/wake): cache byte-identical, scroll works — PASS
- Test 6 (UsoClient force-DSM): scroll preserved — PASS
- Phase 5 (cold reboot): DSM ran twice post-boot, scroll still working — PASS

## Roadmap

Both drivers are maintained. Neither is scheduled for removal, and Driver 2 is **not** a
replacement for Driver 1 — they are different mechanisms with different requirements.

**Driver 1 — patched Apple driver (`v1.0.0`, production ready)**
- Apple's unmodified `applewirelessmouse.sys` as a WDM lower filter
- PowerShell installer + uninstaller, registry `LowerFilters` registration
- Apple-signed + Microsoft WHQL-countersigned, unmodified — no Test Mode, Secure Boot can stay on
- Open: characterise multi-day behaviour beyond the measured 3.1× reduction

**Driver 2 — KMDF driver (`2.0.4.3`, live and confirmed)**
- From-scratch WDF source, no Apple binary dependency
- Its own driver package; Apple's `MagicMouseDriver.sys` untouched
- Two-finger surface scroll, tunable `ScrollStep`, automatic multitouch recovery on reconnect and reboot
- Open: EV signing so test signing is no longer required; community swap-test on a second PC

See [`v2-kmdf-driver/README.md`](v2-kmdf-driver/README.md) and `v2-kmdf-driver/STATUS.md` for Driver 2 status.

## Contributing

### Reporting Issues

File issues at [GitHub Issues](https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix/issues).

**Required information:**
- Windows version and build (run `winver`)
- Magic Mouse hardware version and PID (Device Manager → Human Interface Devices → Apple Magic Mouse → Details → Hardware Ids)
- Steps to reproduce
- Output from Event Viewer:
  - Microsoft-Windows-Kernel-PnP/Configuration (last 50 events)
  - Microsoft-Windows-DeviceSetupManager/Admin (last 50 events)

Export logs:

```powershell
wevtutil epl "Microsoft-Windows-Kernel-PnP/Configuration" C:\pnp-config.evtx
wevtutil epl "Microsoft-Windows-DeviceSetupManager/Admin" C:\dsm-admin.evtx
# Attach .evtx files to issue
```

### Testing Patches

1. Clone this repository
2. Install the patched version per Quick Install
3. Run idle + reconnect test (69+ min)
4. Document results in a test comment with exact Windows version and hardware revision

### Pull Requests

- All commits to feature branches
- PR must include test evidence from your hardware
- Link to related issue
- All .ps1 scripts must pass PSScriptAnalyzer (via GitHub Actions)

## Attribution

Big thanks to [`sbagirici`](https://github.com/sbagirici/apple-magic-mouse-scroll-fix-windows) for the original patched `applewirelessmouse.sys` binary and the LowerFilter installation approach that this project builds on. Without that starting point, the v3 investigation would have taken significantly longer.

**v1 / v2 users:** sbagirici's repo is the right place for you — go give it a star.

Our additions on top of that baseline (v3-specific):
- Full root cause analysis of the H-011 / DSM trigger bug (COL01/COL02 Mode A/B collapse mechanism)
- Test battery (Tests 1–6 + Phase 5) quantifying a 3.1× improvement factor
- Rewritten PowerShell installer/uninstaller with correct LowerFilters path, REG_MULTI_SZ type, and two-level BTHENUM enumeration
- SHA256 verification, DMCA notice, HID descriptor research, and release packaging

## License

MIT License — Copyright 2026 Revive Business Solutions.

See `LICENSE` file for full text.

## Support

Questions? Contact: riley@revivebusiness.ca

For security issues, see `SECURITY.md`.
