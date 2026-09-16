# MagicMouseDriver (KMDF) — PID 0x0323 only

**Unique 2.0.4 scroll package.** **2026-09-01 hardware:** pointer + **2-finger** surface scroll + battery `0x90`. 1-finger glass does not scroll. See `CHECKPOINT-2026-09-01-SCROLL.md`.

**Other PCs ($0):** `Setup-Community.cmd` (testsigning, Secure Boot off). **How to help test:** `COMMUNITY-TESTING.md`. Status / leftovers: `STATUS.md`. Ship plan: `SHIPPING.md`. Developer path: thumb `16940C0F` + `Install-KMDF.cmd`.



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
| **`MagicMouseDriver-kmdf-204-scroll.sys`** | **2.0.4.1** | INF dest / ServiceBinary (same bytes as the sha8 file). |
| **`applewirelessmouse-patched-pathA-SHIPBLOCKER.sys`** | PATH-A v1 | **SHIPBLOCKER.** Never this product. |

Do not install PATH-A. Do not install May 20. Do not install SHA `845435CE…`. No dual-filter.

## Install (signed pnputil only)

See `SIGN-AND-INSTALL.md` and `FREEZE-HASH.md`.

1. Windows WDK build → `Freeze-KmdfArtifact.ps1` → `SHA256SUMS.txt`.
2. Human signs `.sys` + `.cat` with cert thumb **16940C0F** (private key on the PC, not in git).
3. `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install`  
   or `Install-KMDF.cmd` after the signed catalog exists.

`Install-KMDF.cmd` does **not** copy onto System32 or DriverStore, does **not** delete oem16,
does **not** create a cert, and refuses unsigned files.

## HID contract

Documented in `HID-CONTRACT.md`. Short form:

- Keep Apr 30 pointer usages **X/Y 0x0030/0x0031** on report **0x12**.
- Add wheel **0x0038** (and AC Pan) as **extra**, not a replacement.
- Battery stays HID Input **0x90** COL02. Do not use feature **0x47**.
- Do not reintroduce PATH-A.

## Honest limits

| Topic | What actually happens |
|-------|------------------------|
| **No `.sys` on GitHub** | Linux cannot compile a kernel driver. Hash is frozen after a Windows WDK build. |
| **Test signing** | Self-signed `.sys` needs `bcdedit /set testsigning on` and a reboot. |
| **HVCI / Memory Integrity** | Windows 11 Core isolation blocks self-signed kernel drivers. |
| **Event 41** | Hunch only: DriverEntry/PnP in `845435CE…`, or the oem26 hardlink overwrite. This tree uses a unique package and will not grow ACL reports past proven capacity. Not proven until hardware. |
| **PATH-A** | `applewirelessmouse.sys` is a SHIPBLOCKER (BSOD 0xD1). |

## Layout

```
v2-kmdf-driver/
  MagicMouseDriver-kmdf-204-scroll.inf
  Install-KMDF.cmd / Install-KMDF.ps1   ← pnputil /add-driver only
  Uninstall-KMDF.cmd                    ← unique package only; leaves oem16
  SIGN-AND-INSTALL.md
  FREEZE-HASH.md
  HID-CONTRACT.md
  scripts/Freeze-KmdfArtifact.ps1
  scripts/Kmdf-Common.ps1
```

There is **no** `Invoke-KmdfInstall.ps1`, **no** `pr3-activate`, **no** `mm-dev.ps1`.
