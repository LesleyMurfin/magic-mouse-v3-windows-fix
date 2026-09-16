# Shared constants and helpers for the KMDF 2.0.4 unique-package path.
# Dot-sourced by Setup-Community.ps1, Install-KMDF.ps1 and Freeze-KmdfArtifact.ps1.
# Not meant to be run directly.
#
# Install story is signed pnputil /add-driver only.
# Never Copy-Item onto C:\Windows\System32\drivers or DriverStore.
# Never delete the Apr 30 oem16 / MagicMouseDriver.inf package.

# Data dir can be redirected for tests/harnesses with MM_KMDF_DATA_DIR.
# Nothing in this file ever touches the driver, the service or a .sys because
# of that variable - it only moves the log / state / staging location.
if ($env:MM_KMDF_DATA_DIR) {
    $script:KmdfDataDir = $env:MM_KMDF_DATA_DIR
}
else {
    $script:KmdfDataDir = 'C:\ProgramData\MagicMouseDriver'
}
$script:KmdfLog         = Join-Path $script:KmdfDataDir 'install.log'
$script:KmdfResult      = Join-Path $script:KmdfDataDir 'RESULT.txt'
$script:KmdfServiceName = 'MagicMouseDriver204Scroll'
$script:KmdfPidPattern  = 'BTHENUM\\\{00001124.*PID&0323'

# Where Setup-Community.ps1 stages the package it signs. The downloaded ZIP
# folder is never written to, so re-running the wizard is deterministic and a
# read-only Downloads folder still works.
$script:KmdfPackageDir  = Join-Path $script:KmdfDataDir 'package'

# Unique package identity (must not match failed oem26 or Apr 30 oem16).
$script:KmdfUniqueInf     = 'MagicMouseDriver-kmdf-204-scroll.inf'
$script:KmdfUniqueCat     = 'MagicMouseDriver-kmdf-204-scroll.cat'
$script:KmdfUniqueSys     = 'MagicMouseDriver-kmdf-204-scroll.sys'
$script:KmdfArtifactGlob  = 'MagicMouseDriver-kmdf-2.0.4-scroll-*.sys'
$script:KmdfLiveSysName   = 'MagicMouseDriver.sys'   # Apr 30 restore name — do not ship a second copy
$script:KmdfRetiredInf    = 'MagicMouseDriver.inf'   # failed oem26 identity — do not pnputil

# Shipped 2.0.4.3 payload. The ZIP carries this .sys UNSIGNED; every user signs
# it locally with their own machine-generated certificate (Setup-Community.ps1).
$script:KmdfDriverVersion    = '2.0.4.3'
$script:KmdfDriverVerLine    = '09/15/2026,2.0.4.3'
$script:KmdfDriverVerMinimum = '2.0.4.1'             # 2.0.4.0 == failed oem26 / PR #3 identity
$script:KmdfUnsignedSysSha   = '08E91E37AF3B7B9A56E793ADB876BA48FBD61DDFEE446C89A6A1751CABABD6AC'
$script:KmdfUnsignedSysBytes = 25600
$script:KmdfHardwareId       = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'

# Certificate trust model.
#
# There is no shipped signature and no shared private key. The thumbprint this
# package must be signed with is resolved at run time, in this order:
#   1. $env:MM_KMDF_SIGN_THUMB          - maintainer / CI override
#   2. certThumbprint in the state file - the cert THIS machine generated
#                                         (the normal community case)
#   3. $script:KmdfSignThumbLegacy      - last resort, so the maintainer's own
#                                         pre-existing scripts keep working
# See Get-KmdfExpectedThumb / Test-KmdfSignedByExpected.
#
# Legacy maintainer cert (private key on one PC, never in git, never shipped).
# Community users cannot and must not have this key.
$script:KmdfSignThumbLegacy = '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'

# Wizard state file (owned by Setup-Community.ps1; read by nothing else).
$script:KmdfStateSchema = 1
if ($env:MM_KMDF_STATE_FILE) {
    $script:KmdfStateFile = $env:MM_KMDF_STATE_FILE
}
else {
    $script:KmdfStateFile = Join-Path $script:KmdfDataDir 'community-setup-state.json'
}

