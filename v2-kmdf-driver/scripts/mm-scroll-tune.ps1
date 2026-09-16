# mm-scroll-tune.ps1
#
# Change 2-finger scroll sensitivity WITHOUT rebuilding, re-signing, or
# reinstalling the .sys.
#
# Driver.c reads Services\MagicMouseDriver204Scroll\Parameters!ScrollStep once
# in EvtDeviceAdd and clamps it to [1,224] (GestureEngine.h). ScrollStep is the
# surface drag distance, in touch units, required per Wheel detent:
#
#   HIGHER ScrollStep = MORE finger travel per notch = LESS sensitive
#   LOWER  ScrollStep = LESS finger travel per notch = MORE sensitive
#
# Reference points measured on this hardware:
#   8   - the 2026-09-01 proven default (was ~2x too sensitive in practice
#         before 2.0.4.3, because every finger emitted its own notches)
#   224 - the Linux hid-magicmouse default; produced ZERO wheel on this
#         device, i.e. the "provably too coarse" end of the range
#
# Applying requires a device restart, which drops multitouch back to compact
# 9-byte reports - so this script re-runs F1 afterwards, exactly like
# kmdf-204-pnputil-once.ps1 does. MmAutoF1Watcher would also catch it, but
# waiting on a race is not verification.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, 224)][int]$ScrollStep
)

$ErrorActionPreference = 'Stop'

$ParamsKey = 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Parameters'
$DiagKey   = 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Diag'
$Instance  = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'
$F1        = Join-Path $PSScriptRoot 'mm-f1-once.ps1'

function Fail([int]$c, [string]$m) { Write-Output $m; exit $c }

Write-Output ('===== scroll tune ScrollStep=' + $ScrollStep + ' =====')

if (-not (Test-Path -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll')) {
    Fail 2 'service MagicMouseDriver204Scroll not present - nothing to tune'
}

$prev = 'unset'
if (Test-Path -LiteralPath $ParamsKey) {
    $cur = Get-ItemProperty -LiteralPath $ParamsKey -Name ScrollStep -ErrorAction SilentlyContinue
    if ($null -ne $cur -and $null -ne $cur.ScrollStep) { $prev = $cur.ScrollStep }
} else {
    New-Item -Path $ParamsKey -Force | Out-Null
}
Write-Output ('previous=' + $prev)

Set-ItemProperty -LiteralPath $ParamsKey -Name ScrollStep -Type DWord -Value $ScrollStep
Write-Output ('wrote ScrollStep=' + $ScrollStep)

Write-Output '=== restart 0323 instance so EvtDeviceAdd re-reads it ==='
& pnputil.exe /restart-device $Instance
$restartExit = $LASTEXITCODE
Write-Output ('restart_exit=' + $restartExit)
# 3010 is success-with-reboot-required, not failure.
$rebootRequired = ($restartExit -eq 3010)
if ($restartExit -ne 0 -and -not $rebootRequired) {
    Fail 4 ('pnputil /restart-device exited ' + $restartExit + ' - ScrollStep was written but the driver has not re-read it')
}

Start-Sleep -Seconds 3

Write-Output '=== F1 SetFeature (restore MT after the restart) ==='
if (-not (Test-Path -LiteralPath $F1)) {
    Fail 5 ('F1 script missing ' + $F1 + ' - multitouch would stay in compact mode')
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $F1
$f1Exit = $LASTEXITCODE
Write-Output ('f1_exit=' + $f1Exit)
if ($f1Exit -ne 0) {
    $f1Msg = 'mm-f1-once.ps1 exited ' + $f1Exit + ' - multitouch is still in compact 9-byte mode, two-finger scroll will not work'
    # A pending reboot from /restart-device is the likely cause: the device was
    # never re-initialized, so F1 had nothing in MT mode to talk to. Report the
    # banked 3010 instead of Fail 6 - the only action either code asks for is
    # "reboot, then re-run", and 3010 says which one it is.
    if ($rebootRequired) {
        Write-Output ($f1Msg + ' - the device restart reported 3010, so a reboot is pending and is the likely cause')
        Write-Output 'reboot and re-run this script to verify'
        exit 3010
    }
    Fail 6 $f1Msg
}

# The driver echoes the value it actually loaded into its Diag key, so this
# confirms the restart really re-read the tunable instead of assuming it did.
Start-Sleep -Seconds 2
Write-Output '=== driver-reported state ==='
$diag = Get-ItemProperty -LiteralPath $DiagKey -ErrorAction SilentlyContinue
if ($null -eq $diag) {
    Write-Output 'no Diag key yet - driver has not run its diag timer'
} else {
    Write-Output ('driver_ScrollStep=' + $diag.ScrollStep)
    Write-Output ('LastAclReceived='   + $diag.LastAclReceived + '  (>=14 means multitouch, 9 means compact)')
    Write-Output ('LastOutHdr='        + $diag.LastOutHdr)
    if ($null -ne $diag.ScrollStep -and [int]$diag.ScrollStep -ne $ScrollStep) {
        $diagMsg = 'driver still reports ScrollStep=' + $diag.ScrollStep + ' - restart did not pick up the new value'
        if ($rebootRequired) {
            Write-Output ($diagMsg + ' - the device restart reported 3010, so the re-read is deferred to the reboot')
            Write-Output 'reboot and re-run this script to verify'
            exit 3010
        }
        Fail 3 $diagMsg
    }
}

Write-Output '===== scroll tune done ====='
if ($rebootRequired) {
    Write-Output 'restart reported 3010 - reboot required to finish'
    exit 3010
}
exit 0
