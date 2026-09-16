@echo off
REM ===========================================================================
REM  Apple Magic Mouse v3 (Bluetooth PID 0323) two-finger scroll for Windows
REM  COMMUNITY SETUP - the only file you need to run.
REM
REM  DOUBLE-CLICK THIS FILE. That is the whole instruction.
REM
REM  It requests Administrator itself, so there is nothing to right-click, no
REM  PowerShell window to open and no execution policy to change. Everything
REM  else is done for you by Setup-Community.ps1, which lives in this folder.
REM
REM  WHAT IT WILL DO TO YOUR PC (the wizard asks before it changes anything):
REM    The driver in this folder, MagicMouseDriver-kmdf-204-scroll.sys, is
REM    UNSIGNED. The wizard creates a code-signing certificate on THIS PC,
REM    trusts it locally, signs the driver with it and installs it. No private
REM    key from the maintainer is in this download and none is used.
REM    Because that signature is self-signed, Windows Test Mode is required:
REM    Secure Boot and Memory integrity have to be OFF. Getting rid of that
REM    requirement needs a paid EV certificate plus Microsoft Partner Center
REM    attestation signing - tracked as issue #23, not done yet.
REM
REM  THERE IS ONE REBOOT IN THE MIDDLE. When the wizard asks for it, restart
REM  and then double-click this file again - it resumes where it stopped.
REM
REM  Phases: 1 Preflight   2 Certificate   3 TestSigning   4 SignPackage
REM          5 InstallDriver   6 EnableTouch   7 Verify
REM
REM  Exit codes (translated into plain English on screen below):
REM     0   success / this phase finished
REM     10  reboot required - restart, then run this file again
REM     20  preflight failed - something has to be fixed first
REM     30  declined by the user (includes a dismissed UAC prompt)
REM     40  hard error
REM
REM  Elevation model copied from v1-binary-patch\Install.cmd. Arguments are
REM  passed straight through to the wizard. Known switches:
REM     -Yes          answer the confirmations up front
REM     -DryRun       say what would happen and change nothing (no UAC needed)
REM     -Status       print the current phase from the state file and stop
REM     -Phase <1-7>  run one phase only
REM     -NoElevate    do not self-elevate
REM  The read-only switches above skip the UAC prompt. Note: an argument that
REM  itself contains a double quote cannot survive the UAC re-launch; run this
REM  file from an already-elevated prompt for that.
REM ===========================================================================

setlocal EnableExtensions
set "HERE=%~dp0"
set "PS1=%HERE%Setup-Community.ps1"
set "STATEDIR=C:\ProgramData\MagicMouseDriver"

REM --- Separate our own re-launch marker from the user's real arguments, and
REM     notice the switches that need no Administrator rights at all.
REM     %ARGS% keeps the original quoting because it is built from %1, not %~1.
set "ELEVATED="
set "NOELEV="
set "ARGS="
:parse_args
if "%~1"=="" goto args_done
if /i "%~1"=="--mm-elevated" (set "ELEVATED=1") else (set "ARGS=%ARGS% %1")
if /i "%~1"=="-DryRun"    set "NOELEV=1"
if /i "%~1"=="-Status"    set "NOELEV=1"
if /i "%~1"=="-NoElevate" set "NOELEV=1"
shift
goto parse_args
:args_done

if not exist "%PS1%" (
    echo.
    echo [PROBLEM] Cannot find Setup-Community.ps1 next to this file.
    echo           Looked for: "%PS1%"
    echo.
    echo Extract the WHOLE zip to a real folder first - for example your
    echo Downloads folder - and then double-click Setup-Community.cmd from
    echo inside that folder. Running it straight out of the zip viewer, or
    echo copying out only this one file, cannot work.
    echo.
    pause
    endlocal & exit /b 20
)

REM --- Re-launch elevated if we are not Administrator yet. -------------------
REM     -ExecutionPolicy Bypass is deliberate and is not a weakening: the
REM     script being run ships in this same folder, the user launched it, and
REM     the policy applies to this one child process only.
if defined NOELEV goto run
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
echo This window can be closed.
endlocal & exit /b 0

