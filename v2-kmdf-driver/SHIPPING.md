# Shipping — unique 2.0.4.4 (PID 0323)

This PC is the only lab. Do not lose the restore package.

## What is proven (2026-09-16, last signed package 2.0.4.3)

| | |
|--|--|
| Version | source **2.0.4.4** — `DriverVer 09/16/2026,2.0.4.4`, **not yet built or signed** (adds the COL02 `0x90` battery fix and per-contact scroll notches); last built/signed/installed **2.0.4.3** — `DriverVer 09/15/2026,2.0.4.3` |
| Product on **this** PC | Pointer, battery `0x90`, **2-finger** Wheel/AC Pan, 1-finger glass does not scroll |
| Loaded | dest `MagicMouseDriver-kmdf-204-scroll.sys` signed SHA256 `0CC4458B2D70C58BDFB89AD3C4D5BCDB594D6EE34DEFD0E6C831E56FE22540ED`, cert **16940C0F** |
| Unsigned freeze | `25A3287AE7FBF62873354B71F32B16F7DC47CEA65C165C760A9AFBC28C74F6B2` (26112 bytes) |
| Detent | registry `ScrollStep`; default `MM_SCROLL_STEP` **16** in source since 2026-09-16 (the signed 2.0.4.3 binary shipped 8 and its install measured `Diag!ScrollStep=8`); accepted range `[1,224]` — below `1` falls back to the default, above `224` clamps to `224` |
| oem16 | `AD5D244B` — never delete |
| Gestures | **Not** in this package (mouse+wheel, not PTP) |

Source: branch `ai/kmdf-204-unique-pkg-7748`.

*Dated historical evidence — not the current package:* on **2026-09-01** the **2.0.4.1** build
(oem50, signed `9901390e…`, unsigned freeze `E73EC0A8…`) proved the same pointer / 2-finger
behaviour. Checkpoint: `CHECKPOINT-2026-09-01-SCROLL.md`. It survives only as the rollback target
below.

## Restore (keep this)

Known-good **16940C0F** unique package — this folder still holds the **2026-09-01 2.0.4.1** build
and is kept as dated rollback evidence, not as the shipped version:

```text
C:\mm-dev-queue\kmdf-204-sign\
  MagicMouseDriver-kmdf-204-scroll.sys
  MagicMouseDriver-kmdf-204-scroll.inf
  MagicMouseDriver-kmdf-204-scroll.cat
```

Reload: `kmdf-204-pnputil-once.ps1` (unique INF only, then F1). Its `-Stage` defaults to that
2.0.4.1 folder, so a bare run **is** the rollback; pass `-Stage C:\mm-dev-queue\kmdf-204-sign-2043`
to reload the 2.0.4.3 package (the last one that exists as a binary; 2.0.4.4 has no stage folder
until it is built). Do not `Copy-Item` onto System32. Do not delete oem16.

This PC: testsigning **Yes**, Secure Boot **off**, Memory integrity **off**. `16940C0F` HasPrivateKey=True.

## Community script — what was tested vs not

`Setup-Community.cmd` / `Setup-Community.ps1`: local cert `CN=MagicMouseDriver Community`, testsigning, sign unique sys+cat, pnputil, F1.

| Step | Status |
|------|--------|
| Parse on Windows PowerShell 5.1 | Pass (ASCII strings) |
| Create cert + trust Root/TrustedPublisher | Pass — thumb `74C7C4888C7E3BA5D2BD82751C2EC094E7CEB211` |
| Sign sys+cat (`-SkipPnputil`) | Pass — Authenticode **Valid** in `C:\mm-dev-queue\community-dry\`. That dry run predates the Inf2Cat requirement and catalogued with `New-FileCatalog`; its `.cat` must not be published or handed to `pnputil`. |
| `pnputil` of that community-signed package | **Not run** — would replace working oem50 |
| Reboot / first-run testsigning enable | **Not run** — already Yes here |
| Catalog | **Inf2Cat.exe (WDK) is required.** `New-FileCatalog` does not produce a catalog `pnputil` accepts, so there is no fallback: setup fails with an actionable "install the WDK" message when Inf2Cat is absent. |

## Proper test (swap and restore)

Only way to prove the $0 installer on this hardware:

1. Confirm restore folder `C:\mm-dev-queue\kmdf-204-sign\` still has 16940C0F-signed sys+cat.
2. Re-catalogue that dry folder before anything touches `pnputil`: run `Setup-Community.ps1` **without** `-SkipPnputil` from `C:\mm-dev-queue\community-dry\`. A full run rebuilds the `.cat` with `Inf2Cat.exe`, re-signs it, and only then does `pnputil /add-driver <unique INF> /install`. Do **not** hand the `New-FileCatalog` `.cat` left by the earlier `-SkipPnputil` dry run to `pnputil` — that catalog is not installable.
3. Sleep 3s, `scripts\mm-f1-once.ps1`.
4. Glass: 1-finger must **not** scroll; 2-finger must scroll; pointer; battery.
5. **Immediately** reload `kmdf-204-sign` via `kmdf-204-pnputil-once.ps1` + F1.

Do not reboot mid-test. Do not delete oem16. If step 4 fails, step 5 is the rollback.

## What “shippable” means

| Target | How | Cost | Secure Boot |
|--------|-----|------|-------------|
| **Hobbyist zip** | Unique `.sys`+`.inf` + `Setup-Community.cmd`. Label: testsigning on, Secure Boot off, Memory integrity off. After swap-test. | $0 for users | **Off** |
| **Normal Win11 PC** | Microsoft **attestation** (Partner Center Hardware). You sign a cab with an **EV** cert; Microsoft signs the catalog. Users run `Install-KMDF.cmd`. | You pay EV (~yearly). Users pay $0. | On |
| **Store / WHQL** | HLK lab | Real money | On |

**$0 and Secure Boot on is not possible** for this kernel filter. Microsoft ended third-party cross-signing. Only Microsoft’s signature loads on a stock PC.

Hobbyist zip is not a consumer product. Attestation is the only path to “friend double-clicks, Secure Boot stays on.”

## Gestures

Out of this ship. hidclass sees a mouse with wheel. PTP needs a later virtual HID (spec 5), not a larger SDP overlay (0x50). Tray SendInput is a fake. See checkpoint section **Gestures**.

## Do not

- Run `Setup-Community.cmd` pnputil on the Apr 30 mouse until restore (`kmdf-204-sign`) is verified.
- `Copy-Item` onto `MagicMouseDriver.sys` / DriverStore.
- PATH-A `applewirelessmouse.sys`.
- Ship `MM_SCROLL_STEP 224`.
- Put PFX / private keys in git.
- Claim WHQL or “works on any PC” for the community cert.
