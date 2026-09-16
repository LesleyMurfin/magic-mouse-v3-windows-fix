@echo off
setlocal
REM Signed pnputil /add-driver only. Requires unique INF + signed .cat/.sys.
REM Does NOT copy onto System32\drivers or DriverStore.
REM Does NOT run unsigned activate / pr3-activate-204.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KMDF.ps1"
set "PSRC=%ERRORLEVEL%"
echo.
echo PowerShell exit code: %PSRC%   (3010 = reboot required - read the Result file before assuming you are done)
echo Result file: C:\ProgramData\MagicMouseDriver\RESULT.txt
echo Log:         C:\ProgramData\MagicMouseDriver\install.log
echo.
pause
exit /b %PSRC%