# Phase numbering - keep in lockstep with COMMUNITY-TESTING.md and the wizard.
$script:KmdfPhaseNames = @(
    'Preflight',      # 1
    'Certificate',    # 2
    'TestSigning',    # 3
    'SignPackage',    # 4
    'InstallDriver',  # 5
    'EnableTouch',    # 6
    'Verify'          # 7
)
$script:KmdfPhaseCount = $script:KmdfPhaseNames.Count

# Exit codes shared with Setup-Community.cmd / callers.
$script:KmdfExitOk       = 0
$script:KmdfExitReboot   = 10
$script:KmdfExitPreflight = 20
$script:KmdfExitDeclined = 30
$script:KmdfExitError    = 40

# Freeze-hash gate — refuse these as THIS package.
$script:KmdfShaApr30     = 'AD5D244B176D650961594EDED153C46F9A52004C424DABFD86E50844E447546B'
$script:KmdfShaMay20     = '559B136AEB869D1B85EE21583BB7BFD72782A31EE476A2622014D87CE6762F30'
$script:KmdfShaFailed204 = '845435CEF0DABAF2FD0638717E44F6A774556CECE47F00C8B12328B5B2B3FDE3'
$script:KmdfArtifactApr30 = 'MagicMouseDriver-kmdf-apr30-pointer-AD5D244B.sys'
$script:KmdfArtifactMay20 = 'MagicMouseDriver-kmdf-may20-pointerdead-559B136A.sys'
$script:KmdfPathAShipBlocker = 'applewirelessmouse-patched-pathA-SHIPBLOCKER.sys'

# Set to $false by -DryRun so a rehearsal writes no file anywhere.
$script:KmdfLogToFile = $true

function Get-KmdfPhaseName {
    param([Parameter(Mandatory)][int]$Phase)
    if ($Phase -lt 1 -or $Phase -gt $script:KmdfPhaseCount) { return "Phase$Phase" }
    return $script:KmdfPhaseNames[$Phase - 1]
}

function Initialize-KmdfDataDir {
    if (-not $script:KmdfLogToFile) { return }
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
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts][$Level] $Message"
    if ($script:KmdfLogToFile) {
        Initialize-KmdfDataDir
        Add-Content -LiteralPath $script:KmdfLog -Value $line -Encoding UTF8
    }
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
    $level = 'WARN'
    if ($Status -eq 'FAIL') { $level = 'ERROR' }
    elseif ($Status -eq 'PASS') { $level = 'OK' }
    if (-not $script:KmdfLogToFile) {
        Write-KmdfLog -Message "RESULT=$Status $Detail" -Level $level
        return
    }
    Initialize-KmdfDataDir
    $nl = [Environment]::NewLine
    $body = "MagicMouseDriver KMDF $($script:KmdfDriverVersion) unique package (PID 0323)$nl" +
        "Status : $Status$nl" +
        "Time   : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')$nl" +
        "Detail : $Detail$nl" +
        "Log    : $script:KmdfLog"
    Set-Content -LiteralPath $script:KmdfResult -Value $body -Encoding UTF8
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

# ---------------------------------------------------------------------------
# Wizard state file
# ---------------------------------------------------------------------------

function Get-KmdfStatePath {
    return $script:KmdfStateFile
}

function New-KmdfState {
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    return [ordered]@{
        schema         = $script:KmdfStateSchema
        phase          = 0
        certThumbprint = ''
        certSubject    = ''
        driverSha256   = ''
        startedUtc     = $now
        updatedUtc     = $now
        log            = @()
    }
}

