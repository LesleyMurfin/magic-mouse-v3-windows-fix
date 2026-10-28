# Build toolchain inventory — the dev machine

> **Machine inventory, measured 2026-09-17. Not the build procedure.**
> `BUILDING.md` owns how to build, which flags, and which toolchain; this file only
> records *where* the pieces sit on the one lab PC (`SHIPPING.md`) and what to set so the
> scripts find them. Nothing here is needed to build on your own machine.

**Read this before concluding that anything is missing.** The toolchain has been "lost"
twice, both times for the same reason: **the EWDK is an ISO, and a remount gives it a new
drive letter.** The stale `F:` survives only in the generated `_build-once.cmd` left in
old build dirs under `C:\mm-dev-queue\kmdf-204-bld-*`. Nothing was ever uninstalled.

Both build scripts already refuse to pin a letter:

- `scripts/kmdf-204-nuget-build.ps1` scans every filesystem drive for
  `<letter>:\BuildEnv\SetupBuildEnv.cmd` and confirms `<letter>:\Version.txt` against the
  expected image version (`-EwdkRoot` overrides the scan).
- `scripts/kmdf-204-scroll-build.ps1` mounts `-EwdkIso` / `$env:MM_EWDK_ISO` and takes the
  letter from the `Mount-DiskImage` handle, then writes it into a fresh `_build-once.cmd`.

To find an already-mounted image by hand:

```powershell
Get-PSDrive -PSProvider FileSystem |
  Where-Object { Test-Path "$($_.Name):\BuildEnv\SetupBuildEnv.cmd" } |
  ForEach-Object { "{0}: {1}" -f $_.Name, (Get-Content "$($_.Name):\Version.txt") }
```

Expected today: `I: Version ge_release_svc_prod1.26100.6584` — byte-identical to the
banner in `C:\mm-dev-queue\kmdf-204-bld-2043\msbuild-once.log`, the frozen record of the
build behind the installed driver. Same image, same compiler, same libs.

## Set these two on this machine

