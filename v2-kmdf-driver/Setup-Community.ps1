<#
.SYNOPSIS
Guided, resumable setup for the Magic Mouse v3 (2024 USB-C, PID 0323) KMDF
scroll driver. Double-click Setup-Community.cmd and follow the steps.

.DESCRIPTION
The download contains an UNSIGNED kernel driver. Windows will not load an
unsigned kernel driver, and no one can safely publish a pre-signed one, so this
wizard creates a code-signing certificate on YOUR PC and signs the driver with
it. That means Windows Test Mode (test signing) has to be on, which needs one
restart. Removing that requirement needs a paid EV certificate plus Microsoft
attestation signing - tracked as issue #23.

Seven steps, in this order:

  1 Preflight      check Windows version, admin rights, the mouse, the files
  2 Certificate    create a local signing certificate and trust it
  3 TestSigning    enable test signing            <-- RESTART HERE
  4 SignPackage    build the catalog and sign .sys + .cat
  5 InstallDriver  pnputil /add-driver and restart the device
  6 EnableTouch    enable multitouch and install the reconnect watcher
  7 Verify         prove it worked, or say exactly what to do next

Progress is remembered in
  C:\ProgramData\MagicMouseDriver\community-setup-state.json
so after the restart in step 3 you just run Setup-Community.cmd again and it
picks up at step 4. Every step detects work that is already done and skips it,
so running this twice is safe.

Never copies onto System32\drivers or the DriverStore.
Never deletes the Apr 30 oem16 / MagicMouseDriver.inf package.
Never installs anything named like the live pointer driver. PATH-A is refused.

.PARAMETER Yes
Skip the typed confirmation (unattended use). Everything else is unchanged.

.PARAMETER DryRun
Rehearsal. Prints what each of the seven steps would do and changes NOTHING -
no certificate, no bcdedit, no signing, no pnputil, no scheduled task, no state
file, no log file.

.PARAMETER Phase
Re-run a single step (1-7) instead of resuming.

.PARAMETER Status
Print the saved progress and exit.

.PARAMETER NoElevate
Internal. Set when relaunched via UAC so we do not loop.

.NOTES
Exit codes: 0 done / step complete, 10 restart required and re-run,
20 something you must fix first, 30 you declined, 40 error.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$DryRun,
    [ValidateRange(0, 7)][int]$Phase = 0,
    [switch]$Status,
    [switch]$NoElevate
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $Here 'scripts\Kmdf-Common.ps1')

if ($DryRun) {
    # A rehearsal must not even append to install.log.
    $script:KmdfLogToFile = $false
}

$script:KmdfCommunitySubject = 'CN=MagicMouseDriver Community'
$script:CurrentStep = 0
$script:NeedReboot  = $false
$script:StagingDir  = $script:KmdfPackageDir

$script:PhaseTitle = @{
    1 = 'Checking this PC and the downloaded files'
    2 = 'Creating a signing certificate on this PC'
    3 = 'Enabling test signing'
    4 = 'Signing the driver with your certificate'
    5 = 'Installing the driver'
    6 = 'Enabling multitouch so two-finger scroll works'
    7 = 'Checking that everything worked'
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-Act {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('ok', 'info', 'warn', 'fail', 'skip', 'plan')][string]$Status = 'info'
    )
    $tag = switch ($Status) {
        'ok'   { 'OK   ' }
        'warn' { 'WARN ' }
        'fail' { 'FAIL ' }
        'skip' { 'SKIP ' }
        'plan' { 'WOULD' }
        default { '...  ' }
    }
    $color = switch ($Status) {
        'ok'   { 'Green' }
        'warn' { 'Yellow' }
        'fail' { 'Red' }
        'skip' { 'DarkGreen' }
        'plan' { 'DarkCyan' }
        default { 'Gray' }
    }
    Write-Host ("  " + $tag + " " + $Message) -ForegroundColor $color
    if ($script:KmdfLogToFile) {
        Initialize-KmdfDataDir
        $line = "[{0}][STEP{1}][{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $script:CurrentStep, $tag.Trim(), $Message
        Add-Content -LiteralPath $script:KmdfLog -Value $line -Encoding UTF8
    }
}

function Write-StepHeader {
    param([Parameter(Mandatory)][int]$Number)
    $script:CurrentStep = $Number
    Write-Host ''
    Write-Host ("[Step $Number of $($script:KmdfPhaseCount)] " + $script:PhaseTitle[$Number] + "...") -ForegroundColor Cyan
}

function Stop-Wizard {
    param(
        [Parameter(Mandatory)][int]$Code,
        [Parameter(Mandatory)][string]$What,
        [string]$Why,
        [string]$Next
    )
    Write-Host ''
    Write-Host "PROBLEM: $What" -ForegroundColor Red
    if ($Why)  { Write-Host "Why:     $Why" -ForegroundColor Yellow }
    if ($Next) { Write-Host "Next:    $Next" -ForegroundColor Cyan }
    Write-Host ''
    if ($script:CurrentStep -gt 0) {
        Write-Host "Stopped at step $($script:CurrentStep) of $($script:KmdfPhaseCount) ($(Get-KmdfPhaseName $script:CurrentStep)). Later steps were not started." -ForegroundColor Yellow
    }
    Write-Host "Fix the item above, then run Setup-Community.cmd again - finished steps are not repeated." -ForegroundColor Yellow
    if (-not $DryRun) {
        Write-KmdfResult -Status 'FAIL' -Detail "step $($script:CurrentStep): $What"
    }
    exit $Code
}

# ---------------------------------------------------------------------------
# Consent
# ---------------------------------------------------------------------------