# Returns an ordered hashtable, or $null when there is no usable state.
# A truncated / hand-edited / empty file is reported and treated as "no state"
# rather than crashing the wizard - the phases re-detect reality anyway.
function Read-KmdfState {
    $path = Get-KmdfStatePath
    if (-not (Test-Path -LiteralPath $path)) { return $null }

    $raw = $null
    try { $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop }
    catch {
        Write-KmdfLog -Message "Cannot read state file $path ($_). Treating setup as not started." -Level 'WARN'
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($raw)) {
        Write-KmdfLog -Message "State file $path is empty (interrupted write). Treating setup as not started." -Level 'WARN'
        return $null
    }

    $obj = $null
    try { $obj = $raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        Write-KmdfLog -Message "State file $path is not valid JSON (interrupted or edited). Treating setup as not started; the phases re-detect what is already done." -Level 'WARN'
        return $null
    }
    if ($null -eq $obj) { return $null }

    $st = New-KmdfState
    foreach ($key in @('schema', 'phase', 'certThumbprint', 'certSubject', 'driverSha256', 'startedUtc', 'updatedUtc', 'log')) {
        $prop = $obj.PSObject.Properties[$key]
        if (-not $prop) { continue }
        $val = $prop.Value
        if ($null -eq $val) { continue }
        switch ($key) {
            'schema' { try { $st[$key] = [int]$val } catch { } }
            'phase'  { try { $st[$key] = [int]$val } catch { } }
            'log'    { $st[$key] = @($val) }
            default  { $st[$key] = [string]$val }
        }
    }
    if ($st['phase'] -lt 0) { $st['phase'] = 0 }
    if ($st['phase'] -gt $script:KmdfPhaseCount) { $st['phase'] = $script:KmdfPhaseCount }
    if ($st['schema'] -ne $script:KmdfStateSchema) {
        Write-KmdfLog -Message "State file schema $($st['schema']) is not $($script:KmdfStateSchema). Starting from phase 1." -Level 'WARN'
        $st['phase'] = 0
        $st['schema'] = $script:KmdfStateSchema
    }
    $st['certThumbprint'] = $st['certThumbprint'].ToUpperInvariant()
    return $st
}

# Atomic: full JSON goes to a temp file first, then one Move-Item replaces the
# real file. An interruption can therefore never leave truncated JSON behind.
function Write-KmdfState {
    param([Parameter(Mandatory)]$State)
    $path = Get-KmdfStatePath
    $dir = Split-Path -Parent $path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $State['updatedUtc'] = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $json = ([pscustomobject]$State) | ConvertTo-Json -Depth 4
    $tmp = "$path.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $State
}

function Update-KmdfState {
    [CmdletBinding()]
    param(
        [int]$Phase = -1,
        [string]$CertThumbprint,
        [string]$CertSubject,
        [string]$DriverSha256,
        [string]$LogEntry
    )
    $st = Read-KmdfState
    if ($null -eq $st) { $st = New-KmdfState }
    if ($Phase -ge 0) { $st['phase'] = $Phase }
    if ($PSBoundParameters.ContainsKey('CertThumbprint') -and $CertThumbprint) {
        $st['certThumbprint'] = $CertThumbprint.ToUpperInvariant()
    }
    if ($PSBoundParameters.ContainsKey('CertSubject') -and $CertSubject) { $st['certSubject'] = $CertSubject }
    if ($PSBoundParameters.ContainsKey('DriverSha256') -and $DriverSha256) {
        $st['driverSha256'] = $DriverSha256.ToUpperInvariant()
    }
    if ($PSBoundParameters.ContainsKey('LogEntry') -and $LogEntry) {
        $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $entries = @($st['log']) + @("$ts $LogEntry")
        if ($entries.Count -gt 40) { $entries = $entries[($entries.Count - 40)..($entries.Count - 1)] }
        $st['log'] = $entries
    }
    return (Write-KmdfState -State $st)
}

function Get-KmdfStatePhase {
    $st = Read-KmdfState
    if ($null -eq $st) { return 0 }
    return [int]$st['phase']
}

# ---------------------------------------------------------------------------
# Certificate resolution — the community fix. No hard-pinned thumbprint.
# ---------------------------------------------------------------------------

