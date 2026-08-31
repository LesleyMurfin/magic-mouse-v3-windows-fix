<#
.SYNOPSIS
Post-boot verify for MagicMouseDriver. Run by MM-Kmdf-PostBoot (SYSTEM, AtStartup).

.DESCRIPTION
Waits for the Bluetooth stack, re-applies sole LowerFilters on PID 0323,
bounces Bluetooth once if the stack is wrong, then writes RESULT.txt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'Kmdf-Common.ps1')

Initialize-KmdfDataDir
Write-KmdfLog -Message "=== Invoke-KmdfPostBoot ===" -Level 'HEAD' -LogPath $script:KmdfVerifyLog
Write-KmdfLog -Message "Waiting 45s for BTHENUM / HidBth..." -Level 'INFO' -LogPath $script:KmdfVerifyLog
Start-Sleep -Seconds 45

try {
    $mice = @(Get-Kmdf0323Device)
    foreach ($m in $mice) {
        Set-KmdfSoleLowerFilter -InstanceId $m.InstanceId | Out-Null
    }

    $svc = Get-Service -Name $script:KmdfServiceName -ErrorAction SilentlyContinue
    $stackOk = $false
    foreach ($m in $mice) {
        $stack = Get-KmdfDeviceStack -InstanceId $m.InstanceId
        Write-KmdfLog -Message "stack=$stack status=$($m.Status)" -Level 'INFO' -LogPath $script:KmdfVerifyLog
        if ($stack -match 'HidBth' -and $stack -match 'MagicMouseDriver' -and $stack -notmatch 'applewirelessmouse') {
            $stackOk = $true
        }
    }

    if (-not $stackOk -or -not $svc -or $svc.Status -ne 'Running') {
        Write-KmdfLog -Message "Stack/service not ready — Bluetooth bounce + rebind" -Level 'WARN' -LogPath $script:KmdfVerifyLog
        Invoke-KmdfBluetoothBounce
        Start-Sleep -Seconds 8
        $mice = @(Get-Kmdf0323Device)
        foreach ($m in $mice) { Set-KmdfSoleLowerFilter -InstanceId $m.InstanceId | Out-Null }
    }

    $fail = @()
    $svc = Get-Service -Name $script:KmdfServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { $fail += 'service missing' }
    elseif ($svc.Status -ne 'Running') { $fail += "service $($svc.Status)" }

    $mice = @(Get-Kmdf0323Device)
    if ($mice.Count -eq 0) { $fail += 'no PID 0323 device' }
    foreach ($m in $mice) {
        $stack = Get-KmdfDeviceStack -InstanceId $m.InstanceId
        Write-KmdfLog -Message "final stack[$($m.InstanceId)]=$stack" -Level 'INFO' -LogPath $script:KmdfVerifyLog
        if ($stack -notmatch 'HidBth') { $fail += 'stack missing HidBth' }
        if ($stack -notmatch 'MagicMouseDriver') { $fail += 'stack missing MagicMouseDriver' }
        if ($stack -match 'applewirelessmouse') { $fail += 'dual-filter applewirelessmouse still present' }
        $lf = @((Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Enum\$($m.InstanceId)" -ErrorAction SilentlyContinue).LowerFilters)
        if ($lf -contains 'applewirelessmouse') { $fail += 'LowerFilters still has applewirelessmouse' }
        if ($lf.Count -ne 1 -or $lf[0] -ne 'MagicMouseDriver') { $fail += "LowerFilters=$($lf -join ',')" }
        if ($m.Status -notmatch 'Started|OK') { $fail += "HID status=$($m.Status)" }
    }

    if ($fail.Count -gt 0) {
        Write-KmdfResult -Status 'FAIL' -Detail ($fail -join '; ')
        exit 1
    }
    Write-KmdfResult -Status 'PASS' -Detail 'Post-boot: service Running; 0323 HidBth/MagicMouseDriver; sole filter; HID started. Confirm pointer AND vertical/horizontal surface scroll.'
    exit 0
} catch {
    Write-KmdfLog -Message "$_" -Level 'ERROR' -LogPath $script:KmdfVerifyLog
    Write-KmdfResult -Status 'FAIL' -Detail "$_"
    exit 1
}
