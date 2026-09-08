@echo off
REM $0 self-sign + testsigning + unique pnputil. Not WHQL.
REM Does NOT copy onto System32\drivers. Does NOT delete oem16.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-Community.ps1"
echo.
echo Result file: C:\ProgramData\MagicMouseDriver\RESULT.txt
echo Log:         C:\ProgramData\MagicMouseDriver\install.log
echo.
pause