| Variable | Value here | Used by |
| --- | --- | --- |
| `MM_EWDK_ISO` | `D:\Users\Lesley\Downloads\EWDK_ge_release_svc_prod1_26100_250904-1728.iso` | `kmdf-204-scroll-build.ps1` (no default — it fails fast without this) |
| `MM_QUEUE_ROOT` | `C:\mm-dev-queue` (also the built-in default) | build, sign and `pnputil` scripts: synced source, per-version build dirs, sign stages, `wdk-packages\` |

## The EWDK (primary toolchain)

| What | Value |
| --- | --- |
| Mounted at | `I:\` — 18.6 GB, `d-r---`, i.e. the ISO. **Was `F:` when the old build dirs froze.** |
| Version | `ge_release_svc_prod1.26100.6584` (`I:\Version.txt`) |
| Env setup | `I:\BuildEnv\SetupBuildEnv.cmd amd64` (siblings: `SetDevEnv.cmd`, `SetupVSEnv.cmd`) |
| Interactive | `I:\LaunchBuildEnv.cmd` = `@%comspec% /k "%~dp0BuildEnv\SetupBuildEnv.cmd %*"` |
| MSVC in image | `I:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207` |
| Spectre libs | **Present** — `...\14.44.35207\lib\spectre`, which is why only this path ships |
| KMDF libs | `I:\Program Files\Windows Kits\10\Lib\wdf\kmdf\x64\` (through 1.33) |
| InfVerif | `I:\Program Files\Windows Kits\10\Tools\10.0.26100.0\x64\InfVerif.exe` |
| VS version | Developer Command Prompt v17.14.5 (per the frozen `msbuild-once.log` banner) |

`SetupBuildEnv.cmd` only sets environment inside its own `cmd` session, so the env call
and `msbuild` must run in one process — both scripts generate a `.cmd` that does exactly
that. `StampInf=false` in the frozen flag line matters: with stamping on, the old log
shows the INF rewritten to `DriverVer=09/16/2026,1.44.13.690`, a build-clock number, not
package identity.

## Host fallback payload (`-Toolchain NuGet`)

Already unpacked on this machine, so `kmdf-204-nuget-build.ps1` can build with no EWDK
mounted. It is a **codegen deviation** (no Spectre libs) and `kmdf-204-scroll-sign.ps1`
refuses to sign the result — see `BUILDING.md` for the rule; this is only where the bits
are.

| What | Path |
| --- | --- |
| MSBuild 17.14 | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe` |
| `cl` / `link` / `dumpbin` | `...\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\` |
| WDK payload + driver toolset | `C:\mm-dev-queue\wdk-packages\Microsoft.Windows.WDK.x64.10.0.26100.6584\` |
| UM SDK headers / import libs | `C:\mm-dev-queue\wdk-packages\Microsoft.Windows.SDK.CPP[.x64].10.0.26100.{1,6584}\` |
| KMDF libs in payload | `...\Microsoft.Windows.WDK.x64...\c\Lib\wdf\kmdf\x64\{1.15 … 1.35}` |
| No Spectre libs | `VC\Tools\MSVC\14.44.35207\lib\spectre` does **not** exist on `C:` |

## Signing and packaging tools

Both live under `%MM_QUEUE_ROOT%\wdk-packages\` and need no EWDK;
`kmdf-204-scroll-sign.ps1` locates them from `-QueueRoot`. The package and kit versions
below are what is unpacked here today, not a contract. `Inf2Cat` is x86-only by design —
it is a host tool and the target arch comes from `/os:`.

| Tool | Path under `wdk-packages\` |
| --- | --- |
| `signtool.exe` (x64) | `Microsoft.Windows.SDK.CPP.10.0.26100.6584\c\bin\10.0.26100.0\x64\signtool.exe` |
| `Inf2Cat.exe` (x86) | `Microsoft.Windows.WDK.x64.10.0.26100.6584\c\bin\10.0.26100.0\x86\Inf2Cat.exe` |

Cert identity is in `SIGN-AND-INSTALL.md` and the host posture in `SHIPPING.md`. What
neither says, and what cost time here:

- There is **more than one** `MagicMouseFix` entry in `LocalMachine\My`. Match the
  thumbprint, never the subject name. `NotAfter` on the right one is 2036-05-02.
- `Get-ChildItem Cert:\LocalMachine\My` reports `HasPrivateKey = True` unelevated, but the
  key is **not openable** without elevation. Check for the key before signing, not
  halfway through.
- An unelevated test-signing check is worthless: `SystemStartOptions` under
  `HKLM\SYSTEM\CurrentControlSet\Control` reads back empty and `bcdedit` is unreadable, so
  it cannot tell "test-signing off" from "cannot see it". Never gate on it from a plain
  shell.

## Elevation on this machine

`Start-Process -Verb RunAs` is not usable from a non-interactive session here: the UAC
consent dialog is unreachable and it surfaces as
`InvalidOperationException :: The operation was canceled by the user`. Admin work goes
through the `MM-Dev-Cycle` scheduled task (SYSTEM, `RunLevel Highest`), which lives on the
machine, not in this repo — its request/result slot is single-threaded, so one run at a
time.

One trap worth keeping: a PowerShell helper ending in `& $exe @cmdArgs` then `return`
hands the caller the tool's **whole transcript as an array**, not an exit code, so a
`-ne 0` test compares an array and aborts on success. Pipe native output to the host and
return `$LASTEXITCODE` (`scripts/mm-f1-once.ps1` shows the shape):

```powershell
& $exe @cmdArgs 2>&1 | ForEach-Object { Say $_ }
return $LASTEXITCODE
```

## The C# tray, for completeness

Tray source lives in the sibling `magic-tray` repo; `MAGIC-TRAY.md` here covers only its
install/binding contract. Same "where is the toolchain" question:

- Windows `dotnet` **8.0.425** at `C:\Program Files\dotnet\dotnet.exe`.
- It targets `net8.0-windows10.0.17763.0` with WPF/WinForms, so it **cannot build under
  WSL** — the Linux SDK has no `Microsoft.NET.Sdk.WindowsDesktop` and dies at MSB4019
  before compiling. Build-time constraint, not just runtime.
- Build and test over UNC with the Windows SDK, keeping sources in WSL:

  ```bash
  dotnet test '\\wsl.localhost\Ubuntu\<worktree>\MagicMouseTray.Tests\MagicMouseTray.Tests.csproj'
  ```

- `Access to the path '...\obj\<guid>.tmp' is denied` over UNC means the WSL directory is
  not writable by the Windows user: `chmod -R a+rwX` the project dirs from WSL, retry.

## Standing constraints

- `C:` has ~10.7 GB free. Re-downloading the ~18 GB EWDK ISO is not an option — the other
  reason to find the mount rather than assume it is gone.
- `I:` and `%MM_QUEUE_ROOT%\wdk-packages` are read-only inputs. Driver sources are edited
  in a WSL worktree; only the scratch queue root is written on `C:`.
- WSL interop intermittently fails with `UtilAcceptVsock:271: accept4 failed 110`. It is
  transient; retry.