function Show-KmdfConsent {
    param([int[]]$Plan)
    Write-Host ''
    Write-Host '===========================================================================' -ForegroundColor Cyan
    Write-Host ' Magic Mouse v3 scroll driver - what this will change on your PC' -ForegroundColor Cyan
    Write-Host '===========================================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host 'The driver in this download is UNSIGNED. Nobody can hand you a safely'
    Write-Host 'pre-signed kernel driver, so this wizard signs it with a certificate it'
    Write-Host 'creates on this PC. Because that certificate is self-signed, Windows will'
    Write-Host 'only load the result in Test Mode.'
    Write-Host ''
    Write-Host 'It will:' -ForegroundColor Yellow
    Write-Host '  1. create a code-signing certificate on this PC (private key never leaves it)'
    Write-Host '  2. add that certificate to two Windows trust stores'
    Write-Host '     (Local Machine > Trusted Root Certification Authorities, and Trusted Publishers)'
    Write-Host '  3. turn ON Windows test signing  (bcdedit /set testsigning on)'
    Write-Host '  4. RESTART your PC once - you then run this same file again'
    Write-Host '  5. sign and install a kernel driver package for the Magic Mouse (PID 0323) only'
    Write-Host '  6. create a scheduled task "MmAutoF1Watcher" so scroll survives reconnects'
    Write-Host ''
    Write-Host 'For this route Windows requires:' -ForegroundColor Yellow
    Write-Host '  - Secure Boot OFF (firmware/BIOS setting)'
    Write-Host '  - Memory integrity OFF (Windows Security > Device security > Core isolation)'
    Write-Host '  Both block self-signed kernel drivers. With Secure Boot ON, test signing'
    Write-Host '  silently refuses to turn on and nothing will work.'
    Write-Host ''
    Write-Host 'Test Mode shows a desktop watermark and is a real security trade-off. The'
    Write-Host 'only way to avoid it is a paid EV certificate plus Microsoft attestation'
    Write-Host 'signing - tracked as issue #23 in the project repository.'
    Write-Host ''
    Write-Host 'It will NOT touch your existing pointer driver, will NOT copy files into'
    Write-Host 'System32\drivers by hand, and will NOT remove any other driver package.'
    Write-Host ''
    Write-Host ('Steps queued this run: ' + ($Plan -join ', ')) -ForegroundColor Gray
    Write-Host 'To undo everything later: run Uninstall-KMDF.cmd, then bcdedit /set testsigning off.'
    Write-Host ''

    if ($DryRun) {
        Write-Act -Status 'plan' -Message 'ask you to type YES here (rehearsal, so no prompt)'
        return
    }
    if ($Yes) {
        Write-Act -Status 'info' -Message '-Yes given: continuing without the typed confirmation'
        return
    }
    $answer = ''
    try { $answer = Read-Host 'Type YES to continue, or press Enter to stop' }
    catch { $answer = '' }
    if ($null -eq $answer -or $answer.Trim().ToUpperInvariant() -ne 'YES') {
        Write-Host ''
        Write-Host 'Stopped at your request. Nothing on this PC was changed.' -ForegroundColor Yellow
        Write-Host 'Run Setup-Community.cmd again when you are ready (or with -Yes for unattended).' -ForegroundColor Yellow
        exit $script:KmdfExitDeclined
    }
    Write-Act -Status 'ok' -Message 'confirmation received'
}

# ---------------------------------------------------------------------------
# Shared checks
# ---------------------------------------------------------------------------

function Get-KmdfCommunityCertObject {
    $st = Read-KmdfState
    if ($null -ne $st -and $st['certThumbprint']) {
        $byThumb = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint.ToUpperInvariant() -eq $st['certThumbprint'] -and $_.HasPrivateKey } |
            Select-Object -First 1
        if ($byThumb) { return $byThumb }
    }
    return (Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq $script:KmdfCommunitySubject -and $_.HasPrivateKey } |
        Select-Object -First 1)
}

function Assert-KmdfTestSigningActive {
    if (Test-KmdfTestSigningOn) {
        Write-Act -Status 'ok' -Message 'test signing is ON'
        return
    }
    if ($DryRun) {
        Write-Act -Status 'warn' -Message 'test signing is currently OFF - a real run would stop here until step 3 plus a restart had taken effect'
        return
    }
    $why = 'bcdedit reports testsigning is not active. Windows will refuse to load a self-signed kernel driver without it.'
    $next = 'Did you restart after step 3? If you did, Secure Boot is almost certainly still ON - it silently blocks test signing. Turn Secure Boot OFF in your firmware (and Memory integrity OFF in Windows Security > Device security), restart, then run Setup-Community.cmd again.'
    if (Test-KmdfSecureBootOn) {
        $why = 'Secure Boot is ON. Windows accepts the bcdedit command but ignores test signing while Secure Boot is enabled - that is why nothing happened.'
        $next = 'Restart into your firmware/BIOS setup, set Secure Boot to Disabled, boot Windows, then run Setup-Community.cmd again.'
    }
    elseif (Test-KmdfFastStartupOn) {
        $next = 'Fast Startup is ON, so "Shut down" does not fully restart Windows. Use Start > Power > Restart, then run Setup-Community.cmd again. If it still says OFF, turn Secure Boot OFF in firmware.'
    }
    # Step 3 has to happen again once the blocker is cleared.
    Update-KmdfState -Phase 2 -LogEntry 'test signing not active after reboot; step 3 will re-run' | Out-Null
    Stop-Wizard -Code $script:KmdfExitPreflight -What 'Test signing (Windows Test Mode) is not active' -Why $why -Next $next
}

# ---------------------------------------------------------------------------
# Step 1 - Preflight
# ---------------------------------------------------------------------------