:declined
echo.
echo [STOPPED] Administrator permission was refused, so nothing was changed.
echo           Installing a driver is not possible without it.
echo           Double-click Setup-Community.cmd again and choose Yes.
echo.
pause
endlocal & exit /b 30

:elevation_broken
echo.
echo [PROBLEM] This window is supposed to be Administrator but Windows says it
echo           is not. Setup stopped rather than loop on the UAC prompt.
echo           Right-click Setup-Community.cmd, choose "Run as administrator",
echo           and if that also fails your account is not an administrator on
echo           this PC.
echo.
pause
endlocal & exit /b 20

REM --- Elevated from here on. -----------------------------------------------
:run
echo.
echo ===========================================================================
echo   Magic Mouse v3 two-finger scroll  -  community setup
echo ===========================================================================
echo.
echo   The driver in this folder is UNSIGNED. It gets signed with a certificate
echo   created on THIS PC, which is why Windows Test Mode is needed and why
echo   Secure Boot and Memory integrity must be OFF. See issue #23.
echo.
echo   Seven phases: Preflight, Certificate, TestSigning, SignPackage,
echo   InstallDriver, EnableTouch, Verify. There is one reboot in the middle.
echo.
cd /d "%HERE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PS1%"%ARGS%
set "RC=%ERRORLEVEL%"

echo.
echo ---------------------------------------------------------------------------
if "%RC%"=="0"  goto rc_ok
if "%RC%"=="10" goto rc_reboot
if "%RC%"=="20" goto rc_preflight
if "%RC%"=="30" goto rc_declined
if "%RC%"=="40" goto rc_error
goto rc_unknown

:rc_ok
echo  FINISHED - the wizard reported success.
echo.
echo  Check it works: put TWO fingers on the glass and swipe. The page should
echo  scroll. ONE finger must NOT scroll. Moving the mouse must still move the
echo  pointer. If the wizard said a phase is still outstanding, run this file
echo  again to carry on.
goto tail

:rc_reboot
echo  RESTART YOUR PC NOW, THEN DOUBLE-CLICK THIS FILE AGAIN.
echo.
echo  Windows Test Mode only takes effect after a restart, so the wizard has
echo  stopped here on purpose. Nothing is broken. After the restart, run
echo  Setup-Community.cmd again and it will continue from where it stopped.
goto tail

:rc_preflight
echo  SOMETHING NEEDS FIXING FIRST - see the message above.
echo.
echo  The usual causes, in order of how often they happen:
echo    - Secure Boot is still ON in the firmware / BIOS setup.
echo    - Memory integrity is still ON: Windows Security, Device security,
echo      Core isolation.
echo    - The Magic Mouse is not paired, or it is not the 2024 USB-C model
echo      (this driver only binds Bluetooth PID 0323).
echo    - The zip was not fully extracted, so a file is missing.
echo  Fix the one it named and double-click this file again.
goto tail

:rc_declined
echo  CANCELLED at your request. Nothing was changed.
goto tail

:rc_error
echo  THE WIZARD HIT AN ERROR IT COULD NOT HANDLE.
echo.
echo  Your driver setup has not been left half-installed on purpose, but do
echo  read the message above before retrying. Please report it with the log
echo  file below - that is genuinely useful, this is a community test.
goto tail

:rc_unknown
echo  Unexpected exit code %RC%. Read the messages above and please report it.
goto tail

:tail
echo.
echo  Folder with the log and the setup state:  %STATEDIR%
echo    community-setup-state.json  - which phase finished last
echo    install.log                 - what happened, in detail
echo.
echo  Report results / problems:
echo    https://github.com/LesleyMurfin/magic-mouse-v3-windows-fix/issues
echo.
echo  To remove the driver again: Uninstall-KMDF.cmd in this folder.
echo ---------------------------------------------------------------------------
echo.
pause
endlocal & exit /b %RC%
