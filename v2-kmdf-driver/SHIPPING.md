# Shipping — unique 2.0.4.1 (PID 0323)

This PC is the only lab. Do not lose the restore package.

## What is proven (2026-09-01)

| | |
|--|--|
| Product on **this** PC | Pointer, battery `0x90`, **2-finger** Wheel/AC Pan, 1-finger glass does not scroll |
| Loaded | oem50 / dest `MagicMouseDriver-kmdf-204-scroll.sys` SHA `9901390e…` signed **16940C0F** |
| Unsigned freeze | `E73EC0A8…` |
| oem16 | `AD5D244B` — never delete |
| Gestures | **Not** in this package (mouse+wheel, not PTP) |

Source: branch `ai/kmdf-204-unique-pkg-7748`, checkpoint `CHECKPOINT-2026-09-01-SCROLL.md`.

## Restore (keep this)

Known-good **16940C0F** unique package:

```
C:\mm-dev-queue\kmdf-204-sign\
  MagicMouseDriver-kmdf-204-scroll.sys
  MagicMouseDriver-kmdf-204-scroll.inf
  MagicMouseDriver-kmdf-204-scroll.cat
```

Reload: `kmdf-204-pnputil-once.ps1` (unique oem50 only, then F1). Do not `Copy-Item` onto System32. Do not delete oem16.

This PC: testsigning **Yes**, Secure Boot **off**, Memory integrity **off**. `16940C0F` HasPrivateKey=True.

## Community script — what was tested vs not

`Setup-Community.cmd` / `Setup-Community.ps1`: local cert `CN=MagicMouseDriver Community`, testsigning, sign unique sys+cat, pnputil, F1.

| Step | Status |
|------|--------|
| Parse on Windows PowerShell 5.1 | Pass (ASCII strings; `New-FileCatalog` without `-Force`) |
| Create cert + trust Root/TrustedPublisher | Pass — thumb `74C7C4888C7E3BA5D2BD82751C2EC094E7CEB211` |
| Sign sys+cat (`-SkipPnputil`) | Pass — Authenticode **Valid** in `C:\mm-dev-queue\community-dry\` |
| `pnputil` of that community-signed package | **Not run** — would replace working oem50 |
| Reboot / first-run testsigning enable | **Not run** — already Yes here |
| Inf2Cat branch | **Not run** — Inf2Cat not on PATH; used `New-FileCatalog` |

## Proper test (swap and restore)

Only way to prove the $0 installer on this hardware:

1. Confirm restore folder `C:\mm-dev-queue\kmdf-204-sign\` still has 16940C0F-signed sys+cat.
2. `pnputil /add-driver` the community-dry unique INF (or run `Setup-Community.ps1` **without** `-SkipPnputil` from that dry folder).
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