function Invoke-KmdfPhase1 {
    $fatal = @()

    $ver = [Environment]::OSVersion.Version
    if ($ver.Build -ge 14393) {
        Write-Act -Status 'ok' -Message "Windows build $($ver.Build) (needs 14393 or newer)"
    }
    else {
        $fatal += @{
            What = "Windows build $($ver.Build) is too old"
            Why  = 'This driver package needs Windows 10 build 14393 (1607) or newer.'
            Next = 'Update Windows, then run Setup-Community.cmd again.'
        }
    }

    if ([Environment]::Is64BitOperatingSystem) {
        Write-Act -Status 'ok' -Message '64-bit Windows (x64)'
    }
    else {
        $fatal += @{
            What = 'This is not 64-bit Windows'
            Why  = 'Only an x64 build of the driver exists.'
            Next = 'This PC cannot run the driver. Nothing was changed.'
        }
    }

    if (Test-KmdfIsAdmin) {
        Write-Act -Status 'ok' -Message 'running as Administrator'
    }
    elseif ($DryRun) {
        Write-Act -Status 'warn' -Message 'not Administrator - a real run needs it and would ask for approval'
    }
    else {
        $fatal += @{
            What = 'Not running as Administrator'
            Why  = 'Installing a driver, trusting a certificate and changing boot settings all need Administrator.'
            Next = 'Right-click Setup-Community.cmd and choose "Run as administrator".'
        }
    }

    # Files the ZIP must contain.
    $required = @(
        $script:KmdfUniqueInf,
        $script:KmdfUniqueSys,
        'scripts\Kmdf-Common.ps1',
        'scripts\mm-f1-once.ps1',
        'scripts\mm-auto-f1-watcher.ps1',
        'scripts\mm-auto-f1-watcher-install.ps1'
    )
    $missing = @()
    foreach ($rel in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $Here $rel))) { $missing += $rel }
    }
    if ($missing.Count -eq 0) {
        Write-Act -Status 'ok' -Message "all $($required.Count) required files are present"
    }
    else {
        Write-Act -Status 'fail' -Message ("missing from this folder: " + ($missing -join ', '))
        $fatal += @{
            What = 'The download is incomplete'
            Why  = "These files are missing next to Setup-Community.cmd: $($missing -join ', ')"
            Next = 'Download the release ZIP again and extract ALL of it (right-click > Extract All), then run Setup-Community.cmd from the extracted folder.'
        }
    }

    # Driver binary identity.
    $sys = Join-Path $Here $script:KmdfUniqueSys
    if (Test-Path -LiteralPath $sys) {
        $sha = Get-KmdfFileSha256 -Path $sys
        $size = (Get-Item -LiteralPath $sys).Length
        if ($sha -eq $script:KmdfUnsignedSysSha) {
            Write-Act -Status 'ok' -Message "driver $($script:KmdfUniqueSys) matches the published $($script:KmdfDriverVersion) checksum ($size bytes, unsigned)"
            if (-not $DryRun) { Update-KmdfState -DriverSha256 $sha | Out-Null }
        }
        elseif (Test-KmdfSignedByExpected -Path $sys) {
            Write-Act -Status 'ok' -Message 'driver is already signed by this PC certificate (hash differs from the unsigned download by design)'
        }
        else {
            Write-Act -Status 'fail' -Message "driver checksum is $sha, expected $($script:KmdfUnsignedSysSha)"
            $fatal += @{
                What = 'The driver file does not match the published checksum'
                Why  = "$($script:KmdfUniqueSys) is $size bytes with SHA256 $sha; the released $($script:KmdfDriverVersion) build is $($script:KmdfUnsignedSysBytes) bytes with SHA256 $($script:KmdfUnsignedSysSha)."
                Next = 'Delete this folder, download the release ZIP again from the project Releases page, and extract it fresh. Do not run a driver you cannot verify.'
            }
        }
    }

    # Identity / banned-artifact gates (protects the existing pointer driver).
    $pkgProblems = @()
    if (Test-Path -LiteralPath (Join-Path $Here $script:KmdfUniqueInf)) {
        $pkgProblems = @(Get-KmdfPackageProblem -Directory $Here)
    }
    if ($pkgProblems.Count -eq 0) {
        Write-Act -Status 'ok' -Message 'package identity checks passed (unique INF, unique service, no live-driver filenames)'
    }
    else {
        foreach ($p in $pkgProblems) { Write-Act -Status 'fail' -Message $p }
        $fatal += @{
            What = 'The package in this folder failed a safety check'
            Why  = $pkgProblems[0]
            Next = 'Re-download the release ZIP and extract it to an empty folder. Do not mix it with files from older attempts.'
        }
    }

    # The mouse itself.
    $devs = @(Get-KmdfMouseDevice)
    if ($devs.Count -gt 0) {
        $inst = Get-KmdfMouseInstanceId
        if (-not $inst) { $inst = $devs[0].PNPDeviceID }
        Write-Act -Status 'ok' -Message "Magic Mouse (PID 0323) is paired: $inst"
    }
    else {
        Write-Act -Status 'fail' -Message 'no Bluetooth device with PID 0323 found'
        $fatal += @{
            What = 'The Magic Mouse (2024, USB-C) was not found'
            Why  = 'This driver binds only the Apple Magic Mouse v3, product ID 0323, over Bluetooth. Windows does not currently see one.'
            Next = 'Pair the mouse: Settings > Bluetooth & devices > Add device > Bluetooth, and make sure it shows as Connected. Then run Setup-Community.cmd again.'
        }
    }

    # Blockers for a self-signed kernel driver.
    if (Test-KmdfSecureBootOn) {
        Write-Act -Status 'fail' -Message 'Secure Boot is ON'
        $fatal += @{
            What = 'Secure Boot is ON'
            Why  = 'With Secure Boot enabled Windows ignores test signing, so a self-signed kernel driver can never load. There is no software workaround.'
            Next = 'Restart into firmware/BIOS setup, set Secure Boot to Disabled, boot Windows, then run Setup-Community.cmd again. (Issue #23 tracks the paid EV-signing route that would avoid this.)'
        }
    }
    else {
        Write-Act -Status 'ok' -Message 'Secure Boot is off (or not present)'
    }

    if (Test-KmdfMemoryIntegrityOn) {
        Write-Act -Status 'fail' -Message 'Memory integrity (HVCI) is ON'
        $fatal += @{
            What = 'Memory integrity is ON'
            Why  = 'Core isolation / memory integrity refuses drivers that are not properly signed, including test-signed ones.'
            Next = 'Windows Security > Device security > Core isolation details > turn Memory integrity OFF, restart, then run Setup-Community.cmd again.'
        }
    }
    else {
        Write-Act -Status 'ok' -Message 'Memory integrity is off'
    }

    if (Test-KmdfFastStartupOn) {
        Write-Act -Status 'warn' -Message 'Fast Startup is ON - later, use Start > Power > Restart. "Shut down" does not fully restart Windows and test signing would not take effect'
    }
    else {
        Write-Act -Status 'ok' -Message 'Fast Startup is off'
    }

    Write-Act -Status 'info' -Message "progress file: $(Get-KmdfStatePath)"

    if ($fatal.Count -eq 0) {
        Write-Act -Status 'ok' -Message 'preflight passed'
        return
    }
    if ($DryRun) {
        Write-Act -Status 'warn' -Message "$($fatal.Count) preflight item(s) would stop a real run here; the remaining steps below are shown anyway"
        return
    }
    $f = $fatal[0]
    Stop-Wizard -Code $script:KmdfExitPreflight -What $f.What -Why $f.Why -Next $f.Next
}

# ---------------------------------------------------------------------------
# Step 2 - Certificate
# ---------------------------------------------------------------------------

