@echo off
REM One click. First time: accept the Administrator prompt (registers a SYSTEM task).
REM Later clicks: no prompt — the task just runs.
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-KMDF.ps1"
echo.
echo Result file: C:\ProgramData\MagicMouseDriver\RESULT.txt
echo Log:         C:\ProgramData\MagicMouseDriver\install.log
echo.
pause
