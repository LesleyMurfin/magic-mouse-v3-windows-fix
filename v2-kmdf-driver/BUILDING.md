# Building MagicMouseDriver.sys

Linux cannot produce a `.sys`. Build on Windows 10/11 x64 with Visual Studio + WDK, or a mounted Enterprise WDK.

## WDK / Visual Studio

```bat
msbuild MagicMouseDriver.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off
```

Output is typically `x64\Release\MagicMouseDriver.sys` (or a WDK subfolder). Copy it next to `MagicMouseDriver.inf` if you want the one-click task to skip compile.

`SignMode=Off` is required: WDK's inline sign task often deletes the `.sys` when `signtool` wants `/fd sha256`. The SYSTEM installer signs afterwards.

## Enterprise WDK ISO

1. Mount the EWDK ISO.
2. Run `LaunchBuildEnv.cmd` (or `BuildEnv\SetupBuildEnv.cmd`).
3. `msbuild` the vcxproj as above.

The SYSTEM task (`MM-Kmdf-Install`) can see WDK on `C:\Program Files*`. It **cannot** see an ISO you mounted only in your interactive session (Session 0). Prefer an installed WDK, or place a prebuilt `.sys` in the package folder.

## After the `.sys` exists

Double-click `Install-KMDF.cmd`. Do not run a pile of helper scripts by hand.
