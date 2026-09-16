@echo off
REM ===========================================================================
REM  Magic Mouse scroll fix - one-click installer (Apple driver route)
REM
REM  Double-click this file. It requests Administrator itself, so there is
REM  nothing to type and no PowerShell execution policy to change.
REM
REM  Works on Magic Mouse v1 (030D), v2 (0269 / 0310) and v3 (0323).
REM
REM  There is exactly one install route: the bundled Apple driver is copied to
REM  System32\drivers, registered as a kernel service, and bound to the paired
REM  mouse by writing LowerFilters on that one device instance.
REM
REM  Apple's binary is countersigned by Microsoft, so Test Mode is EXPECTED not
REM  to be required and Secure Boot / Memory Integrity should be able to stay
REM  ON. That is NOT yet verified on a machine with test signing off - the
REM  development PC runs with testsigning on. After the reboot, confirm the
REM  driver really loaded:
REM
REM      sc query applewirelessmouse
REM
REM  Exit codes:
REM      0  success (or a partial state the installer explains)
REM      1  install failed
REM      2  a required file is missing from the extracted download
REM      3  Administrator elevation was declined
REM ===========================================================================

setlocal
set "HERE=%~dp0"
set "PS1=%HERE%installer\Install-MagicMousePatch.ps1"
set "DRV=%HERE%apple-driver\applewirelessmouse.sys"

if not exist "%PS1%" (
    echo [ERROR] Missing "%PS1%"
    echo Extract the whole download, then run Install.cmd again.
    pause
    endlocal
    exit /b 2
)

if not exist "%DRV%" (
    echo [ERROR] Missing "%DRV%"
    echo Extract the whole download, then run Install.cmd again.
    pause
    endlocal
    exit /b 2
)

REM Re-launch elevated if we are not already Administrator. The relaunch exits
REM 3 of its own accord when the UAC prompt is dismissed, so a declined
REM elevation is reported as a failure instead of a silent success.
REM
REM -ExecutionPolicy Bypass is deliberate and not a weakening: the script being
REM run ships in this same folder, the user launched it explicitly, and the
REM policy applies to this child process only - nothing machine-wide changes.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "try { Start-Process -FilePath '%~f0' -Verb RunAs -ErrorAction Stop } catch { exit 3 }"
    if errorlevel 1 (
        echo.
        echo [ERROR] Administrator elevation was declined.
        echo Right-click Install.cmd and choose "Run as administrator".
        pause
        endlocal
        exit /b 3
    )
    endlocal
    exit /b 0
)

echo.
echo Installing the Magic Mouse scroll fix...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DriverPath "%DRV%"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Done. Reboot to finish, then confirm the driver loaded with:
    echo     sc query applewirelessmouse
) else (
    echo Install reported a problem ^(exit %RC%^). Read the messages above.
)
echo.
pause
endlocal & exit /b %RC%
