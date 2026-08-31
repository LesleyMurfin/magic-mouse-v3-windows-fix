# Shared constants for the KMDF 2.0.4 unique-package path.
# Dot-sourced by Install-KMDF.ps1 and Freeze-KmdfArtifact.ps1.
# Not meant to be run directly.
#
# Install story is signed pnputil /add-driver only.
# Never Copy-Item onto C:\Windows\System32\drivers or DriverStore.
# Never delete the Apr 30 oem16 / MagicMouseDriver.inf package.

$script:KmdfDataDir     = 'C:\ProgramData\MagicMouseDriver'
$script:KmdfLog         = Join-Path $script:KmdfDataDir 'install.log'
$script:KmdfResult      = Join-Path $script:KmdfDataDir 'RESULT.txt'
$script:KmdfServiceName = 'MagicMouseDriver'
$script:KmdfPidPattern  = 'BTHENUM\\\{00001124.*PID&0323'

# Unique package identity (must not match failed oem26 or Apr 30 oem16).
$script:KmdfUniqueInf     = 'MagicMouseDriver-kmdf-204-scroll.inf'
$script:KmdfUniqueCat     = 'MagicMouseDriver-kmdf-204-scroll.cat'
$script:KmdfUniqueSys     = 'MagicMouseDriver-kmdf-204-scroll.sys'
$script:KmdfArtifactGlob  = 'MagicMouseDriver-kmdf-2.0.4-scroll-*.sys'
$script:KmdfLiveSysName   = 'MagicMouseDriver.sys'   # Apr 30 restore name — do not ship a second copy
$script:KmdfRetiredInf    = 'MagicMouseDriver.inf'   # failed oem26 identity — do not pnputil

# Human sign cert (private key on the PC, not in git). Never commit PFX.
$script:KmdfSignThumb = '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'

# Freeze-hash gate — refuse these as THIS package.
$script:KmdfShaApr30     = 'AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B'
$script:KmdfShaMay20     = '559B136AEB869D1B85EE21583BB7BFD72782A31EE476A2622014D87CE6762F30'
$script:KmdfShaFailed204 = '845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3'
$script:KmdfArtifactApr30 = 'MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys'
$script:KmdfArtifactMay20 = 'MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys'
$script:KmdfPathAShipBlocker = 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys'

function Initialize-KmdfDataDir {
    if (-not (Test-Path -LiteralPath $script:KmdfDataDir)) {
        New-Item -ItemType Directory -Path $script:KmdfDataDir -Force | Out-Null
    }
}

function Write-KmdfLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'HEAD')]
        [string]$Level = 'INFO'
    )
    Initialize-KmdfDataDir
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    Add-Content -LiteralPath $script:KmdfLog -Value $line -Encoding UTF8
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN'  { 'Yellow' }
        'OK'    { 'Green' }
        'HEAD'  { 'Cyan' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
}

function Write-KmdfResult {
    param(
        [Parameter(Mandatory)][ValidateSet('PASS', 'FAIL', 'PENDING')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    Initialize-KmdfDataDir
    $nl = [Environment]::NewLine
    $body = "MagicMouseDriver KMDF 2.0.4 unique package (PID 0323)$nl" +
        "Status : $Status$nl" +
        "Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$nl" +
        "Detail : $Detail$nl" +
        "Log    : $script:KmdfLog"
    Set-Content -LiteralPath $script:KmdfResult -Value $body -Encoding UTF8
    $level = 'WARN'
    if ($Status -eq 'FAIL') { $level = 'ERROR' }
    elseif ($Status -eq 'PASS') { $level = 'OK' }
    Write-KmdfLog -Message "RESULT=$Status $Detail" -Level $level
}

function Test-KmdfIsAdmin {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-KmdfFileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-KmdfForbiddenSys {
    param([Parameter(Mandatory)][string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -eq $script:KmdfLiveSysName) {
        Write-KmdfLog -Message "Refusing live-named $name — that filename is the Apr 30 restore file. Use $script:KmdfUniqueSys / $script:KmdfArtifactGlob." -Level 'ERROR'
        return $true
    }
    if ($name -like 'applewirelessmouse*' -or $name -eq $script:KmdfPathAShipBlocker) {
        Write-KmdfLog -Message "Refusing PATH-A package $name — SHIPBLOCKER BSOD. Never the 0323 product." -Level 'ERROR'
        return $true
    }
    if ($name -like '*may20-pointerdead*' -or $name -eq $script:KmdfArtifactMay20) {
        Write-KmdfLog -Message "Refusing May 20 pointer-dead artifact $name." -Level 'ERROR'
        return $true
    }
    if ($name -like '*pr3-activate*' -or $name -like '*activate-204*') {
        Write-KmdfLog -Message "Refusing unsigned activate artifact $name." -Level 'ERROR'
        return $true
    }
    $sha = Get-KmdfFileSha256 -Path $Path
    if ($sha -eq $script:KmdfShaMay20) {
        Write-KmdfLog -Message "Refusing May 20 SHA $sha — pointer-dead." -Level 'ERROR'
        return $true
    }
    if ($sha -eq $script:KmdfShaFailed204) {
        Write-KmdfLog -Message "Refusing failed 2.0.4 SHA $sha (oem26 / Event 41). Rebuild and freeze a new hash." -Level 'ERROR'
        return $true
    }
    if ($sha -eq $script:KmdfShaApr30) {
        Write-KmdfLog -Message "Refusing Apr 30 SHA $sha as this package — that binary stays oem16 / MagicMouseDriver.sys for restore." -Level 'ERROR'
        return $true
    }
    return $false
}

function Test-KmdfSignedByThumb {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Thumb
    )
    $sig = Get-AuthenticodeSignature -FilePath $Path
    if ($null -eq $sig -or $null -eq $sig.SignerCertificate) {
        Write-KmdfLog -Message "$Path is not Authenticode-signed." -Level 'ERROR'
        return $false
    }
    $got = $sig.SignerCertificate.Thumbprint.ToUpperInvariant()
    $want = $Thumb.ToUpperInvariant()
    if ($got -ne $want) {
        Write-KmdfLog -Message "$Path signed by $got — required thumb is $want (16940C0F…)." -Level 'ERROR'
        return $false
    }
    if ($sig.Status -ne 'Valid' -and $sig.Status -ne 'UnknownError') {
        Write-KmdfLog -Message "$Path signature status $($sig.Status)." -Level 'WARN'
    }
    Write-KmdfLog -Message "$Path signed by $got status=$($sig.Status)" -Level 'OK'
    return $true
}
