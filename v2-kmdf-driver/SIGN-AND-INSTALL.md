# Sign and install — unique 2.0.4 scroll package

**Do not merge. Draft PR only.** Linux cannot produce a `.sys`.

Install story is **signed `pnputil /add-driver` only**.

## Ban (this is how oem26 / Event 41 happened)

- No script that `Copy-Item`s onto `C:\Windows\System32\drivers\MagicMouseDriver.sys`
- No script that writes into `C:\Windows\System32\DriverStore`
- No unsigned activate (`pr3-activate-204` or anything like it)
- No `pnputil /delete-driver` of Apr 30 `MagicMouseDriver.inf` / oem16 / `f7bf31c7`
- No second live-named `MagicMouseDriver.sys` in the package folder
- No PATH-A `applewirelessmouse.sys` (SHIPBLOCKER BSOD)
- No PFX / private keys in git

## Package identity (must be new)

| Field | This package | Failed oem26 (do not reuse) | Apr 30 (leave installed) |
|-------|----------------|-----------------------------|---------------------------|
| INF | `MagicMouseDriver-kmdf-204-scroll.inf` | `MagicMouseDriver.inf` | `MagicMouseDriver.inf` |
| CatalogFile | `MagicMouseDriver-kmdf-204-scroll.cat` | `MagicMouseDriver.cat` | existing oem16 cat |
| DriverVer | `09/01/2026,2.0.4.1` | `08/30/2026,2.0.4.0` | pointer-only |
| Dest `.sys` | `MagicMouseDriver-kmdf-204-scroll.sys` | `MagicMouseDriver.sys` (hardlink) | `MagicMouseDriver.sys` |
| DriverStore | new `…204-scroll.inf_amd64_<hash>` | `magicmousedriver.inf_amd64_79beb68f1da25da4` | oem16 `f7bf31c7` |
| SHA256 | freeze after WDK | `845435CE…` refuse | `AD5D244B…` restore baseline |

Windows then creates a **new** DriverStore folder beside oem16. System32 keeps Apr 30 `MagicMouseDriver.sys` for Safe Mode restore.

## On the Windows PC (human)

Private key stays on the PC. Cert thumb:

```
16940C0F937D569363560D5FEC5CD8FA6D6D9BCE
```

1. WDK build:

   ```bat
   msbuild MagicMouseDriver.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off
   ```

   Output: `x64\Release\MagicMouseDriver-kmdf-204-scroll.sys` (not `MagicMouseDriver.sys`).

2. Freeze-hash gate:

   ```powershell
   powershell -NoProfile -File scripts\Freeze-KmdfArtifact.ps1 -SysPath x64\Release\MagicMouseDriver-kmdf-204-scroll.sys
   ```

   Produces `MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys` plus a byte-identical INF payload and `SHA256SUMS.txt`.

3. Catalog + sign (human, thumb 16940C0F):

   ```bat
   inf2cat /driver:. /os:10_X64
   signtool sign /fd sha256 /sha1 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE /tr http://timestamp.digicert.com /td sha256 MagicMouseDriver-kmdf-204-scroll.sys
   signtool sign /fd sha256 /sha1 16940C0F937D569363560D5FEC5CD8FA6D6D9BCE /tr http://timestamp.digicert.com /td sha256 MagicMouseDriver-kmdf-204-scroll.cat
   ```

   Also sign the sha8-named artifact. Do not export or commit the PFX.

4. Add beside Apr 30 (do not replace oem16):

   ```bat
   pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install
   ```

   Or double-click `Install-KMDF.cmd` **after** the signed `.cat` exists. That script only runs `pnputil /add-driver`. It refuses unsigned files, the retired INF, live-named `.sys`, PATH-A, May 20, and SHA `845435CE…`.

5. Confirm pointer **and** wheel. If the stack faults, restore Apr 30 from oem16 / `MagicMouseDriver.sys` SHA `AD5D244B…`. Safe Mode takeown should not be required because this package does not hardlink over that file.


## $0 community install (no paid cert)

End users run **`Setup-Community.cmd`** (Admin) from this folder, with the unique `.sys` + `.inf` present:

1. Creates `CN=MagicMouseDriver Community` code-signing cert on **this PC** (non-exportable key; not in git).
2. Trusts it in LocalMachine Root + TrustedPublisher.
3. `bcdedit /set testsigning on` if needed, then **reboot and run again**.
4. Signs unique `.sys` + `.cat` (Inf2Cat if WDK is present, else `New-FileCatalog`).
5. `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install` only. Sleep 3s. `HidD_SetFeature(F1)`.

Requires: **Secure Boot OFF**, **Memory integrity OFF**, testsigning ON. Not WHQL. Not Secure Boot compatible.

Still banned: System32 copy-over, oem16 delete, PATH-A, live `MagicMouseDriver.sys` in the folder, PFX in git.

Swap-test, restore folder, hobbyist vs EV attestation: `SHIPPING.md`.


Test signing / HVCI: a self-signed `.sys` still needs `bcdedit /set testsigning on` and Memory integrity **off**. That is a Windows policy step, not a copy-over.