function Invoke-KmdfPhase2 {
    $existing = Get-KmdfCommunityCertObject
    if ($existing) {
        Write-Act -Status 'skip' -Message "signing certificate already exists on this PC: $($existing.Thumbprint)"
        if (-not $DryRun) {
            Update-KmdfState -CertThumbprint $existing.Thumbprint -CertSubject $existing.Subject -LogEntry 'reused existing community certificate' | Out-Null
        }
        return
    }
    if ($DryRun) {
        Write-Act -Status 'plan' -Message "create a 10-year code-signing certificate '$($script:KmdfCommunitySubject)' in Local Machine > Personal (private key non-exportable, never leaves this PC)"
        Write-Act -Status 'plan' -Message 'add its public half to Local Machine > Trusted Root Certification Authorities'
        Write-Act -Status 'plan' -Message 'add its public half to Local Machine > Trusted Publishers'
        Write-Act -Status 'plan' -Message 'record its thumbprint in the progress file'
        return
    }

    Write-Act -Status 'info' -Message "creating code-signing certificate $($script:KmdfCommunitySubject)"
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject $script:KmdfCommunitySubject `
        -HashAlgorithm SHA256 `
        -KeyLength 2048 `
        -KeyExportPolicy NonExportable `
        -CertStoreLocation Cert:\LocalMachine\My `
        -NotAfter (Get-Date).AddYears(10)
    Write-Act -Status 'ok' -Message "certificate created: $($cert.Thumbprint)"

    $tmp = Join-Path $env:TEMP 'mm-community.cer'
    try {
        Export-Certificate -Cert $cert -FilePath $tmp | Out-Null
        Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
        Write-Act -Status 'ok' -Message 'trusted as a root certificate on this PC'
        Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
        Write-Act -Status 'ok' -Message 'trusted as a driver publisher on this PC'
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    Update-KmdfState -CertThumbprint $cert.Thumbprint -CertSubject $cert.Subject -LogEntry 'created community certificate' | Out-Null
    Write-Act -Status 'ok' -Message 'thumbprint recorded - the installer will now accept YOUR certificate, not anyone else you cannot have'
}

# ---------------------------------------------------------------------------
# Step 3 - TestSigning
# ---------------------------------------------------------------------------

function Invoke-KmdfPhase3 {
    if (Test-KmdfTestSigningOn) {
        Write-Act -Status 'skip' -Message 'test signing is already ON - no restart needed'
        return
    }
    if (Test-KmdfSecureBootOn) {
        Stop-Wizard -Code $script:KmdfExitPreflight `
            -What 'Secure Boot is ON, so test signing cannot be enabled' `
            -Why 'Windows accepts "bcdedit /set testsigning on" but ignores it while Secure Boot is enabled.' `
            -Next 'Restart into firmware/BIOS setup, set Secure Boot to Disabled, boot Windows, then run Setup-Community.cmd again.'
    }
    if ($DryRun) {
        Write-Act -Status 'plan' -Message 'run: bcdedit /set testsigning on'
        Write-Act -Status 'plan' -Message 'record step 3 as done, then stop with exit code 10 and ask you to RESTART'
        Write-Act -Status 'plan' -Message 'after the restart, running Setup-Community.cmd again continues at step 4'
        return
    }

    Write-Act -Status 'info' -Message 'running: bcdedit /set testsigning on'
    $out = & bcdedit.exe /set testsigning on 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Stop-Wizard -Code $script:KmdfExitError `
            -What 'Could not enable test signing' `
            -Why ("bcdedit failed: " + $out.Trim()) `
            -Next 'Make sure you are running as Administrator and that Secure Boot is OFF in firmware, then run Setup-Community.cmd again.'
    }
    Write-Act -Status 'ok' -Message 'test signing will be ON after the next restart'
    $script:NeedReboot = $true
}

# ---------------------------------------------------------------------------
# Step 4 - SignPackage
# ---------------------------------------------------------------------------

function Get-KmdfInf2CatPath {
    $cmd = Get-Command Inf2Cat.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits\10\bin", "$env:ProgramFiles\Windows Kits\10\bin")) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $hit = Get-ChildItem -Path $root -Filter 'Inf2Cat.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Set-KmdfSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Cert
    )
    # Timestamping is best-effort: it needs internet, and the signature is
    # valid without it for this route.
    $sig = $null
    try {
        $sig = Set-AuthenticodeSignature -FilePath $Path -Certificate $Cert -HashAlgorithm SHA256 `
            -TimestampServer 'http://timestamp.digicert.com' -ErrorAction Stop
    }
    catch { $sig = $null }
    if ($null -eq $sig -or $null -eq $sig.SignerCertificate) {
        Write-Act -Status 'warn' -Message "could not reach the timestamp server for $([System.IO.Path]::GetFileName($Path)) - signing without a timestamp"
        $sig = Set-AuthenticodeSignature -FilePath $Path -Certificate $Cert -HashAlgorithm SHA256
    }
    if ($null -eq $sig -or $null -eq $sig.SignerCertificate) {
        Stop-Wizard -Code $script:KmdfExitError `
            -What "Could not sign $([System.IO.Path]::GetFileName($Path))" `
            -Why 'Set-AuthenticodeSignature returned no signature. The certificate may have no usable private key.' `
            -Next 'Run: Setup-Community.cmd -Phase 2  to recreate the certificate, then run Setup-Community.cmd again.'
    }
    Write-Act -Status 'ok' -Message "signed $([System.IO.Path]::GetFileName($Path)) (status $($sig.Status))"
}

function Invoke-KmdfPhase4 {
    Assert-KmdfTestSigningActive

    $srcInf = Join-Path $Here $script:KmdfUniqueInf
    $srcSys = Join-Path $Here $script:KmdfUniqueSys
    $dstInf = Join-Path $script:StagingDir $script:KmdfUniqueInf
    $dstSys = Join-Path $script:StagingDir $script:KmdfUniqueSys
    $dstCat = Join-Path $script:StagingDir $script:KmdfUniqueCat

    if ($DryRun) {
        $cert = Get-KmdfCommunityCertObject
        if ($cert) { Write-Act -Status 'info' -Message "would sign with certificate $($cert.Thumbprint)" }
        else { Write-Act -Status 'info' -Message 'would sign with the certificate created in step 2' }
        Write-Act -Status 'plan' -Message "copy $($script:KmdfUniqueInf) and $($script:KmdfUniqueSys) to $($script:StagingDir) (the download folder is never modified)"
        $tool = Get-KmdfInf2CatPath
        if ($tool) { Write-Act -Status 'plan' -Message "build $($script:KmdfUniqueCat) with $tool /driver:$($script:StagingDir) /os:10_X64" }
        else { Write-Act -Status 'plan' -Message "build $($script:KmdfUniqueCat) with New-FileCatalog (Inf2Cat from the WDK is not installed; the fallback catalog works for test signing)" }
        Write-Act -Status 'plan' -Message 'sign the staged .sys and .cat with your certificate'
        return
    }

    $cert = Get-KmdfCommunityCertObject
    if (-not $cert) {
        Stop-Wizard -Code $script:KmdfExitError `
            -What 'No signing certificate was found on this PC' `
            -Why 'Step 2 creates it, but it is not in Local Machine > Personal any more.' `
            -Next 'Run: Setup-Community.cmd -Phase 2  to create it again, then run Setup-Community.cmd.'
    }

    if (-not (Test-Path -LiteralPath $script:StagingDir)) {
        New-Item -ItemType Directory -Path $script:StagingDir -Force | Out-Null
    }

    $alreadySigned = $false
    if ((Test-Path -LiteralPath $dstSys) -and (Test-Path -LiteralPath $dstCat)) {
        $alreadySigned = (Test-KmdfSignedByExpected -Path $dstSys) -and (Test-KmdfSignedByExpected -Path $dstCat)
    }
    if ($alreadySigned) {
        Write-Act -Status 'skip' -Message "already signed with $($cert.Thumbprint) in $($script:StagingDir)"
        return
    }

    Copy-Item -LiteralPath $srcInf -Destination $dstInf -Force
    Copy-Item -LiteralPath $srcSys -Destination $dstSys -Force
    Write-Act -Status 'ok' -Message "staged the package in $($script:StagingDir)"

    $stagedSha = Get-KmdfFileSha256 -Path $dstSys
    if ($stagedSha -ne $script:KmdfUnsignedSysSha) {
        Stop-Wizard -Code $script:KmdfExitPreflight `
            -What 'The staged driver does not match the published checksum' `
            -Why "Copied SHA256 $stagedSha, expected $($script:KmdfUnsignedSysSha)." `
            -Next 'Download the release ZIP again and extract it fresh, then run Setup-Community.cmd.'
    }
    Write-Act -Status 'ok' -Message "staged driver checksum verified ($($script:KmdfUnsignedSysSha))"

    Set-KmdfSignature -Path $dstSys -Cert $cert

    Remove-Item -LiteralPath $dstCat -Force -ErrorAction SilentlyContinue
    $tool = Get-KmdfInf2CatPath
    if ($tool) {
        Write-Act -Status 'info' -Message "building the catalog with $tool"
        & $tool "/driver:$($script:StagingDir)" /os:10_X64 2>&1 | ForEach-Object { Write-Act -Status 'info' -Message "Inf2Cat: $_" }
        if ($LASTEXITCODE -ne 0) {
            Stop-Wizard -Code $script:KmdfExitError `
                -What 'Inf2Cat could not build the driver catalog' `
                -Why "Inf2Cat exited $LASTEXITCODE." `
                -Next 'Run Setup-Community.cmd -Phase 4 again. If it keeps failing, re-extract the ZIP (a corrupted INF is the usual cause).'
        }
    }
    else {
        # Documented fallback: no WDK on the machine. New-FileCatalog produces a
        # catalog that satisfies pnputil while test signing is on. Users who hit
        # a pnputil catalog error install the WDK (for Inf2Cat) and re-run step 4.
        Write-Act -Status 'warn' -Message 'Inf2Cat (Windows Driver Kit) not installed - using the built-in New-FileCatalog fallback, which is fine while test signing is on'
        New-FileCatalog -Path @($dstInf, $dstSys) -CatalogFilePath $dstCat -CatalogVersion 2.0 | Out-Null
    }
    if (-not (Test-Path -LiteralPath $dstCat)) {
        Stop-Wizard -Code $script:KmdfExitError `
            -What 'The driver catalog was not created' `
            -Why "$dstCat does not exist after the catalog step." `
            -Next 'Run Setup-Community.cmd -Phase 4 again.'
    }
    Write-Act -Status 'ok' -Message "catalog built: $($script:KmdfUniqueCat)"

    Set-KmdfSignature -Path $dstCat -Cert $cert
    Update-KmdfState -LogEntry "signed package with $($cert.Thumbprint)" | Out-Null
}

# ---------------------------------------------------------------------------
# Step 5 - InstallDriver
# ---------------------------------------------------------------------------

function Test-KmdfDriverInstalled {
    $oems = @(Get-KmdfPublishedOemNames)
    if ($oems.Count -eq 0) { return $null }
    return $oems[0]
}

function Invoke-KmdfPhase5 {
    Assert-KmdfTestSigningActive

    if ($DryRun) {
        $published = @(Get-KmdfPublishedOemNames)
        if ($published.Count -gt 0) {
            Write-Act -Status 'info' -Message ("this package is already published as " + ($published -join ', ') + " - a real run would skip the install")
        }
        Write-Act -Status 'plan' -Message "check the staged package in $($script:StagingDir) against every safety gate (unique INF, unique service name, no live-driver filename, signed by YOUR certificate)"
        Write-Act -Status 'plan' -Message "run: pnputil /add-driver $(Join-Path $script:StagingDir $script:KmdfUniqueInf) /install"
        $inst = Get-KmdfMouseInstanceId
        if (-not $inst) { $inst = $script:KmdfHardwareId }
        Write-Act -Status 'plan' -Message "run: pnputil /restart-device `"$inst`""
        Write-Act -Status 'plan' -Message 'leave every other driver package, including the existing pointer driver, untouched'
        return
    }

    $existingOem = Test-KmdfDriverInstalled
    if ($existingOem -and (Get-KmdfStatePhase) -ge 5 -and $Phase -eq 0) {
        Write-Act -Status 'skip' -Message "driver package already installed as $existingOem"
        return
    }

    $problems = @(Get-KmdfPackageProblem -Directory $script:StagingDir -RequireSignature)
    if ($problems.Count -gt 0) {
        foreach ($p in $problems) { Write-Act -Status 'fail' -Message $p }
        Stop-Wizard -Code $script:KmdfExitError `
            -What 'The package failed a safety or signature check, so nothing was installed' `
            -Why $problems[0] `
            -Next 'Run: Setup-Community.cmd -Phase 4  to sign the package again, then run Setup-Community.cmd.'
    }

    $inf = Join-Path $script:StagingDir $script:KmdfUniqueInf
    Write-Act -Status 'info' -Message "running: pnputil /add-driver $inf /install"
    & pnputil.exe /add-driver $inf /install 2>&1 | ForEach-Object { Write-Act -Status 'info' -Message "pnputil: $_" }
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 3010) {
        Stop-Wizard -Code $script:KmdfExitError `
            -What 'Windows refused to install the driver package' `
            -Why "pnputil exited with code $rc. With a self-signed driver this is nearly always test signing not being active, Memory integrity still ON, or a catalog Windows would not accept." `
            -Next 'Check Windows Security > Device security > Memory integrity is OFF and restart; then run Setup-Community.cmd again. The full pnputil output is in C:\ProgramData\MagicMouseDriver\install.log.'
    }
    $oem = Test-KmdfDriverInstalled
    if ($oem) { Write-Act -Status 'ok' -Message "driver package installed as $oem" }
    else { Write-Act -Status 'ok' -Message 'pnputil reported success' }

    $inst = Get-KmdfMouseInstanceId
    if ($inst) {
        Write-Act -Status 'info' -Message "restarting the mouse device so the new driver attaches: $inst"
        & pnputil.exe /restart-device "$inst" 2>&1 | ForEach-Object { Write-Act -Status 'info' -Message "pnputil: $_" }
        Start-Sleep -Seconds 3
    }
    else {
        Write-Act -Status 'warn' -Message 'the mouse is not connected right now - turn it off and on (or re-pair) so the new driver attaches'
    }

    if ($rc -eq 3010) {
        Write-Act -Status 'warn' -Message 'Windows says a restart is needed to finish the install'
        $script:NeedReboot = $true
    }
}

