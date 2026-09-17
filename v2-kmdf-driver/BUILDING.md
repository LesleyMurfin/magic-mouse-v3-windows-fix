# Building MagicMouseDriver-kmdf-2.0.4-scroll-\<sha8\>.sys

Linux cannot produce a `.sys`. This WSL is a factory-server mirror; Windows work is IaC through `MM-Dev-Cycle`, not `/tmp` copies of `powershell.exe`.

From this WSL (after `WSL-FACTORY-MIRROR`):

```bash
bash v2-kmdf-driver/scripts/kmdf-204-from-wsl.sh
```

That syncs sources to `C:\mm-dev-queue\kmdf-204-src` and runs named phases `KMDF-204-SYNC` / `KMDF-204-BUILD` (unsigned unique `2.0.4.4` only). It does **not** `pnputil` or `INSTALL-DRIVER`.

Build on Windows 10/11 x64 with Visual Studio + WDK, or a mounted Enterprise WDK.

`msbuild` emits **`MagicMouseDriver-kmdf-204-scroll.sys`** (unique INF dest / ServiceBinary). Then freeze it as **`MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys`**. FileVersion / DriverVer is **2.0.4.4** (`DriverVer 09/16/2026,2.0.4.4`). 2.0.4.3 is frozen: it was already built and hashed, so the build script's `FROZEN-UNSIGNED` one-shot guard refuses to rebuild that version and every change must land under a new version number.

Do **not** emit `MagicMouseDriver.sys`. That filename is the Apr 30 restore binary (`AD5D244B…`, oem16 `f7bf31c7`). Never name a KMDF build `applewirelessmouse*.sys`.

## Where is the compiler

`TOOLCHAIN.md` is the durable inventory: EWDK location and discovery rule, the BuildTools + WDK NuGet fallback, signtool / Inf2Cat paths and the cert. Read it instead of searching for a toolchain again.

## WDK / Visual Studio

```bat
msbuild MagicMouseDriver.vcxproj /t:Build /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:EnableInf2cat=false /p:StampInf=false
```

`EnableInf2cat=false` keeps the WDK `Build` target from running signability/Inf2Cat here; the script runs the desktop `InfVerif` check separately before freezing the `.sys`.

```powershell
powershell -NoProfile -File scripts\Freeze-KmdfArtifact.ps1 -SysPath x64\Release\MagicMouseDriver-kmdf-204-scroll.sys
```

`SignMode=Off` is required: WDK's inline sign task often deletes the `.sys` when `signtool` wants `/fd sha256`. A human signs afterwards with thumb **16940C0F** (private key on the PC). See `SIGN-AND-INSTALL.md`.

## Enterprise WDK ISO

1. Mount the EWDK ISO.
2. Run `LaunchBuildEnv.cmd` (or `BuildEnv\SetupBuildEnv.cmd`).
3. `msbuild` the vcxproj as above, then freeze.

## Out-of-tree build: `scripts\kmdf-204-nuget-build.ps1`

Same msbuild line as above, but source dir in / output dir out, nothing written to `C:\`, and no drive letter hardcoded anywhere:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\kmdf-204-nuget-build.ps1 `
    -SourceDir <dir with the .c/.h/.rc/.vcxproj/.inf> -OutDir <build+output dir> [-Configuration Release] [-Clean]
