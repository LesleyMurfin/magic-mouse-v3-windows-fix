# Build toolchain inventory — the dev machine

**Read this before concluding that anything is missing.** This file exists because the
toolchain has now been "lost" twice, both times for the same reason: **the EWDK is an
ISO, and a remount gives it a different drive letter.** `_build-once.cmd` in the frozen
build directories hardcodes `F:\BuildEnv\SetupBuildEnv.cmd`; the image is currently at
`I:`. Nothing was uninstalled either time.

Every path and value below was measured read-only on 2026-09-17 on this machine, and
each carries the command that produced it. Re-verify rather than trust it if the machine
has been rebuilt.

## Rule 1 — never hardcode the EWDK drive letter

Discover it. The image is identified by a version string, not by a letter:

```powershell
Get-PSDrive -PSProvider FileSystem |
  Where-Object { Test-Path "$($_.Name):\BuildEnv\SetupBuildEnv.cmd" } |
  ForEach-Object { "{0}: {1}" -f $_.Name, (Get-Content "$($_.Name):\Version.txt") }
```

Expected today: `I: Version ge_release_svc_prod1.26100.6584`.

That version string is the one to match — it is byte-identical to the banner in
`C:\mm-dev-queue\kmdf-204-bld-2043\msbuild-once.log`, which is the frozen record of the
build that produced the currently installed driver. Same image, same compiler, same libs.

`v2-kmdf-driver/scripts/kmdf-204-nuget-build.ps1` implements this discovery with an
`-EwdkRoot` override; use it instead of writing the search again.

## The EWDK (primary build path)

