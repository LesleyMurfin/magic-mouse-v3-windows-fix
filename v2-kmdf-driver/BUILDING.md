# Building MagicMouseDriver-kmdf-2.0.4-scroll-\<sha8\>.sys

Linux cannot produce a `.sys`. This WSL is a factory-server mirror; Windows work is IaC through `MM-Dev-Cycle`, not `/tmp` copies of `powershell.exe`.

From this WSL (after `WSL-FACTORY-MIRROR`):

```bash
bash v2-kmdf-driver/scripts/kmdf-204-from-wsl.sh
```

That syncs sources to `C:\mm-dev-queue\kmdf-204-src` and runs named phases `KMDF-204-SYNC` / `KMDF-204-BUILD` (unsigned unique `2.0.4.1` only). It does **not** `pnputil` or `INSTALL-DRIVER`.

Build on Windows 10/11 x64 with Visual Studio + WDK, or a mounted Enterprise WDK.

`msbuild` emits **`MagicMouseDriver-kmdf-204-scroll.sys`** (unique INF dest / ServiceBinary). Then freeze it as **`MagicMouseDriver-kmdf-2.0.4-scroll-<sha8>.sys`**. FileVersion / DriverVer is **2.0.4.1**.

Do **not** emit `MagicMouseDriver.sys`. That filename is the Apr 30 restore binary (`AD5D244B…`, oem16 `f7bf31c7`). Never name a KMDF build `applewirelessmouse*.sys`.

## WDK / Visual Studio

```bat
msbuild MagicMouseDriver.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off
```

```powershell
powershell -NoProfile -File scripts\Freeze-KmdfArtifact.ps1 -SysPath x64\Release\MagicMouseDriver-kmdf-204-scroll.sys
```

`SignMode=Off` is required: WDK's inline sign task often deletes the `.sys` when `signtool` wants `/fd sha256`. A human signs afterwards with thumb **16940C0F** (private key on the PC). See `SIGN-AND-INSTALL.md`.

## Enterprise WDK ISO

1. Mount the EWDK ISO.
2. Run `LaunchBuildEnv.cmd` (or `BuildEnv\SetupBuildEnv.cmd`).
3. `msbuild` the vcxproj as above, then freeze.

## After the `.sys` exists

1. Freeze-hash (above).
2. `inf2cat` + `signtool` with thumb `16940C0F…`.
3. `pnputil /add-driver MagicMouseDriver-kmdf-204-scroll.inf /install`.

Do not run unsigned activate. Do not `Copy-Item` onto System32 or DriverStore.
