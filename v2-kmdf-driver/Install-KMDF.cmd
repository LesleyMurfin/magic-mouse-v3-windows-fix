@echo off
REM Signed pnputil /add-driver only. Requires unique INF + signed .cat/.sys.
REM Does NOT copy onto System32\drivers or DriverStore.
REM Does NOT run unsigned activate / pr3-activate-204.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KMDF.ps1"
echo.
echo Result file: C:\ProgramData\MagicMouseDriver\RESULT.txt
echo Log:         C:\ProgramData\MagicMouseDriver\install.log
echo.
pause
