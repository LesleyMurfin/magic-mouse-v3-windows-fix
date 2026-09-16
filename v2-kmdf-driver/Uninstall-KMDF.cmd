@echo off
REM ===========================================================================
REM  Remove the Magic Mouse v3 scroll driver again.
REM
REM  DOUBLE-CLICK THIS FILE. It requests Administrator itself.
REM
REM  It removes ONLY the unique 2.0.4 scroll package
REM  (MagicMouseDriver-kmdf-204-scroll.inf / .sys and the
REM  MagicMouseDriver204Scroll service). It deliberately leaves any older
REM  Apple / MagicMouseDriver.sys install - oem16 - completely alone.
REM
REM  It does NOT turn Windows Test Mode back off and it does NOT delete the
REM  certificate the setup wizard created. Both of those are your call:
REM      bcdedit /set testsigning off        (needs a reboot)
REM  and the certificate can be removed from certlm.msc under
REM  Trusted Publishers / Trusted Root Certification Authorities.
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
    echo Extract the whole zip and run Uninstall-KMDF.cmd from inside that
    echo folder.
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
echo [STOPPED] Administrator permission was refused. Nothing was removed.
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
echo.
echo Removing the unique 2.0.4 scroll package. Older Apple mouse drivers on
echo this PC are left alone.
echo.
cd /d "%HERE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Uninstall%ARGS%
set "RC=%ERRORLEVEL%"

echo.
echo ---------------------------------------------------------------------------
if "%RC%"=="0"  echo  Removed. Two-finger scroll is gone; the pointer keeps working
if "%RC%"=="0"  echo  through Windows' own Bluetooth mouse driver.
if "%RC%"=="10" echo  RESTART REQUIRED to finish removing it. Reboot, then run this
if "%RC%"=="10" echo  file again.
if "%RC%"=="20" echo  Nothing to remove, or a precondition failed - see above.
if "%RC%"=="30" echo  Cancelled at your request. Nothing was removed.
if "%RC%"=="40" echo  Hard error - see the message above and the log.
echo.
echo  Log folder: %STATEDIR%
echo  Test Mode is still ON until you run: bcdedit /set testsigning off
echo ---------------------------------------------------------------------------
echo.
pause
endlocal & exit /b %RC%