```

Prints the produced `.sys` path, SHA256 and byte size, and exits non-zero on any compile/link failure (2 bad input, 3 no toolchain, 4 build failed, 5 no output, 6 refused output). Intermediates land in `<OutDir>\build`, the binary in `<OutDir>\build\x64\Release` and copied to `<OutDir>`, which is the layout `kmdf-204-scroll-sign.ps1` expects; it also writes `<OutDir>\build\FROZEN-UNSIGNED.txt` in that script's format. Unlike `kmdf-204-scroll-build.ps1` there is **no `FROZEN-UNSIGNED` one-shot guard** - re-running the same version overwrites the record, so the "one build per version number" rule is on you here.

It does not sign, `pnputil`, or touch the DriverStore. Signing and installing stay a separate elevated step (`kmdf-204-scroll-sign.ps1`, `SIGN-AND-INSTALL.md`).

### Primary toolchain: the mounted EWDK

Prerequisite: the EWDK ISO mounted anywhere. **The drive letter is discovered, never assumed** - `_build-once.cmd` said `F:` and the same image came back as `I:` after a remount, which is the whole reason the compiler once looked "missing". The script enumerates every filesystem drive, tests `<letter>:\BuildEnv\SetupBuildEnv.cmd`, and confirms identity from `<letter>:\Version.txt` against `ge_release_svc_prod1.26100.6584`, printing the root and matched version. `-EwdkRoot <path>` overrides the scan; `-EwdkVersion ''` accepts a different image (codegen then no longer matches the frozen artifacts).

It then does exactly what `_build-once.cmd` did - `call <root>\BuildEnv\SetupBuildEnv.cmd amd64` and the frozen msbuild line - in one `cmd.exe` process, because the env script only sets its environment inside its own session. `cmd.exe` cannot `cd` to a UNC path, so the generated `_ewdk-build.cmd` re-enters the build dir with `pushd`, which maps a temporary drive letter; a build under `\\wsl.localhost\...` therefore compiles as `Z:\...`.

### Fallback toolchain: VS BuildTools + WDK NuGet payload

For a host with no EWDK mounted, `-Toolchain NuGet` builds from VS 2022 Build Tools ("Desktop development with C++" workload) plus the unpacked NuGet payload in `C:\mm-dev-queue\wdk-packages` (`-NuGetPackageDir` to relocate): `Microsoft.Windows.WDK.x64`, `Microsoft.Windows.SDK.CPP` (headers, `rc.exe`) and `Microsoft.Windows.SDK.CPP.x64` (um import libs), all three from nuget.org. `-Toolchain Ewdk` forces the primary path instead of falling back; the default `Auto` prefers the EWDK.

The NuGet packages ship the WDK MSBuild toolset but not the VSIX glue that registers `WindowsKernelModeDriver10.0`, and they are three separate roots where an installed kit is one, so the script generates a small overlay `VCTargetsPath` in `<OutDir>\vctargets-overlay` (toolset stub + the package's `ImportAfter` glue + explicit kit paths) and passes it as `AdditionalVCTargetsPath`. Details are commented in the script.

**Spectre mitigation is off on this path** and the script warns about it: BuildTools has no `VC\Tools\MSVC\<ver>\lib\spectre`, which the EWDK image does have. A fallback-built `.sys` is a real codegen deviation from every frozen artifact - measured on the 2.0.4.3 sources, `.text` is 64 bytes smaller and does not match the EWDK build byte-for-byte. Ship EWDK builds; use this only to get a binary at all.

### Toolchain proof (2.0.4.3, 2026-09-17)

Rebuilding the frozen `kmdf-204-bld-2043` sources with the discovered EWDK reproduced `MagicMouseDriver-kmdf-2.0.4-scroll-25A3287A.sys` (26112 bytes) to within **58 bytes in 8 ranges**: `IMAGE_FILE_HEADER.TimeDateStamp`, `IMAGE_OPTIONAL_HEADER.CheckSum`, two `IMAGE_DEBUG_DIRECTORY` timestamps and the CodeView RSDS GUID/age/PDB-path string. Every section except `.rdata` (which holds those debug records) is byte-identical, including `.text`; imports, section table, `FILEVERSION` and the stamped INF hash all match. An out-of-tree build cannot do better - the `.sys` embeds its own PDB path.

## After the `.sys` exists

1. Freeze-hash (above).
2. `inf2cat` + `signtool` with thumb `16940C0F…`.
3. `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install`.

Do not run unsigned activate. Do not `Copy-Item` onto System32 or DriverStore.