function Resolve-KmdfExpectedThumb {
    if ($env:MM_KMDF_SIGN_THUMB) {
        $t = ($env:MM_KMDF_SIGN_THUMB -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        if ($t) {
            return [PSCustomObject]@{ Thumbprint = $t; Source = 'MM_KMDF_SIGN_THUMB environment override' }
        }
    }
    $st = Read-KmdfState
    if ($null -ne $st -and $st['certThumbprint']) {
        return [PSCustomObject]@{
            Thumbprint = $st['certThumbprint']
            Source     = "certificate generated on this PC (state file $(Get-KmdfStatePath))"
        }
    }
    return [PSCustomObject]@{
        Thumbprint = $script:KmdfSignThumbLegacy
        Source     = 'last-resort maintainer certificate constant'
    }
}

function Get-KmdfExpectedThumb {
    return (Resolve-KmdfExpectedThumb).Thumbprint
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
        Write-KmdfLog -Message "$Path signed by $got - expected $want." -Level 'ERROR'
        return $false
    }
    # A self-signed / locally-generated cert legitimately reports
    # UnknownError (chain not trusted by default). Thumbprint match is the gate.
    if ($sig.Status -ne 'Valid' -and $sig.Status -ne 'UnknownError') {
        Write-KmdfLog -Message "$Path signature status $($sig.Status)." -Level 'WARN'
    }
    Write-KmdfLog -Message "$Path signed by $got status=$($sig.Status)" -Level 'OK'
    return $true
}

# Verify against the RESOLVED expected thumbprint (env / this PC's cert /
# legacy constant). Community users sign with their own cert, so no caller may
# pin a literal thumbprint any more.
function Test-KmdfSignedByExpected {
    param([Parameter(Mandatory)][string]$Path)
    $exp = Resolve-KmdfExpectedThumb
    Write-KmdfLog -Message "Expected signer $($exp.Thumbprint) from $($exp.Source)." -Level 'INFO'
    return (Test-KmdfSignedByThumb -Path $Path -Thumb $exp.Thumbprint)
}

# One sentence a non-technical user can act on when a signature check fails.
function Get-KmdfSigningAdvice {
    $exp = Resolve-KmdfExpectedThumb
    if ($exp.Source -like 'last-resort*') {
        return 'Run Setup-Community.cmd first - it creates a signing certificate on this PC and signs the driver for you. Nothing in the download is pre-signed.'
    }
    return "Run Setup-Community.cmd again to re-sign the package with this PC's certificate ($($exp.Thumbprint))."
}

function Test-KmdfForbiddenSys {
    param([Parameter(Mandatory)][string]$Path)
    $name = [System.IO.Path]::GetFileName($Path)
    if ($name -eq $script:KmdfLiveSysName) {
        Write-KmdfLog -Message "Refusing live-named $name - that filename is the Apr 30 restore file. Use $script:KmdfUniqueSys / $script:KmdfArtifactGlob." -Level 'ERROR'
        return $true
    }
    if ($name -like 'applewirelessmouse*' -or $name -eq $script:KmdfPathAShipBlocker) {
        Write-KmdfLog -Message "Refusing PATH-A package $name - SHIPBLOCKER BSOD. Never the 0323 product." -Level 'ERROR'
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
        Write-KmdfLog -Message "Refusing May 20 SHA $sha - pointer-dead." -Level 'ERROR'
        return $true
    }
    if ($sha -eq $script:KmdfShaFailed204) {
        Write-KmdfLog -Message "Refusing failed 2.0.4 SHA $sha (oem26 / Event 41). Rebuild and freeze a new hash." -Level 'ERROR'
        return $true
    }
    if ($sha -eq $script:KmdfShaApr30) {
        Write-KmdfLog -Message "Refusing Apr 30 SHA $sha as this package - that binary stays oem16 / MagicMouseDriver.sys for restore." -Level 'ERROR'
        return $true
    }
    return $false
}