| What | Value |
| --- | --- |
| Mounted at | `I:\` — 18.6 GB, `d-r---` read-only, i.e. the ISO. **Was `F:` when the frozen scripts were written.** |
| Version | `ge_release_svc_prod1.26100.6584` (`I:\Version.txt`) |
| Env setup | `I:\BuildEnv\SetupBuildEnv.cmd amd64` (siblings: `SetDevEnv.cmd`, `SetupVSEnv.cmd`) |
| Interactive | `I:\LaunchBuildEnv.cmd` = `@%comspec% /k "%~dp0BuildEnv\SetupBuildEnv.cmd %*"` |
| MSVC in image | `I:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207` |
| Spectre libs | **Present** — `...\14.44.35207\lib\spectre`. Leave `SpectreMitigation` at the image default on this path. |
| KMDF libs | `I:\Program Files\Windows Kits\10\Lib\wdf\kmdf\x64\` (through 1.33) |
| VS version | Developer Command Prompt v17.14.5 (per the frozen `msbuild-once.log` banner) |

`SetupBuildEnv.cmd` sets environment inside a `cmd` session. It does **not** survive into
a PowerShell parent, so drive it in one shell:

```
cmd.exe /c "call I:\BuildEnv\SetupBuildEnv.cmd amd64 && msbuild MagicMouseDriver.vcxproj /t:Build /m /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:RunCodeAnalysis=false /p:EnableInf2cat=false /p:StampInf=false"
```

Those are the exact flags that built the installed driver — toolset
`WindowsKernelModeDriver10.0`, `Universal` target platform. `StampInf=false` matters:
with stamping on, the frozen log shows the INF rewritten to
`DriverVer=09/16/2026,1.44.13.690`, which is a build-clock version, not package identity.

## Host toolchain (fallback build path)

Usable when no EWDK is mounted. Both halves are already on C: — this was proven to be a
complete payload before the `I:` mount was found.

| What | Path |
| --- | --- |
| MSBuild 17.14 | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe` |
| `cl.exe` / `link.exe` / `dumpbin.exe` | `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\` |
| WDK payload + driver MSBuild toolset | `C:\mm-dev-queue\wdk-packages\Microsoft.Windows.WDK.x64.10.0.26100.6584\` |
| — toolset props/targets | `...\c\build\10.0.26100.0\` (`WindowsDriver.*.props/.targets`, `x64\WindowsKernelModeDriver\`, `1033\KernelModeDriver.xml`) |
| — NuGet integration props | `...\build\native\Microsoft.Windows.WDK.x64.props` (sets `WindowsSdkDir`, `WDKContentRoot`, `WDK_NuGet=true`) |
| — KMDF libs | `...\c\Lib\wdf\kmdf\x64\{1.15,1.17,1.19,1.21,1.23,1.25,1.27,1.31,1.33,1.35}` |
| UM SDK headers/libs | `C:\mm-dev-queue\wdk-packages\Microsoft.Windows.SDK.CPP[.x64].10.0.26100.{1,6584}\` |

**The one real deviation on this path:** the host BuildTools install has **no Spectre
libs** (`VC\Tools\MSVC\14.44.35207\lib\spectre` does not exist), while the WDK toolset
defaults `SpectreMitigation` on. It must be disabled explicitly, which produces an
unmitigated kernel binary — a genuine difference from every shipped artifact. The build
script warns when this path is taken. Prefer the EWDK.

## Signing and packaging tools

`signtool.exe` and `Inf2Cat.exe` do **not** need the EWDK; they are in the unpacked
packages. Note the architectures — `Inf2Cat` ships x86-only, which is correct and not a
problem to "fix": it is a host tool and the target arch comes from its `/os:` argument.

| Tool | Path |
| --- | --- |
| `signtool.exe` (x64) | `C:\mm-dev-queue\wdk-packages\Microsoft.Windows.SDK.CPP.10.0.26100.6584\c\bin\10.0.26100.0\x64\signtool.exe` |
| `Inf2Cat.exe` (x86 only) | `C:\mm-dev-queue\wdk-packages\Microsoft.Windows.WDK.x64.10.0.26100.6584\c\bin\10.0.26100.0\x86\Inf2Cat.exe` — invoke with `/os:10_X64` |

Test-signing certificate, as measured:

- Subject `CN=MagicMouseFix`, thumbprint `16940C0F937D569363560D5FEC5CD8FA6D6D9BCE`,
  `NotAfter 2036-05-02`. Verified unelevated via `Get-ChildItem Cert:\LocalMachine\My`.
- Present in `LocalMachine\My` **with** `HasPrivateKey = True`, and in `LocalMachine\Root`
  + `LocalMachine\TrustedPublisher` (all three confirmed). Note there is **more than one**
  `MagicMouseFix` entry in `My`; match on the thumbprint above, not on the subject name.
- The key is **not openable from a non-elevated shell** — signing requires elevation.
  Check the cert before signing, not halfway through.
- `TESTSIGNING` on and HVCI `Enabled=0`, per the elevated `run-battfix01.log`
  (`SystemStartOptions = I TESTSIGNING NOEXECUTE=OPTIN HYPERVISORLAUNCHTYPE=AUTO`).
  **Both readings need elevation**: unelevated, `HKLM\SYSTEM\CurrentControlSet\Control\SystemStartOptions`
  comes back empty and `bcdedit` is unreadable, so an unelevated check cannot distinguish
  "test-signing off" from "cannot see it" — do not gate on it from a plain shell.

## Elevation — use the existing queue runner, not `Start-Process -Verb RunAs`

`Start-Process -Verb RunAs` from this environment dies with
`InvalidOperationException :: The operation was canceled by the user` — the UAC consent
dialog is not reachable from an Orca session. Do not fight it.

Instead use the SYSTEM scheduled task **`MM-Dev-Cycle`** (`RunLevel Highest`, no UAC),
protocol documented in `C:\mm-dev-queue\mm-task-runner.READ.txt` (live copy of
`Revive_Labs/scripts/windows/mm-task-runner.ps1`): a pipe-delimited filesystem queue.

```
printf 'RUN|<nonce>|C:\\path\\to\\script.ps1' > /mnt/c/mm-dev-queue/request.txt
schtasks /run /tn MM-Dev-Cycle          # then poll result.txt for "EXITCODE|<nonce>"
```

Request `C:\mm-dev-queue\request.txt`, result `C:\mm-dev-queue\result.txt`, lock
`running.lock`, per-run log `C:\mm-dev-queue\run-<nonce>.log`. The nonce is what stops a
stale result from a previous run being read as this run's.

One trap that cost a cycle: a PowerShell helper that ends with `& $exe @cmdArgs` and then
`return` gives the caller the tool's **entire transcript as an array**, not its exit code,
so `-ne 0` compares an array and aborts on success. Pipe native output to the host and
return `$LASTEXITCODE`:

```powershell
& $exe @cmdArgs 2>&1 | ForEach-Object { Say $_ }
return $LASTEXITCODE
```

## Building the C# tray on this machine

Not driver work, but the same "where is the toolchain" question, so it lives here too.

- Windows `dotnet` **8.0.425** at `C:\Program Files\dotnet\dotnet.exe`.
- The tray targets `net8.0-windows10.0.17763.0` with WPF/WinForms, so it **cannot build
  under WSL** — the Linux SDK has no `Microsoft.NET.Sdk.WindowsDesktop` and fails at
  MSB4019 before compiling anything. This is a build-time constraint, not just runtime.
- Build and test it over UNC with the Windows SDK, which keeps sources in WSL and writes
  nothing to C::
  ```
  dotnet test '\\wsl.localhost\Ubuntu\<path-to-worktree>\MagicMouseTray.Tests\MagicMouseTray.Tests.csproj'
  ```
- If a Windows tool reports `Access to the path '...\obj\<guid>.tmp' is denied` on a UNC
  path, the WSL directory is not writable by the Windows user: `chmod -R a+rwX` the
  project directories from WSL and retry. That is the whole fix.

## Standing constraints

- **Nothing is written to `C:\`.** Build inside a WSL worktree and reach it over UNC.
  `I:` and the `C:\mm-dev-queue\wdk-packages` trees are read-only inputs.
- `C:` has ~10.7 GB free. Re-downloading the ~18 GB EWDK ISO is not an option — which is
  the other reason to discover the mount rather than assume it is gone.
- WSL interop intermittently fails with `UtilAcceptVsock:271: accept4 failed 110`. It is
  transient; retry.
