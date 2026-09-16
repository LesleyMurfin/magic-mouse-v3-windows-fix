# Freeze-hash gate

Ship one named artifact after a Windows WDK build:

```
MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys
```

`<sha8>` is the first eight hex characters of SHA256 (uppercase). Example after a real build: `MagicMouseDriver-kmdf-2.0.4-scroll-A1B2C3D4.sys`.

Linux cannot produce the `.sys`. There is no frozen hash in this PR until a human builds on Windows.

## Gate

1. Build with WDK (`TargetName` = `MagicMouseDriver-kmdf-204-scroll`).
2. `scripts\Freeze-KmdfArtifact.ps1` hashes the file and writes:
   - `MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys` — canonical
   - `MagicMouseDriver-kmdf-204-scroll.sys` — INF dest / ServiceBinary (same bytes)
   - `SHA256SUMS.txt`
3. Install only if `SHA256SUMS.txt` matches the file you are about to `pnputil`.
4. Never put `MagicMouseDriver.sys` in the package folder. That name is the Apr 30 restore file (`AD5D244B…` / oem16).

## Refuse (do not freeze, do not pnputil)

| SHA256 (prefix) | Why |
|-----------------|-----|
| `AD5D244B…` | Apr 30 known-good pointer-only. Leave as `MagicMouseDriver.sys`. |
| `559B136A…` | May 20 pointer-dead. |
| `845435CE…` | Failed 2.0.4 that overwrote oem26 and preceded Kernel-Power Event 41. |
| any `applewirelessmouse*` | PATH-A SHIPBLOCKER. |

## Why the name includes sha8

The unlabeled `MagicMouseDriver-kmdf-2.0.4-scroll.sys` from PR #3 collided with “the 2.0.4 file” in conversation while System32 still used the live name. Hash-in-the-filename stops a second live-named copy from being treated as restore.
