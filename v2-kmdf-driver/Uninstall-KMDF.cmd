@echo off
setlocal
REM Removes only the unique 2.0.4 scroll package.
REM Leaves Apr 30 oem16 / MagicMouseDriver.sys alone.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KMDF.ps1" -Uninstall
set "PSRC=%ERRORLEVEL%"
echo.
echo PowerShell exit code: %PSRC%   (3010 = reboot required - read the Result file before assuming you are done)
pause
exit /b %PSRC%