# INF identity gates. Returns a list of problems; empty means the INF is the
# unique 2.0.4.x scroll package and cannot strand the Apr 30 oem16 install.
function Get-KmdfInfProblem {
    param([Parameter(Mandatory)][string]$Path)
    $problems = @()
    $infText = Get-Content -LiteralPath $Path -Raw

    if ($infText -notmatch '(?m)^[ \t]*CatalogFile[ \t]*=[ \t]*MagicMouseDriver-kmdf-204-scroll\.cat') {
        $problems += "INF CatalogFile is not $($script:KmdfUniqueCat)."
    }
    # Only real directives count. The INF documents the banned 2.0.4.0
    # identities in its own ";" comment header, and matching the raw text made
    # this gate reject the shipping INF outright.
    $verMatches = [regex]::Matches($infText, '(?m)^[ \t]*DriverVer[ \t]*=[ \t]*(\d{2}/\d{2}/\d{4})[ \t]*,[ \t]*([0-9.]+)')
    if ($verMatches.Count -eq 0) {
        $problems += 'INF has no parseable DriverVer.'
    }
    foreach ($m in $verMatches) {
        $date = $m.Groups[1].Value
        $ver  = $m.Groups[2].Value
        if ($ver -eq '2.0.4.0' -and ($date -eq '08/30/2026' -or $date -eq '08/31/2026')) {
            $problems += "INF DriverVer $date,$ver collides with the failed 2.0.4.0 oem26 / PR #3 identity."
            continue
        }
        $parsed = $null
        if (-not [version]::TryParse($ver, [ref]$parsed)) {
            $problems += "INF DriverVer version '$ver' is not parseable."
        }
        elseif ($parsed -lt [version]$script:KmdfDriverVerMinimum) {
            $problems += "INF DriverVer $ver is older than $($script:KmdfDriverVerMinimum) (2.0.4.0 is the failed oem26 identity)."
        }
    }
    if ($infText -match 'ServiceBinary\s*=\s*%12%\\MagicMouseDriver\.sys') {
        $problems += 'INF ServiceBinary must not be MagicMouseDriver.sys (Apr 30 restore file).'
    }
    if ($infText -match '(?m)^MagicMouseDriver\.sys') {
        $problems += 'INF CopyFiles must not be MagicMouseDriver.sys (Apr 30 restore file).'
    }
    if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') {
        $problems += 'INF AddService must not be MagicMouseDriver (live oem16 SCM name).'
    }
    if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') {
        $problems += "INF AddService must be $($script:KmdfServiceName)."
    }
    if ($infText -notmatch 'LowerFilters.*,0x00010000,"MagicMouseDriver204Scroll"') {
        $problems += "INF LowerFilters must be $($script:KmdfServiceName)."
    }
    if ($infText -match 'LowerFilters.*,0x00010000,"MagicMouseDriver"(?!204Scroll)') {
        $problems += 'INF LowerFilters must not be MagicMouseDriver (live oem16 filter).'
    }
    return $problems
}

# Every gate that protects the live Apr 30 pointer driver, applied to one
# package folder. Returns a list of problems; empty means safe to pnputil.
function Get-KmdfPackageProblem {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [switch]$RequireSignature
    )
    $problems = @()
    $inf = Join-Path $Directory $script:KmdfUniqueInf
    $sys = Join-Path $Directory $script:KmdfUniqueSys
    $cat = Join-Path $Directory $script:KmdfUniqueCat
    $retired = Join-Path $Directory $script:KmdfRetiredInf
    $liveNamed = Join-Path $Directory $script:KmdfLiveSysName

    if (Test-Path -LiteralPath $retired) {
        $problems += "Retired $($script:KmdfRetiredInf) is in the package folder. That identity created oem26 and hardlinked over Apr 30. Use $($script:KmdfUniqueInf) only."
    }
    if (Test-Path -LiteralPath $liveNamed) {
        $problems += "Package folder has $($script:KmdfLiveSysName). Remove it. That name collides with the Apr 30 restore file."
    }
    if (-not (Test-Path -LiteralPath $inf)) {
        $problems += "Missing $inf"
    }
    else {
        $problems += @(Get-KmdfInfProblem -Path $inf)
    }
    if (-not (Test-Path -LiteralPath $sys)) {
        $problems += "Missing $sys"
    }
    elseif (Test-KmdfForbiddenSys -Path $sys) {
        $problems += "Refusing banned .sys $sys"
    }
    if ($RequireSignature) {
        if (-not (Test-Path -LiteralPath $cat)) {
            $problems += "Missing $cat - the catalog is built and signed by Setup-Community.cmd."
        }
        elseif (-not (Test-KmdfSignedByExpected -Path $cat)) {
            $problems += "$($script:KmdfUniqueCat) is unsigned or signed by an unexpected certificate. $(Get-KmdfSigningAdvice)"
        }
        if ((Test-Path -LiteralPath $sys) -and -not (Test-KmdfSignedByExpected -Path $sys)) {
            $problems += "$($script:KmdfUniqueSys) is unsigned or signed by an unexpected certificate. $(Get-KmdfSigningAdvice)"
        }
    }
    return $problems
}

