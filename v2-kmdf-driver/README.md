# MagicMouseDriver (KMDF) — PID 0x0323 only

**Unique 2.0.4 scroll package.** **2026-09-01 hardware:** pointer + **2-finger** surface scroll + battery `0x90`. 1-finger glass does not scroll. See `CHECKPOINT-2026-09-01-SCROLL.md`.

**Install it ($0, no compiler):** download the release ZIP and double-click `Setup-Community.cmd` — see [Install](#install). **How to help test:** `COMMUNITY-TESTING.md`. Status / leftovers: `STATUS.md`. Ship plan: `SHIPPING.md`. Maintainer pre-signed path: thumb `16940C0F` + `Install-KMDF.cmd`.



**Do not install an unsigned copy-over on the live Apr 30 PC.** That machine keeps
`MagicMouseDriver.sys` SHA256 `AD5D244B…` (oem16 `f7bf31c7`, pointer OK, no wheel).
The failed 2.0.4 (`845435CE…`) reused `MagicMouseDriver.inf` / `MagicMouseDriver.cat` /
`MagicMouseDriver.sys` and overwrote DriverStore oem26 (`79beb68f1da25da4`) so System32
was a hardlink. Restore needed Safe Mode takeown. This package uses a **new INF + catalog
+ dest filename** so Windows creates a new DriverStore folder beside Apr 30.

## Artifact names (do not mix these up)

| Filename | FileVersion | Role |
|----------|-------------|------|
| **`MagicMouseDriver.sys`** | not 2.0.4.1 | **Apr 30 live / restore name only.** SHA `AD5D244B…`. Do not ship a second copy. |
| **`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`** | not 2.0.4.1 | Package label for that pointer-only binary. |
| **`MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys`** | 2.0.2.0 | Pointer-dead. Refuse. |
| **`MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys`** | **2.0.4.1** | **Canonical scroll artifact** after freeze-hash. |
| **`MagicMouseDriver-kmdf-204-scroll.sys`** | **2.0.4.3** | INF dest / ServiceBinary. **This one ships, UNSIGNED**, in the repo and the release ZIP: 25,600 bytes, SHA256 `08E91E37…`. Each user signs their own copy during setup. |
| **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`** | PATH-A v1 | **SHIPBLOCKER.** Never this product. |

Do not install PATH-A. Do not install May 20. Do not install SHA `845435CE…`. No dual-filter.

## Install

### Normal route — release ZIP, one double-click

1. Download `magic-mouse-v3-scroll-community-2.0.4.3.zip` from Releases.
2. Extract the **whole** ZIP to a folder.
3. Double-click **`Setup-Community.cmd`**.

No WDK, no Visual Studio, no compiler, no paid certificate. The ZIP carries the driver binary
**unsigned**; the wizard creates a code-signing certificate on the user's own PC, signs the driver
with it, and installs it. It self-elevates, survives the one mandatory reboot in the middle (run it
again afterwards), and walks through seven phases: `Preflight`, `Certificate`, `TestSigning`,
`SignPackage`, `InstallDriver`, `EnableTouch`, `Verify`. Exit codes: `0` ok, `10` reboot required,
`20` preflight failed, `30` declined, `40` hard error — all printed in plain English.

Because the signature is generated locally it is only accepted in Windows **Test Mode**, so
**Secure Boot and Memory integrity must be OFF**. Removing that requirement needs a commercial EV
certificate plus Microsoft attestation signing — issue #23, not done. Full walkthrough, the
testing matrix and troubleshooting: `COMMUNITY-TESTING.md`. Plain-text version shipped in the ZIP:
`README-FIRST.txt`.

Build the ZIP with `scripts\make-community-zip.ps1` (default `-Version 2.0.4.3`). It packages
exactly the agreed payload, regenerates `SHA256SUMS.txt`, refuses to include maintainer tooling,
signing material, a `.cat` or a `MagicMouseDriver.sys`, verifies the `.sys` against its frozen
hash, and prints the ZIP's SHA256.

### Maintainer / advanced route — pre-signed pnputil install

See `SIGN-AND-INSTALL.md` and `FREEZE-HASH.md`.

1. Windows WDK build → `Freeze-KmdfArtifact.ps1` → `SHA256SUMS.txt`.
2. Human signs `.sys` + `.cat` with cert thumb **16940C0F** (private key on the PC, not in git).
3. `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install`
   or `Install-KMDF.cmd` once the signed catalog exists.

`Install-KMDF.cmd` does **not** copy onto System32 or DriverStore, does **not** delete oem16,
does **not** create a cert, and refuses unsigned files. Override the thumbprint it expects with
`MM_KMDF_SIGN_THUMB`.

## HID contract

Documented in `HID-CONTRACT.md`. Short form:

- Keep Apr 30 pointer usages **X/Y 0x0030/0x0031** on report **0x12**.
- Add wheel **0x0038** (and AC Pan) as **extra**, not a replacement.
- Battery stays HID Input **0x90** COL02. Do not use feature **0x47**.
- Do not reintroduce PATH-A.

## Honest limits

| Topic | What actually happens |
|-------|------------------------|
| **The shipped `.sys`** | A frozen **unsigned** build ships in the repo and the ZIP (25,600 bytes, `08E91E37…`). Linux cannot compile it, so the binary is produced on a Windows WDK box and hash-frozen; nobody publishes a kernel binary signed with a private key. |
| **Test signing** | Self-signed `.sys` needs `bcdedit /set testsigning on` and a reboot. |
| **HVCI / Memory Integrity** | Windows 11 Core isolation blocks self-signed kernel drivers. |
| **Event 41** | Hunch only: DriverEntry/PnP in `845435CE…`, or the oem26 hardlink overwrite. This tree uses a unique package and will not grow ACL reports past proven capacity. Not proven until hardware. |
| **PATH-A** | `applewirelessmouse.sys` is a SHIPBLOCKER (BSOD 0xD1). |

## Layout

```
v2-kmdf-driver/
  MagicMouseDriver-kmdf-204-scroll.inf
  MagicMouseDriver-kmdf-204-scroll.sys  ← UNSIGNED; each user signs their own copy
  Setup-Community.cmd / Setup-Community.ps1   ← community wizard, 7 phases
  Install-KMDF.cmd / Install-KMDF.ps1   ← pnputil /add-driver only (pre-signed)
  Uninstall-KMDF.cmd                    ← unique package only; leaves oem16
  README-FIRST.txt                      ← plain text, shipped in the ZIP
  SHA256SUMS.txt                        ← regenerated at release time
  COMMUNITY-TESTING.md
  SIGN-AND-INSTALL.md
  FREEZE-HASH.md
  HID-CONTRACT.md
  scripts/make-community-zip.ps1        ← builds the release ZIP
  scripts/Freeze-KmdfArtifact.ps1
  scripts/Kmdf-Common.ps1
```

There is **no** `Invoke-KmdfInstall.ps1`, **no** `pr3-activate`, **no** `mm-dev.ps1`.