# ---------------------------------------------------------------------------
# Step 6 - EnableTouch
# ---------------------------------------------------------------------------

function Invoke-KmdfPhase6 {
    $f1 = Join-Path $Here 'scripts\mm-f1-once.ps1'
    $watcherInstall = Join-Path $Here 'scripts\mm-auto-f1-watcher-install.ps1'

    if ($DryRun) {
        Write-Act -Status 'plan' -Message "run scripts\mm-f1-once.ps1 - sends the HID Feature report F1 02 01 that switches the mouse into multitouch mode (without it the mouse sends compact reports and two-finger scroll cannot work)"
        Write-Act -Status 'plan' -Message 'run scripts\mm-auto-f1-watcher-install.ps1 - registers the MmAutoF1Watcher scheduled task (SYSTEM, at startup) so scroll survives sleep, re-pairing and reboots'
        $task = Get-ScheduledTask -TaskName 'MmAutoF1Watcher' -ErrorAction SilentlyContinue
        if ($task) { Write-Act -Status 'info' -Message "scheduled task MmAutoF1Watcher already exists (state $($task.State)) - a real run would re-register it" }
        return
    }

    if (-not (Test-Path -LiteralPath $f1)) {
        Stop-Wizard -Code $script:KmdfExitPreflight `
            -What 'scripts\mm-f1-once.ps1 is missing' `
            -Why 'That script switches the mouse into multitouch mode; without it scroll cannot work.' `
            -Next 'Re-extract the whole release ZIP (including the scripts folder) and run Setup-Community.cmd again.'
    }

    Write-Act -Status 'info' -Message 'enabling multitouch reports on the mouse (HID Feature F1)'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f1 2>&1
    $f1rc = $LASTEXITCODE
    foreach ($line in @($out)) { Write-Act -Status 'info' -Message "mm-f1-once: $line" }
    if ($f1rc -eq 0) {
        Write-Act -Status 'ok' -Message 'multitouch enabled'
    }
    elseif ($f1rc -eq 2) {
        Write-Act -Status 'warn' -Message 'the mouse HID interface was not found - it is probably disconnected. Turn the mouse off and on, then run: Setup-Community.cmd -Phase 6'
    }
    else {
        Write-Act -Status 'warn' -Message "could not enable multitouch yet (exit $f1rc). This often succeeds after the mouse reconnects; the watcher below retries automatically."
    }

    if (-not (Test-Path -LiteralPath $watcherInstall)) {
        Write-Act -Status 'warn' -Message 'scripts\mm-auto-f1-watcher-install.ps1 is missing - scroll will work now but not after a reconnect. Re-extract the ZIP to fix.'
        return
    }
    $task = Get-ScheduledTask -TaskName 'MmAutoF1Watcher' -ErrorAction SilentlyContinue
    if ($task -and (Get-KmdfStatePhase) -ge 6 -and $Phase -eq 0) {
        Write-Act -Status 'skip' -Message "scheduled task MmAutoF1Watcher already installed (state $($task.State))"
        return
    }
    Write-Act -Status 'info' -Message 'installing the MmAutoF1Watcher scheduled task so scroll survives reconnects and reboots'
    $wout = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $watcherInstall 2>&1
    $wrc = $LASTEXITCODE
    foreach ($line in @($wout)) { Write-Act -Status 'info' -Message "watcher: $line" }
    if ($wrc -eq 0) {
        Write-Act -Status 'ok' -Message 'MmAutoF1Watcher installed and started'
    }
    else {
        Write-Act -Status 'warn' -Message "the watcher task did not install (exit $wrc). Scroll can still work now; after a reconnect run scripts\mm-f1-once.ps1 or Setup-Community.cmd -Phase 6."
    }
}

# ---------------------------------------------------------------------------
# Step 7 - Verify
# ---------------------------------------------------------------------------

function Invoke-KmdfPhase7 {
    $hardFail = @()
    $soft = @()

    # 1. Service
    $svc = $null
    try { $svc = Get-CimInstance -ClassName Win32_SystemDriver -Filter "Name='$($script:KmdfServiceName)'" -ErrorAction Stop } catch { $svc = $null }
    if ($svc) {
        Write-Act -Status 'ok' -Message "service $($script:KmdfServiceName) present (State=$($svc.State) Start=$($svc.StartMode))"
    }
    elseif (Test-Path -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$($script:KmdfServiceName)") {
        Write-Act -Status 'ok' -Message "service $($script:KmdfServiceName) is registered"
    }
    else {
        Write-Act -Status 'fail' -Message "service $($script:KmdfServiceName) is not registered"
        $hardFail += 'the driver service is not registered, so the driver was never installed'
    }

    # 2. Driver package
    $oems = @(Get-KmdfPublishedOemNames)
    if ($oems.Count -gt 0) {
        Write-Act -Status 'ok' -Message ("pnputil lists the driver package as " + ($oems -join ', '))
    }
    else {
        Write-Act -Status 'fail' -Message 'pnputil /enum-drivers does not list MagicMouseDriver-kmdf-204-scroll.inf'
        $hardFail += 'the driver package is not in the Windows driver store'
    }

    # 3. PnP node
    $devs = @(Get-KmdfMouseDevice)
    if ($devs.Count -eq 0) {
        Write-Act -Status 'warn' -Message 'the mouse is not connected right now, so its status cannot be read'
        $soft += 'the mouse was not connected during this check'
    }
    foreach ($d in $devs) {
        $code = $d.ConfigManagerErrorCode
        $msg = "$($d.PNPDeviceID) status=$($d.Status) problem=$code"
        if ([int]$code -eq 0) { Write-Act -Status 'ok' -Message $msg }
        else {
            Write-Act -Status 'fail' -Message $msg
            $hardFail += "Windows reports device problem code $code on the mouse (Device Manager shows the detail)"
        }
    }

    # 4. Test signing
    if (Test-KmdfTestSigningOn) { Write-Act -Status 'ok' -Message 'test signing is ON' }
    else {
        Write-Act -Status 'fail' -Message 'test signing is OFF - Windows will not keep this driver loaded'
        $hardFail += 'test signing is off (Secure Boot ON is the usual cause)'
    }

    # 5. Watcher task
    $task = Get-ScheduledTask -TaskName 'MmAutoF1Watcher' -ErrorAction SilentlyContinue
    if ($task) { Write-Act -Status 'ok' -Message "scheduled task MmAutoF1Watcher present (state $($task.State))" }
    else {
        Write-Act -Status 'warn' -Message 'scheduled task MmAutoF1Watcher is missing - scroll may stop working after a reconnect'
        $soft += 'the reconnect watcher is not installed (run Setup-Community.cmd -Phase 6)'
    }

    # 6. Driver diagnostics
    $diag = Get-KmdfDiag
    Write-Host ''
    Write-Host '  Driver diagnostics (HKLM\SYSTEM\CurrentControlSet\Services\MagicMouseDriver204Scroll\Diag):' -ForegroundColor Gray
    if (-not $diag['Present']) {
        Write-Act -Status 'warn' -Message 'no Diag values yet - the driver has not run. Connect the mouse, wait 5 seconds, then run: Setup-Community.cmd -Phase 7'
        $soft += 'the driver had not published diagnostics yet'
    }
    else {
        Write-Act -Status 'info' -Message "SdpPatchSuccess = $($diag['SdpPatchSuccess'])   (>0 means the driver patched the Bluetooth service record so Windows asks for multitouch)"
        Write-Act -Status 'info' -Message "LastAclReceived = $($diag['LastAclReceived'])   (14 or more = multitouch reports are flowing; 9 = compact mode, scroll will NOT work)"
        Write-Act -Status 'info' -Message "ScrollStep      = $($diag['ScrollStep'])   (scroll sensitivity; tune with scripts\mm-scroll-tune.ps1)"
        $acl = $diag['LastAclReceived']
        if ($null -eq $acl) {
            $soft += 'LastAclReceived is not published yet'
        }
        elseif ([int]$acl -ge 14) {
            Write-Act -Status 'ok' -Message 'multitouch reports are flowing - this is what a working install looks like'
        }
        elseif ([int]$acl -eq 9) {
            Write-Act -Status 'warn' -Message 'the mouse is in compact 9-byte mode, so two-finger scroll will not work yet'
            $soft += 'the mouse fell back to compact mode (LastAclReceived=9): turn the mouse off and on, then run Setup-Community.cmd -Phase 6'
        }
        else {
            Write-Act -Status 'warn' -Message "LastAclReceived = $acl - not the healthy 14+ value yet"
            $soft += "LastAclReceived is $acl; turn the mouse off and on, then run Setup-Community.cmd -Phase 6"
        }
    }

    if ($DryRun) {
        Write-Act -Status 'plan' -Message 'print a PASS/FAIL summary and, on a real run, write C:\ProgramData\MagicMouseDriver\RESULT.txt'
        return
    }

    Write-Host ''
    if ($hardFail.Count -eq 0) {
        Write-Host '===========================================================================' -ForegroundColor Green
        Write-Host ' RESULT: PASS - the driver is installed and running' -ForegroundColor Green
        Write-Host '===========================================================================' -ForegroundColor Green
        Write-KmdfResult -Status 'PASS' -Detail "community self-signed install verified; LastAclReceived=$($diag['LastAclReceived'])"
    }
    else {
        Write-Host '===========================================================================' -ForegroundColor Red
        Write-Host ' RESULT: FAIL - the driver is not working' -ForegroundColor Red
        Write-Host '===========================================================================' -ForegroundColor Red
        foreach ($h in $hardFail) { Write-Host "  - $h" -ForegroundColor Red }
        Write-KmdfResult -Status 'FAIL' -Detail ($hardFail -join '; ')
    }
    if ($soft.Count -gt 0) {
        Write-Host ''
        Write-Host ' Things to look at:' -ForegroundColor Yellow
        foreach ($s in $soft) { Write-Host "  - $s" -ForegroundColor Yellow }
    }

    Write-Host ''
    Write-Host ' Now test it physically:' -ForegroundColor Cyan
    Write-Host '   - Two fingers on the mouse surface, slide up and down: the page must scroll.'
    Write-Host '   - ONE finger sliding on the surface must NOT scroll (that would be a bug).'
    Write-Host '   - Pointer movement and left/right click must still work exactly as before.'
    Write-Host ''
    Write-Host ' Please report what happened - working or not - in COMMUNITY-TESTING.md' -ForegroundColor Cyan
    Write-Host ' (open an issue on the project repository and paste:' -ForegroundColor Cyan
    Write-Host "   C:\ProgramData\MagicMouseDriver\RESULT.txt and install.log)." -ForegroundColor Cyan
    Write-Host ''
    Write-Host ' Reminder: this PC is now in Windows Test Mode (watermark bottom-right).' -ForegroundColor Yellow
    Write-Host ' To undo: run Uninstall-KMDF.cmd, then: bcdedit /set testsigning off, then restart.' -ForegroundColor Yellow
    Write-Host ' Issue #23 tracks the EV/attestation signing that would remove Test Mode.' -ForegroundColor Yellow

    if ($hardFail.Count -gt 0) {
        exit $script:KmdfExitError
    }
}

# ---------------------------------------------------------------------------
# -Status
# ---------------------------------------------------------------------------

function Show-KmdfStatus {
    $path = Get-KmdfStatePath
    Write-Host ''
    Write-Host 'Magic Mouse v3 scroll driver - setup status' -ForegroundColor Cyan
    Write-Host "Progress file : $path"
    $st = Read-KmdfState
    if ($null -eq $st) {
        Write-Host 'Progress      : setup has not started (no saved progress)' -ForegroundColor Yellow
        Write-Host "Next step     : 1 of $($script:KmdfPhaseCount) - $(Get-KmdfPhaseName 1)"
        Write-Host ''
        Write-Host 'Run Setup-Community.cmd to begin.' -ForegroundColor Cyan
        return
    }
    $done = [int]$st['phase']
    if ($done -le 0) {
        Write-Host 'Progress      : started, no step completed yet' -ForegroundColor Yellow
    }
    else {
        Write-Host "Progress      : $done of $($script:KmdfPhaseCount) completed (last: $(Get-KmdfPhaseName $done))" -ForegroundColor Green
    }
    if ($done -ge $script:KmdfPhaseCount) {
        Write-Host 'Next step     : none - setup is complete. Re-run with -Phase 7 to re-check.'
    }
    else {
        Write-Host "Next step     : $($done + 1) of $($script:KmdfPhaseCount) - $(Get-KmdfPhaseName ($done + 1))"
    }
    $thumb = $st['certThumbprint']
    if ($thumb) {
        Write-Host "Certificate   : $thumb"
        Write-Host "Subject       : $($st['certSubject'])"
    }
    else {
        Write-Host 'Certificate   : none recorded yet'
    }
    if ($st['driverSha256']) { Write-Host "Driver SHA256 : $($st['driverSha256'])" }
    Write-Host "Started (UTC) : $($st['startedUtc'])"
    Write-Host "Updated (UTC) : $($st['updatedUtc'])"
    $expected = Resolve-KmdfExpectedThumb
    Write-Host "Expected signer: $($expected.Thumbprint) [$($expected.Source)]"
    $log = @($st['log'])
    if ($log.Count -gt 0) {
        Write-Host 'Recent events :'
        foreach ($line in ($log | Select-Object -Last 5)) { Write-Host "  $line" }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if ($Status) {
    Show-KmdfStatus
    exit $script:KmdfExitOk
}

if (-not (Test-KmdfIsAdmin) -and -not $NoElevate -and -not $DryRun) {
    Write-Host 'This needs Administrator rights. Approve the Windows prompt to continue.' -ForegroundColor Yellow
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-NoElevate')
    if ($Yes)          { $relaunch += '-Yes' }
    if ($Phase -gt 0)  { $relaunch += @('-Phase', "$Phase") }
    try {
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunch -Verb RunAs -Wait -PassThru
        exit $proc.ExitCode
    }
    catch {
        Write-Host 'Administrator approval was refused. Nothing was changed.' -ForegroundColor Red
        exit $script:KmdfExitDeclined
    }
}

Write-Host ''
Write-Host "Magic Mouse v3 (2024 USB-C) two-finger scroll - guided setup, $($script:KmdfPhaseCount) steps" -ForegroundColor Cyan
Write-Host "Driver $($script:KmdfDriverVersion) - self-signed on this PC. Issue #23 tracks the no-Test-Mode route." -ForegroundColor Gray
if ($DryRun) {
    Write-Host 'REHEARSAL (-DryRun): every step below is only described. NOTHING is changed.' -ForegroundColor Magenta
}

# Work out which steps to run.
$done = 0
if ($DryRun) {
    $plan = 1..$script:KmdfPhaseCount
    $recorded = Get-KmdfStatePhase
    if ($recorded -gt 0) {
        Write-Host "Saved progress says $recorded of $($script:KmdfPhaseCount) steps are done; a real run would resume at step $([Math]::Min($recorded + 1, $script:KmdfPhaseCount))." -ForegroundColor Gray
    }
}
elseif ($Phase -gt 0) {
    $plan = @($Phase)
    Write-Host "Running only step $Phase ($(Get-KmdfPhaseName $Phase)) as requested." -ForegroundColor Yellow
}
else {
    $done = Get-KmdfStatePhase
    if ($done -ge $script:KmdfPhaseCount) {
        Write-Host 'Setup is already complete - re-checking the install (step 7).' -ForegroundColor Green
        $plan = @(7)
    }
    elseif ($done -gt 0) {
        Write-Host "Resuming: steps 1-$done are already done, continuing at step $($done + 1)." -ForegroundColor Green
        $plan = ($done + 1)..$script:KmdfPhaseCount
    }
    else {
        $plan = 1..$script:KmdfPhaseCount
    }
}

# If step 3 is behind us, test signing must really be active before we sign or
# install anything. This is the single most common real-world failure.
if (-not $DryRun -and $done -ge 3 -and ($plan | Where-Object { $_ -ge 4 })) {
    $script:CurrentStep = 3
    Assert-KmdfTestSigningActive
}

# Consent before the first change. Reading files and the registry in step 1
# changes nothing, so the prompt comes just before step 2.
if ($plan | Where-Object { $_ -ge 2 -and $_ -le 6 }) {
    Show-KmdfConsent -Plan $plan
}

if (-not $DryRun) {
    Update-KmdfState -LogEntry ("run started, plan " + ($plan -join ',')) | Out-Null
}

try {
    foreach ($n in $plan) {
        $script:NeedReboot = $false
        Write-StepHeader -Number $n
        & "Invoke-KmdfPhase$n" | Out-Null

        if (-not $DryRun) {
            $recordPhase = $n
            if ($Phase -gt 0) {
                # A single re-run must not rewind progress.
                $current = Get-KmdfStatePhase
                if ($current -gt $n) { $recordPhase = $current }
            }
            Update-KmdfState -Phase $recordPhase -LogEntry "step $n $(Get-KmdfPhaseName $n) complete" | Out-Null
        }

        if ($script:NeedReboot) {
            Write-Host ''
            Write-Host '***************************************************************************' -ForegroundColor Yellow
            Write-Host '*  RESTART YOUR PC NOW                                                    *' -ForegroundColor Yellow
            Write-Host '*                                                                         *' -ForegroundColor Yellow
            Write-Host '*  Use Start > Power > Restart (NOT Shut down - Fast Startup would skip    *' -ForegroundColor Yellow
            Write-Host '*  the real restart and test signing would not take effect).               *' -ForegroundColor Yellow
            Write-Host '*                                                                         *' -ForegroundColor Yellow
            Write-Host '*  After the PC comes back, run Setup-Community.cmd AGAIN.                 *' -ForegroundColor Yellow
            Write-Host "*  It continues at step $([Math]::Min($n + 1, $script:KmdfPhaseCount)) of $($script:KmdfPhaseCount) - finished steps are not repeated.        *" -ForegroundColor Yellow
            Write-Host '***************************************************************************' -ForegroundColor Yellow
            Write-Host ''
            if (-not $DryRun) {
                Write-KmdfResult -Status 'PENDING' -Detail "step $n done; restart required, then run Setup-Community.cmd again"
            }
            exit $script:KmdfExitReboot
        }
    }
}
catch {
    $msg = "$($_.Exception.Message)"
    Write-Act -Status 'fail' -Message $msg
    if ($script:KmdfLogToFile) {
        Add-Content -LiteralPath $script:KmdfLog -Value ("[detail] " + ($_ | Out-String)) -Encoding UTF8
    }
    Stop-Wizard -Code $script:KmdfExitError `
        -What "Step $($script:CurrentStep) ($(Get-KmdfPhaseName $script:CurrentStep)) hit an unexpected error" `
        -Why $msg `
        -Next "Run Setup-Community.cmd again. If it fails the same way, open an issue with C:\ProgramData\MagicMouseDriver\install.log attached."
}

Write-Host ''
if ($DryRun) {
    Write-Host "Rehearsal finished: all $($script:KmdfPhaseCount) steps described, nothing changed." -ForegroundColor Magenta
    Write-Host 'Run Setup-Community.cmd without -DryRun when you are ready.' -ForegroundColor Magenta
}
elseif ($Phase -gt 0) {
    Write-Host "Step $Phase ($(Get-KmdfPhaseName $Phase)) finished." -ForegroundColor Green
}
else {
    Write-Host "All $($script:KmdfPhaseCount) steps finished." -ForegroundColor Green
}
exit $script:KmdfExitOk
