# Community testing — Magic Mouse v3 (PID 0323) KMDF 2.0.4.1

Help wanted. This is a **test-signed kernel filter**, not WHQL. It will **not** load on a stock PC with Secure Boot on.

## What should work today

On **Magic Mouse 2024 / USB-C, Bluetooth PID `0x0323` only:**

| You do | Expect |
|--------|--------|
| Move the mouse on the desk | Pointer moves |
| One finger on the glass | **No** scroll (click/rest only) |
| Two fingers swipe on the glass | Vertical/horizontal scroll (wheel + tilt) |
| Battery | Readable (Device Manager / tray if you have it) |

**Not expected:** Mission Control, desktop swipe, pinch, Precision Touchpad gestures, Magic Mouse v1 (`030D`) / v2 (`0269`).

## Can you run this?

You need **all** of:

- Windows 10/11 **64-bit**
- Magic Mouse PID **0323** (Device Manager → HID → Hardware Ids → `PID&0323`)
- Administrator
- **Secure Boot OFF** (firmware)
- **Memory integrity OFF** (Windows Security → Device security → Core isolation)
- Willingness to enable **testsigning** (the script does `bcdedit /set testsigning on` and you **reboot once**)

If Secure Boot stays on, stop. The driver will not load. That is a Windows rule, not a bug.

## Install (no paid certificate)

1. Get the unique package folder (`MagicMouseDriver-kmdf-204-scroll.sys` + `.inf` + `Setup-Community.cmd`). Do **not** use `MagicMouseDriver.sys` or `applewirelessmouse.sys`.
2. Right-click `Setup-Community.cmd` → Run as administrator.
3. If it asks for a reboot (testsigning just turned on): reboot, run `Setup-Community.cmd` **again**.
4. Confirm Device Manager: HID device named like **Apple Magic Mouse (PID 0323) KMDF 2.0.4 scroll**, status Started.

The script makes a cert **on your PC** (`CN=MagicMouseDriver Community`). The private key never leaves the machine. Nothing is uploaded. No PFX in git.

## How to test (please do this)

After install, wait a few seconds (the script sends Feature **F1**; timeout/error 121 is OK).

1. **Pointer** — move on the desk. Must work.
2. **One finger** — rest or drag one finger on the glass. Must **not** scroll.
3. **Two fingers** — swipe two fingers. Must scroll.
4. **Reconnect** — turn the mouse off/on or unpair/pair. Repeat 1–3. If scroll dies until you re-run `scripts\mm-f1-once.ps1`, say so (that is a known gap).
4b. **Magic Tray "Enabled on this PC" checkbox** — confirmed 2026-09-08: toggling it off then on kills 2-finger scroll (pointer keeps working) until `mm-f1-once.ps1` runs again. Not a corrupted install, no reinstall needed — just re-run the F1 script. Report it anyway so the tray gets fixed to do this automatically.
5. **Reboot Windows** — repeat 1–3. Tell us if two-finger scroll survived without running anything.

If 1-finger still scrolls, or 2-finger never scrolls, we need a Diag dump (below).

## What to send if it fails

Admin PowerShell:

```powershell
Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Diag' |
  Select-Object SdpPatchSuccess, LastAclReceived, LastAclCapacity, Rid12Count,
                LastOutHdr, LastOutBufferSize, MtEnableStatus
```

While **two fingers are on the glass**:

| Field | Healthy | Broken |
|-------|---------|--------|
| `SdpPatchSuccess` | 1 | 0 = overlay missed |
| `LastAclReceived` | 23–31 | 9 = no touch tail (F1/MT) |
| `LastOutHdr` | 83 (`0x53`) after F1 | 65 = GET_REPORT only |
| Idle `LastAclBytes` | often `A1 60 02` | ignore idle for scroll |

Also send: Windows version, Secure Boot on/off, testsigning Yes/No, PID from Hardware Ids, and whether oem16 / another Apple mouse driver is installed.

## Do not

- Copy a `.sys` into `C:\Windows\System32\drivers`
- Install `applewirelessmouse.sys` (BSOD)
- Overwrite `MagicMouseDriver.sys` if you already have an older fix
- Expect gestures or v1/v2 support
- Run this on a work PC that requires Secure Boot

## Uninstall

`Install-KMDF.cmd` is the developer (pre-signed) path. For community installs, remove only the unique package:

```bat
pnputil /enum-drivers
```

Delete the published `oemNN.inf` whose Original Name is `MagicMouseDriver-kmdf-204-scroll.inf`. Never `/delete-driver oem16` if that is someone else's restore package.

## Maintainers

Internal leftover list: `STATUS.md`. Swap-test / attestation: `SHIPPING.md`.
