@echo off
REM ===========================================================================
REM  MAINTAINER / ADVANCED PATH - pre-signed package only.
REM
REM  Most people want Setup-Community.cmd instead. That one creates a
REM  certificate on your own PC and signs the shipped UNSIGNED driver for you.
REM  This file does NOT create a certificate and does NOT sign anything: it
REM  expects MagicMouseDriver-kmdf-204-scroll.sys AND a matching .cat that are
REM  already signed, and it refuses unsigned files.
REM
REM  It runs signed "pnputil /add-driver <inf> /install" only. It does NOT copy
REM  onto System32\drivers or into the DriverStore by hand, and it does NOT
REM  delete oem16 (the Apr 30 pointer-only package).
REM
REM  Double-click is fine - it requests Administrator itself. Arguments are
REM  passed through to Install-KMDF.ps1.
REM
REM  Exit codes: 0 success  10 reboot required  20 preflight failed
REM              30 declined  40 hard error
REM ===========================================================================

setlocal EnableExtensions
set "HERE=%~dp0"
set "PS1=%HERE%Install-KMDF.ps1"
set "STATEDIR=C:\ProgramData\MagicMouseDriver"

set "ELEVATED="
set "ARGS="
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--mm-elevated" (set "ELEVATED=1") else (set "ARGS=%ARGS% %1")
shift
goto parse_args
:args_done

if not exist "%PS1%" (
    echo.
    echo [PROBLEM] Cannot find Install-KMDF.ps1 next to this file.
    echo           Looked for: "%PS1%"
    echo.
    pause
    endlocal & exit /b 20
)

net session >nul 2>&1
if not errorlevel 1 goto run
if defined ELEVATED goto elevation_broken

echo.
echo Requesting Administrator...
if defined ARGS goto relaunch_with_args
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '--mm-elevated' -Verb RunAs -ErrorAction Stop } catch { exit 3 }"
if errorlevel 1 goto declined
goto handed_off

:relaunch_with_args
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process -FilePath '%~f0' -ArgumentList '--mm-elevated%ARGS%' -Verb RunAs -ErrorAction Stop } catch { exit 3 }"
if errorlevel 1 goto declined
goto handed_off

:handed_off
echo A new Administrator window has opened - carry on in that one.
endlocal & exit /b 0

:declined
echo.
echo [STOPPED] Administrator permission was refused. Nothing was changed.
echo.
pause
endlocal & exit /b 30

:elevation_broken
echo.
echo [PROBLEM] Still not Administrator after elevating. Stopped instead of
echo           looping on the UAC prompt.
echo.
pause
endlocal & exit /b 20

:run
cd /d "%HERE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"%ARGS%
set "RC=%ERRORLEVEL%"

echo.
echo ---------------------------------------------------------------------------
if "%RC%"=="0"  echo  Done - the signed package installed.
if "%RC%"=="10" echo  RESTART REQUIRED. Reboot, then run this file again.
if "%RC%"=="20" echo  A precondition failed - see the message above. Usually a
if "%RC%"=="20" echo  missing or unsigned .cat / .sys, or the wrong mouse model.
if "%RC%"=="30" echo  Cancelled at your request. Nothing was changed.
if "%RC%"=="40" echo  Hard error - see the message above and the log.
echo.
echo  Log folder: %STATEDIR%
echo ---------------------------------------------------------------------------
echo.
pause
endlocal & exit /b %RC%