# ---------------------------------------------------------------------------
# Machine state probes (all read-only)
# ---------------------------------------------------------------------------

function Test-KmdfTestSigningOn {
    $out = & bcdedit.exe /enum '{current}' 2>&1 | Out-String
    return ($out -match '(?im)^\s*testsigning\s+Yes')
}

function Test-KmdfSecureBootOn {
    try { return [bool](Confirm-SecureBootUEFI) } catch { return $false }
}

function Test-KmdfMemoryIntegrityOn {
    $key = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'
    try {
        $v = Get-ItemProperty -Path $key -Name 'Enabled' -ErrorAction Stop
        return ([int]$v.Enabled -eq 1)
    }
    catch { return $false }
}

function Test-KmdfFastStartupOn {
    try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -ErrorAction Stop
        return ([int]$v.HiberbootEnabled -eq 1)
    }
    catch { return $false }
}

# All PnP entities that belong to the Magic Mouse v3 (PID 0323).
function Get-KmdfMouseDevice {
    try {
        return @(Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.PNPDeviceID -match 'PID[_&]0323' })
    }
    catch { return @() }
}

# The BTHENUM node pnputil /restart-device takes. The mouse also enumerates a
# {00001200-...} PnP-information node; restarting that one does nothing, so the
# HID service GUID {00001124-...} - the one this INF binds - is required.
function Get-KmdfMouseInstanceId {
    $bth = @(Get-KmdfMouseDevice | Where-Object { $_.PNPDeviceID -like 'BTHENUM\*' })
    $hid = $bth | Where-Object { $_.PNPDeviceID -like 'BTHENUM\{00001124*' } | Select-Object -First 1
    if ($hid) { return $hid.PNPDeviceID }
    if ($bth.Count -gt 0) { return $bth[0].PNPDeviceID }
    return $null
}

# Diag counters the driver publishes once per second.
function Get-KmdfDiag {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($script:KmdfServiceName)\Diag"
    $out = [ordered]@{ Present = $false; SdpPatchSuccess = $null; LastAclReceived = $null; ScrollStep = $null }
    try {
        $p = Get-ItemProperty -Path $key -ErrorAction Stop
        $out['Present'] = $true
        foreach ($n in @('SdpPatchSuccess', 'LastAclReceived', 'ScrollStep')) {
            if ($null -ne $p.PSObject.Properties[$n]) { $out[$n] = [int]$p.$n }
        }
    }
    catch { }
    return $out
}

# Published oem*.inf names for OUR unique package only. oem16 / the Apr 30
# MagicMouseDriver.inf package is filtered out and never returned, so no
# caller can be tricked into deleting it.
function Get-KmdfPublishedOemNames {
    $pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
    $blocks = $pnpRaw -split '(?=Published Name:)'
    $found = @()
    foreach ($block in $blocks) {
        if ($block -notmatch 'MagicMouseDriver-kmdf-204-scroll\.inf') { continue }
        if ($block -match 'Original Name:\s+MagicMouseDriver\.inf') { continue }
        if ($block -match 'Published Name:\s+oem16\.inf') { continue }
        if ($block -match 'Published Name:\s+(oem\d+\.inf)') { $found += $Matches[1] }
    }
    return $found
}
