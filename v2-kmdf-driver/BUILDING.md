# Building MagicMouseDriver-kmdf-2.0.4-scroll.sys

Linux cannot produce a `.sys`. Build on Windows 10/11 x64 with Visual Studio + WDK, or a mounted Enterprise WDK.

`msbuild` / INF still emit **`MagicMouseDriver.sys`** (Windows service name). Copy or let the installer label the artifact **`MagicMouseDriver-kmdf-2.0.4-scroll.sys`**. FileVersion / DriverVer is **2.0.4.0**.

Do **not** install a build on the live Apr 30 PC (`MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys`, pointer OK / scroll dead) until you are ready to prove 2.0.4 scroll. Do not merge until hardware proves pointer **and** scroll. Never name a KMDF build `applewirelessmouse*.sys`.

## WDK / Visual Studio

```bat
msbuild MagicMouseDriver.vcxproj /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off
```

Output is typically `x64\Release\MagicMouseDriver.sys` (INF name). The installer copies it to `MagicMouseDriver-kmdf-2.0.4-scroll.sys` next to the INF. You can also drop that labeled file next to the INF to skip compile.

`SignMode=Off` is required: WDK's inline sign task often deletes the `.sys` when `signtool` wants `/fd sha256`. The SYSTEM installer signs afterwards.

## Enterprise WDK ISO

1. Mount the EWDK ISO.
2. Run `LaunchBuildEnv.cmd` (or `BuildEnv\SetupBuildEnv.cmd`).
3. `msbuild` the vcxproj as above.

The SYSTEM task (`MM-Kmdf-Install`) can see WDK on `C:\Program Files*`. It **cannot** see an ISO you mounted only in your interactive session (Session 0). Prefer an installed WDK, or place a prebuilt `.sys` in the package folder.

## After the `.sys` exists

Double-click `Install-KMDF.cmd`. Do not run a pile of helper scripts by hand.
