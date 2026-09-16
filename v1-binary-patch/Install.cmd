@echo off
REM ===========================================================================
REM  Magic Mouse scroll fix - one-click installer (Apple driver route)
REM
REM  Double-click this file. It requests Administrator itself, so there is
REM  nothing to type and no PowerShell execution policy to change.
REM
REM  Works on Magic Mouse v1 (030D), v2 (0269 / 0310) and v3 (0323).
REM  Uses Apple's own Microsoft-countersigned driver: no Test Mode, and
REM  Secure Boot / Memory Integrity can stay ON.
REM ===========================================================================

setlocal
set "HERE=%~dp0"
set "PS1=%HERE%installer\Install-MagicMousePatch.ps1"
set "DRV=%HERE%apple-driver\applewirelessmouse.sys"

if not exist "%PS1%" (
    echo [ERROR] Missing "%PS1%"
    echo Extract the whole download, then run Install.cmd again.
    pause
    exit /b 2
)

REM Re-launch elevated if we are not already Administrator.
net session >nul 2>&1
if errorlevel 1 (
    echo Requesting Administrator...
    powershell -NoProfile -ExecutionPolicy Bypass -Command ^
      "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b 0
)

echo.
echo Installing the Magic Mouse scroll fix...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -DriverPath "%DRV%"
set "RC=%ERRORLEVEL%"

echo.
if "%RC%"=="0" (
    echo Done. Reboot to finish.
) else (
    echo Install reported a problem ^(exit %RC%^). Read the messages above.
)
echo.
pause
exit /b %RC%
