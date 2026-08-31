<#
.SYNOPSIS
One click for a non-technical user: register a SYSTEM task and install MagicMouseDriver for PID 0323.

.DESCRIPTION
Double-click Install-KMDF.cmd. The first run asks for Administrator once so it can
register MM-Kmdf-Install and MM-Kmdf-PostBoot as SYSTEM. After that, this script
only starts the task — no UAC.

The SYSTEM task builds if needed, self-signs, installs, binds 0323 only
(LowerFilters=MagicMouseDriver, no applewirelessmouse, no 030D), bounces
Bluetooth, reboots if test signing just changed, then post-boot verifies.

Results: C:\ProgramData\MagicMouseDriver\RESULT.txt
Logs:    C:\ProgramData\MagicMouseDriver\install.log

.PARAMETER Uninstall
Remove the SYSTEM tasks, unbind 0323, delete the KMDF package.

.PARAMETER NoElevate
Internal. Set when relaunched via UAC so we do not loop.
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'scripts\Kmdf-Common.ps1')

function Start-KmdfInstallTask {
    Write-Host ""
    Write-Host "Starting SYSTEM task '$script:KmdfTaskInstall' (no approval prompt)..." -ForegroundColor Cyan
    & schtasks.exe /run /tn $script:KmdfTaskInstall
    if ($LASTEXITCODE -ne 0) { return $false }
    Write-Host "The installer is running in the background as SYSTEM." -ForegroundColor Green
    Write-Host "Watch:  $script:KmdfResult" -ForegroundColor Yellow
    Write-Host "Log:    $script:KmdfLog" -ForegroundColor Gray
    Write-Host ""
    Write-Host "The PC may reboot by itself if test signing was just turned on." -ForegroundColor Yellow
    Write-Host "After reboot, RESULT.txt is the pass/fail." -ForegroundColor Yellow
    return $true
}

function Copy-KmdfPackageToProgramFiles {
    Initialize-KmdfDataDir
    if (-not (Test-Path -LiteralPath $script:KmdfInstallDir)) {
        New-Item -ItemType Directory -Path $script:KmdfInstallDir -Force | Out-Null
    }
    Write-Host "Copying KMDF package to $script:KmdfInstallDir" -ForegroundColor Gray
    Copy-Item -Path (Join-Path $Here '*') -Destination $script:KmdfInstallDir -Recurse -Force
    icacls.exe "$script:KmdfInstallDir" /inheritance:r /grant 'SYSTEM:(OI)(CI)F' /grant 'Administrators:(OI)(CI)F' /grant 'Users:(OI)(CI)RX' | Out-Null
}

function Register-KmdfSystemTasks {
    $installPs1  = Join-Path $script:KmdfInstallDir 'scripts\Invoke-KmdfInstall.ps1'
    $postBootPs1 = Join-Path $script:KmdfInstallDir 'scripts\Invoke-KmdfPostBoot.ps1'
    if (-not (Test-Path -LiteralPath $installPs1))  { throw "Missing $installPs1" }
    if (-not (Test-Path -LiteralPath $postBootPs1)) { throw "Missing $postBootPs1" }

    $installAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installPs1`" -PackageRoot `"$script:KmdfInstallDir`""
    $postAction = New-ScheduledTaskAction -Execute 'powershell.exe' `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$postBootPs1`""

    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    $installSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 30) `
        -MultipleInstances IgnoreNew `
        -Hidden

    $postSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
        -MultipleInstances IgnoreNew `
        -Hidden

    $startup = New-ScheduledTaskTrigger -AtStartup
    $startup.Delay = 'PT45S'

    Register-ScheduledTask -TaskName $script:KmdfTaskInstall `
        -Action $installAction `
        -Principal $principal `
        -Settings $installSettings `
        -Description 'MagicMouseDriver KMDF one-click install (PID 0323 only). Trigger with schtasks /run — no UAC after first register.' `
        -Force | Out-Null

    Register-ScheduledTask -TaskName $script:KmdfTaskPostBoot `
        -Action $postAction `
        -Principal $principal `
        -Settings $postSettings `
        -Trigger $startup `
        -Description 'MagicMouseDriver KMDF post-boot verify (PID 0323 stack + service).' `
        -Force | Out-Null

    Write-Host "Registered SYSTEM tasks: $script:KmdfTaskInstall , $script:KmdfTaskPostBoot" -ForegroundColor Green
}

function Unregister-KmdfSystemTasks {
    foreach ($n in @($script:KmdfTaskInstall, $script:KmdfTaskPostBoot)) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed task $n" -ForegroundColor Gray
    }
}

function Uninstall-KmdfPackage {
    Write-Host "Unbinding PID 0323 and removing MagicMouseDriver..." -ForegroundColor Yellow
    $mice = @(Get-Kmdf0323Device)
    foreach ($m in $mice) {
        $rp = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($m.InstanceId)"
        try {
            $lf = @((Get-ItemProperty -LiteralPath $rp -ErrorAction Stop).LowerFilters)
            $new = @($lf | Where-Object { $_ -ne 'MagicMouseDriver' })
            if ($new.Count -gt 0) {
                Set-ItemProperty -LiteralPath $rp -Name LowerFilters -Value $new -Type MultiString
            } else {
                Remove-ItemProperty -LiteralPath $rp -Name LowerFilters -ErrorAction SilentlyContinue
            }
            & pnputil.exe /restart-device $m.InstanceId 2>&1 | Out-Null
        } catch {
            Write-Host "  $($m.InstanceId): $_" -ForegroundColor Yellow
        }
    }

    $pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
    $oems = ($pnpRaw -split '(?=Published Name:)') |
        Where-Object { $_ -match 'MagicMouseDriver\.inf' } |
        ForEach-Object { if ($_ -match 'Published Name:\s+(oem\d+\.inf)') { $Matches[1] } }
    foreach ($oem in $oems) {
        & pnputil.exe /delete-driver $oem /uninstall /force 2>&1 | Out-Null
    }

    & sc.exe stop MagicMouseDriver 2>&1 | Out-Null
    & sc.exe delete MagicMouseDriver 2>&1 | Out-Null
    Write-Host "Uninstall finished. Reboot if the mouse stack looks stuck." -ForegroundColor Green
}

# --- later clicks: task already there → no UAC ---
if (-not $Uninstall) {
    $existing = Get-ScheduledTask -TaskName $script:KmdfTaskInstall -ErrorAction SilentlyContinue
    if ($existing) {
        if (Start-KmdfInstallTask) { exit 0 }
        Write-Host "Could not start the existing task (exit $LASTEXITCODE). Will elevate and repair registration." -ForegroundColor Yellow
    }
}

if (-not (Test-KmdfIsAdmin) -and -not $NoElevate) {
    Write-Host "First run needs Administrator once to register the SYSTEM task." -ForegroundColor Yellow
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate')
    if ($Uninstall) { $relaunch += '-Uninstall' }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs -Wait -PassThru
    exit $proc.ExitCode
}

if (-not (Test-KmdfIsAdmin)) {
    Write-Host "Administrator approval was cancelled. Nothing was installed." -ForegroundColor Red
    exit 2
}

if ($Uninstall) {
    Unregister-KmdfSystemTasks
    Uninstall-KmdfPackage
    Write-KmdfResult -Status 'FAIL' -Detail 'Uninstalled by user.'
    exit 0
}

Copy-KmdfPackageToProgramFiles
Register-KmdfSystemTasks
if (-not (Start-KmdfInstallTask)) {
    Write-Host "schtasks /run failed after registration." -ForegroundColor Red
    exit 1
}
exit 0
