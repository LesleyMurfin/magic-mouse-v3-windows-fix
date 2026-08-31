<#
.SYNOPSIS
Unattended KMDF install path. Run by the MM-Kmdf-Install SYSTEM task.

.DESCRIPTION
Does not prompt. Writes C:\ProgramData\MagicMouseDriver\install.log and RESULT.txt.

  1. Optional build (WDK/EWDK on a fixed path — Session 0 cannot see a user-mounted ISO)
  2. Enable test signing if needed
  3. Create/reuse CN=MagicMouseFix (thumb B902C286…) code-signing cert
  4. Catalog + sign .sys/.cat — refuse the May 20 WDKTestCert (pointer-dead)
  5. pnputil install; LowerFilters=MagicMouseDriver sole on PID 0323 only
  6. Bluetooth bounce only if 0323 HID did not start
  7. Reboot if test signing just changed or pnputil asked for it
  8. Otherwise verify now

Never writes LowerFilters=MagicMouseDriver,applewirelessmouse.
Never binds PID 030D.
#>
[CmdletBinding()]
param(
    [string]$PackageRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

if (-not $PackageRoot) {
    $PackageRoot = Split-Path -Parent $PSScriptRoot
}

. (Join-Path $PSScriptRoot 'Kmdf-Common.ps1')

Initialize-KmdfDataDir
Write-KmdfLog -Message "=== Invoke-KmdfInstall (SYSTEM unattended) ===" -Level 'HEAD'
Write-KmdfLog -Message "PackageRoot=$PackageRoot User=$([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level 'INFO'

function Get-KmdfFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-KmdfForbiddenSys {
    param([Parameter(Mandatory)][string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -like '*may20-pointerdead*' -or $name -eq $script:KmdfArtifactMay20) {
        Write-KmdfLog -Message "Refusing labeled May 20 pointer-dead artifact $name — installer never installs this SHA." -Level 'ERROR'
        return $true
    }
    if ($name -like 'applewirelessmouse*') {
        Write-KmdfLog -Message "Refusing PATH-A package $name — never install as MagicMouseDriver.sys / 0323 product." -Level 'ERROR'
        return $true
    }
    $sha = Get-KmdfFileSha256 -Path $Path
    if ($sha -eq $script:KmdfShaPointerDead) {
        Write-KmdfLog -Message "Refusing May 20 WDKTestCert ($script:KmdfArtifactMay20 / $sha) — pointer-dead. Will not install it." -Level 'ERROR'
        return $true
    }
    return $false
}

function Get-KmdfArtifactLabel {
    param([Parameter(Mandatory)][string]$Path)
    $sha = Get-KmdfFileSha256 -Path $Path
    $name = [System.IO.Path]::GetFileName($Path)
    if ($sha -eq $script:KmdfShaPointerDead -or $name -eq $script:KmdfArtifactMay20) {
        return $script:KmdfArtifactMay20
    }
    if ($sha -eq $script:KmdfShaPointerOk -or $name -eq $script:KmdfArtifactApr30) {
        return $script:KmdfArtifactApr30
    }
    if ($name -eq $script:KmdfArtifactScroll -or $name -like 'MagicMouseDriver-kmdf-2.0.4-scroll*') {
        return $script:KmdfArtifactScroll
    }
    return $script:KmdfArtifactScroll
}

function Find-KmdfSys {
    $hints = @(
        (Join-Path $PackageRoot $script:KmdfArtifactScroll),
        (Join-Path $PackageRoot "x64\Release\$($script:KmdfArtifactScroll)"),
        (Join-Path $PackageRoot $script:KmdfInstallSysName),
        (Join-Path $PackageRoot "x64\Release\$($script:KmdfInstallSysName)"),
        (Join-Path $PackageRoot "x64\Release\MagicMouseDriver\$($script:KmdfInstallSysName)"),
        (Join-Path $PackageRoot "x64\Debug\$($script:KmdfInstallSysName)"),
        (Join-Path $PackageRoot $script:KmdfArtifactApr30)
    )
    $apr30 = $null
    foreach ($h in $hints) {
        if (-not (Test-Path -LiteralPath $h)) { continue }
        $full = (Resolve-Path -LiteralPath $h).Path
        if (Test-KmdfForbiddenSys -Path $full) { continue }
        $sha = Get-KmdfFileSha256 -Path $full
        if ($sha -eq $script:KmdfShaPointerOk) {
            if (-not $apr30) { $apr30 = $full }
            continue
        }
        return $full
    }
    if ($apr30) {
        Write-KmdfLog -Message "Only $($script:KmdfArtifactApr30) is available (pointer OK, scroll dead). Prefer $($script:KmdfArtifactScroll) FileVersion 2.0.4.0." -Level 'WARN'
        return $apr30
    }
    return $null
}

function Backup-KmdfLiveSys {
    $live = Join-Path $env:SystemRoot "System32\drivers\$($script:KmdfInstallSysName)"
    if (-not (Test-Path -LiteralPath $live)) { return }
    if (-not (Test-Path -LiteralPath $script:KmdfBackupDir)) {
        New-Item -ItemType Directory -Path $script:KmdfBackupDir -Force | Out-Null
    }
    $label = Get-KmdfArtifactLabel -Path $live
    $dst = Join-Path $script:KmdfBackupDir $label
    Copy-Item -LiteralPath $live -Destination $dst -Force
    Write-KmdfLog -Message "Backed up live $live as $dst (package name; Windows file stays $($script:KmdfInstallSysName))" -Level 'OK'
}

function Publish-KmdfScrollArtifact {
    param([Parameter(Mandatory)][string]$SysPath)
    $sha = Get-KmdfFileSha256 -Path $SysPath
    if ($sha -eq $script:KmdfShaPointerOk -or $sha -eq $script:KmdfShaPointerDead) {
        return
    }
    $labeled = Join-Path $PackageRoot $script:KmdfArtifactScroll
    if ((Resolve-Path -LiteralPath $SysPath).Path -ne (Join-Path $PackageRoot $script:KmdfArtifactScroll)) {
        Copy-Item -LiteralPath $SysPath -Destination $labeled -Force
        Write-KmdfLog -Message "Labeled scroll artifact $labeled (FileVersion 2.0.4.0). INF still installs as $($script:KmdfInstallSysName)." -Level 'OK'
    }
}

function Invoke-KmdfBuildIfNeeded {
    $sys = Find-KmdfSys
    if ($sys) {
        Write-KmdfLog -Message "Using existing .sys: $sys" -Level 'OK'
        return $sys
    }

    $proj = Join-Path $PackageRoot 'MagicMouseDriver.vcxproj'
    if (-not (Test-Path -LiteralPath $proj)) {
        throw "MagicMouseDriver.vcxproj not found under $PackageRoot"
    }

    $msbuild = Find-KmdfMsBuild
    if (-not $msbuild) {
        throw "$($script:KmdfArtifactScroll) is not in the package and no WDK/EWDK MSBuild was found. Build on Windows with the WDK (FileVersion 2.0.4.0), copy $($script:KmdfArtifactScroll) next to the INF (INF still installs as $($script:KmdfInstallSysName)), then run Install-KMDF.cmd again."
    }

    Write-KmdfLog -Message "Building $proj ($msbuild)" -Level 'INFO'
    $outDir = Join-Path $PackageRoot 'x64\Release'
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null

    if ($msbuild -like 'EWDK:*') {
        $setup = $msbuild.Substring(5)
        $cmd = '"' + $setup + '" && msbuild "' + $proj + '" /m /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:RunCodeAnalysis=false'
        & cmd.exe /c $cmd 2>&1 | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
        if ($LASTEXITCODE -ne 0) { throw "EWDK msbuild exited $LASTEXITCODE" }
    } else {
        & $msbuild $proj /m /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:RunCodeAnalysis=false 2>&1 |
            ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
        if ($LASTEXITCODE -ne 0) { throw "msbuild exited $LASTEXITCODE" }
    }

    $sys = Find-KmdfSys
    if (-not $sys) { throw "Build finished but $($script:KmdfInstallSysName) was not produced." }
    Publish-KmdfScrollArtifact -SysPath $sys
    $labeled = Find-KmdfSys
    if ($labeled) { $sys = $labeled }
    Write-KmdfLog -Message "Built $sys (artifact $($script:KmdfArtifactScroll), installs as $($script:KmdfInstallSysName))" -Level 'OK'
    return $sys
}

function Get-KmdfSigningCert {
    $byThumb = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Thumbprint -eq $script:KmdfCertThumb -and $_.HasPrivateKey } |
        Select-Object -First 1
    if ($byThumb) {
        Write-KmdfLog -Message "Reusing MagicMouseFix thumb $($byThumb.Thumbprint)" -Level 'OK'
        return $byThumb
    }
    $existing = Get-ChildItem Cert:\LocalMachine\My |
        Where-Object { $_.Subject -eq $script:KmdfCertSubject -and $_.HasPrivateKey } |
        Select-Object -First 1
    if ($existing) {
        Write-KmdfLog -Message "Reusing cert $($existing.Subject) $($existing.Thumbprint)" -Level 'OK'
        return $existing
    }
    Write-KmdfLog -Message "Creating $script:KmdfCertSubject code-signing certificate" -Level 'INFO'
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $script:KmdfCertSubject `
        -CertStoreLocation Cert:\LocalMachine\My `
        -KeyUsage DigitalSignature `
        -NotAfter (Get-Date).AddYears(10)
    Write-KmdfLog -Message "Created cert $($cert.Thumbprint)" -Level 'OK'
    return $cert
}

function Install-KmdfTrust {
    param($Cert)
    $cer = Join-Path $script:KmdfDataDir 'MagicMouseDriver.cer'
    Export-Certificate -Cert $Cert -FilePath $cer -Force | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
    Import-Certificate -FilePath $cer -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Write-KmdfLog -Message "Trusted $script:KmdfCertSubject in TrustedPublisher and Root" -Level 'OK'
}

function New-KmdfSignedPackage {
    param(
        [Parameter(Mandatory)][string]$SysPath,
        $Cert
    )
    $stage = Join-Path $script:KmdfDataDir 'pkg'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    $infSrc = Join-Path $PackageRoot 'MagicMouseDriver.inf'
    Copy-Item -LiteralPath $SysPath -Destination (Join-Path $stage 'MagicMouseDriver.sys') -Force
    Copy-Item -LiteralPath $infSrc -Destination (Join-Path $stage 'MagicMouseDriver.inf') -Force

    $cat = Join-Path $stage 'MagicMouseDriver.cat'
    $inf2cat = Find-KmdfInf2Cat
    if ($inf2cat) {
        Write-KmdfLog -Message "inf2cat $stage" -Level 'INFO'
        & $inf2cat /driver:$stage /os:10_X64 2>&1 | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
        if ($LASTEXITCODE -ne 0) { throw "inf2cat exited $LASTEXITCODE" }
    } else {
        Write-KmdfLog -Message "inf2cat not found — New-FileCatalog fallback" -Level 'WARN'
        New-FileCatalog -Path $stage -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
    }
    if (-not (Test-Path -LiteralPath $cat)) { throw "Catalog was not created." }

    $signtool = Find-KmdfSignTool
    $sysDst = Join-Path $stage 'MagicMouseDriver.sys'
    if ($signtool) {
        Write-KmdfLog -Message "signtool $signtool" -Level 'INFO'
        foreach ($f in @($sysDst, $cat)) {
            & $signtool sign /fd sha256 /sm /sha1 $Cert.Thumbprint /tr http://timestamp.digicert.com /td sha256 $f 2>&1 |
                ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
            if ($LASTEXITCODE -ne 0) {
                Write-KmdfLog -Message "Timestamped sign failed on $f — retry without timestamp" -Level 'WARN'
                & $signtool sign /fd sha256 /sm /sha1 $Cert.Thumbprint $f 2>&1 |
                    ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
                if ($LASTEXITCODE -ne 0) { throw "signtool failed on $f" }
            }
        }
    } else {
        Write-KmdfLog -Message "signtool not found — Set-AuthenticodeSignature" -Level 'WARN'
        foreach ($f in @($sysDst, $cat)) {
            $sig = Set-AuthenticodeSignature -FilePath $f -Certificate $Cert
            Write-KmdfLog -Message "$f Authenticode=$($sig.Status)" -Level 'INFO'
            if ($sig.Status -ne 'Valid' -and $sig.Status -ne 'UnknownError') {
                # UnknownError is common without a trusted timestamp on a fresh cert.
                Write-KmdfLog -Message "Signature status $($sig.Status) on $f (test signing will still load it)" -Level 'WARN'
            }
        }
    }
    return $stage
}

function Install-KmdfPnputil {
    param([Parameter(Mandatory)][string]$StageDir)
    $inf = Join-Path $StageDir 'MagicMouseDriver.inf'

    $pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
    $existing = ($pnpRaw -split '(?=Published Name:)') |
        Where-Object { $_ -match 'MagicMouseDriver\.inf' } |
        ForEach-Object { if ($_ -match 'Published Name:\s+(oem\d+\.inf)') { $Matches[1] } }
    foreach ($oem in $existing) {
        Write-KmdfLog -Message "Removing prior $oem" -Level 'INFO'
        & pnputil.exe /delete-driver $oem /uninstall /force 2>&1 |
            ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
    }

    Write-KmdfLog -Message "pnputil /add-driver $inf /install" -Level 'INFO'
    & pnputil.exe /add-driver $inf /install 2>&1 | ForEach-Object { Write-KmdfLog -Message "$_" -Level 'INFO' }
    $rc = $LASTEXITCODE
    if ($rc -eq 0) { return $false }
    if ($rc -eq 3010) {
        Write-KmdfLog -Message "pnputil 3010 — reboot required" -Level 'WARN'
        return $true
    }
    throw "pnputil /add-driver exited $rc"
}

function Bind-Kmdf0323Only {
    $mice = @(Get-Kmdf0323Device)
    if ($mice.Count -eq 0) {
        Write-KmdfLog -Message "PID 0323 not enumerated yet — package is staged. Pair the mouse; post-boot verify will bind." -Level 'WARN'
        return
    }
    foreach ($m in $mice) {
        Write-KmdfLog -Message "0323 instance $($m.InstanceId) status=$($m.Status)" -Level 'INFO'
        Set-KmdfSoleLowerFilter -InstanceId $m.InstanceId | Out-Null
    }
}

function Test-KmdfInstallNow {
    $fail = @()
    $svc = Get-Service -Name $script:KmdfServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $fail += 'service MagicMouseDriver missing'
    } elseif ($svc.Status -ne 'Running') {
        try { Start-Service -Name $script:KmdfServiceName -ErrorAction Stop } catch { $fail += "service not Running ($($svc.Status))" }
        $svc = Get-Service -Name $script:KmdfServiceName -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') { $fail += "service still $($svc.Status)" }
    }

    $mice = @(Get-Kmdf0323Device)
    if ($mice.Count -eq 0) {
        $fail += 'no BTHENUM PID&0323 device'
    } else {
        foreach ($m in $mice) {
            $stack = Get-KmdfDeviceStack -InstanceId $m.InstanceId
            Write-KmdfLog -Message "stack[$($m.InstanceId)]=$stack" -Level 'INFO'
            if (-not $stack) {
                $fail += "no DEVPKEY_Device_Stack for $($m.InstanceId)"
                continue
            }
            if ($stack -notmatch 'HidBth') { $fail += 'stack missing HidBth' }
            if ($stack -notmatch 'MagicMouseDriver') { $fail += 'stack missing MagicMouseDriver' }
            if ($stack -match 'applewirelessmouse') { $fail += 'stack still has applewirelessmouse (dual-filter)' }
            $lfPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($m.InstanceId)"
            $lf = (Get-ItemProperty -LiteralPath $lfPath -ErrorAction SilentlyContinue).LowerFilters
            $lfList = @($lf)
            if ($lfList -contains 'applewirelessmouse') { $fail += 'LowerFilters still lists applewirelessmouse' }
            if ($lfList.Count -ne 1 -or $lfList[0] -ne 'MagicMouseDriver') { $fail += "LowerFilters=$($lfList -join ',')" }
            if ($m.Status -notmatch 'Started|OK') { $fail += "0323 status=$($m.Status)" }
        }
    }

    if ($fail.Count -gt 0) {
        Write-KmdfResult -Status 'FAIL' -Detail ($fail -join '; ')
        return $false
    }
    Write-KmdfResult -Status 'PASS' -Detail 'Service Running; 0323 stack HidBth/MagicMouseDriver; sole LowerFilters; HID started.'
    return $true
}

try {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    if ([int]$os.BuildNumber -lt 14393) {
        throw "Windows build 14393 or later required (got $($os.BuildNumber))"
    }

    if (Test-KmdfHvci) {
        Write-KmdfLog -Message "HVCI / Memory Integrity is ON. Windows 11 will refuse this self-signed .sys. Turn it off: Settings → Privacy & security → Windows Security → Device security → Core isolation → Memory integrity OFF, then reboot and click Install-KMDF.cmd again." -Level 'ERROR'
        Write-KmdfResult -Status 'FAIL' -Detail 'HVCI / Memory Integrity is enabled. Disable it, reboot, run Install-KMDF.cmd again.'
        exit 2
    }

    $needReboot = $false
    if (Enable-KmdfTestSigning) { $needReboot = $true }

    $sys = Invoke-KmdfBuildIfNeeded
    if (Test-KmdfForbiddenSys -Path $sys) {
        throw "Chosen .sys is $($script:KmdfArtifactMay20) (May 20 pointer-dead WDKTestCert). Build $($script:KmdfArtifactScroll) FileVersion 2.0.4.0 from this tree instead."
    }
    $sha = Get-KmdfFileSha256 -Path $sys
    $label = Get-KmdfArtifactLabel -Path $sys
    Write-KmdfLog -Message "Installing $sys as $($script:KmdfInstallSysName) (package label $label) SHA256=$sha" -Level 'INFO'
    if ($sha -eq $script:KmdfShaPointerOk) {
        Write-KmdfLog -Message "This is $($script:KmdfArtifactApr30) (pointer OK, scroll dead). Prefer $($script:KmdfArtifactScroll) FileVersion 2.0.4.0. Installing only because no other .sys is available." -Level 'WARN'
    } else {
        Publish-KmdfScrollArtifact -SysPath $sys
    }
    Backup-KmdfLiveSys

    $cert = Get-KmdfSigningCert
    Install-KmdfTrust -Cert $cert
    $stage = New-KmdfSignedPackage -SysPath $sys -Cert $cert
    if (Install-KmdfPnputil -StageDir $stage) { $needReboot = $true }
    Bind-Kmdf0323Only

    $hidStarted = $true
    foreach ($m in @(Get-Kmdf0323Device)) {
        if ($m.Status -notmatch 'Started|OK') { $hidStarted = $false }
    }
    if (-not $hidStarted) {
        Write-KmdfLog -Message "0323 HID not started — Bluetooth bounce" -Level 'WARN'
        Invoke-KmdfBluetoothBounce
        Bind-Kmdf0323Only
    } else {
        Write-KmdfLog -Message "0323 HID started — skipping Bluetooth bounce" -Level 'OK'
    }

    Save-KmdfState -State @{
        NeedReboot   = $needReboot
        InstalledUtc = (Get-Date).ToUniversalTime().ToString('o')
        SysPath      = $sys
    }

    if ($needReboot) {
        Write-KmdfResult -Status 'PENDING' -Detail 'Driver staged. Rebooting so test signing / PnP can load MagicMouseDriver. Post-boot task MM-Kmdf-PostBoot will verify.'
        Write-KmdfLog -Message "Rebooting in 15 seconds." -Level 'WARN'
        & shutdown.exe /r /t 15 /c "MagicMouseDriver KMDF: reboot to load test-signed driver"
        exit 0
    }

    if (Test-KmdfInstallNow) {
        Write-KmdfLog -Message "Install verified without reboot." -Level 'OK'
        exit 0
    }
    Write-KmdfLog -Message "Immediate verify failed — scheduling reboot so the stack can rebuild." -Level 'WARN'
    Write-KmdfResult -Status 'PENDING' -Detail 'Install finished; verify failed before reboot. Rebooting for MM-Kmdf-PostBoot.'
    & shutdown.exe /r /t 15 /c "MagicMouseDriver KMDF: reboot to rebuild 0323 stack"
    exit 0
} catch {
    Write-KmdfLog -Message "$_" -Level 'ERROR'
    Write-KmdfResult -Status 'FAIL' -Detail "$_"
    exit 1
}
