# PATH-A v3 trust-and-install — runs as SYSTEM via task runner
# Adds M14 cert to LocalMachine\Root + invokes pnputil /add-driver /install /force
# Outputs to log file passed as $LogPath argument.

param(
    [Parameter(Mandatory=$true)][string]$LogPath
)

$ErrorActionPreference = 'Continue'
$thumb = '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
$cerPath = 'C:\mm-dev-queue\MagicMouseFix.cer'
$infPath = 'C:\mm-dev-queue\AppleWirelessMouse.inf'

function Log([string]$msg) {
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "[$ts] $msg" | Add-Content -Path $LogPath -Encoding ASCII
}

Log "=== PATH-A trust-and-install start ==="
Log "Running as: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"

# Step 1: verify cert exists in LocalMachine\My (signing source)
$signCert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }
if (-not $signCert) {
    Log "FAIL: M14 cert $thumb not found in Cert:\LocalMachine\My"
    exit 1
}
Log "PASS: cert found in LocalMachine\My (HasPrivateKey=$($signCert.HasPrivateKey))"

# Step 2: import to LocalMachine\Root if missing
$rootCert = Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }
if ($rootCert) {
    Log "INFO: cert already in LocalMachine\Root"
} else {
    Log "Adding cert to LocalMachine\Root..."
    try {
        $store = Get-Item Cert:\LocalMachine\Root
        $store.Open('ReadWrite')
        $store.Add($signCert)
        $store.Close()
        Log "PASS: cert added to LocalMachine\Root"
    } catch {
        Log "FAIL: could not add cert to Root: $_"
        exit 2
    }
}

# Step 3: ensure cert is in TrustedPublisher (idempotent)
$tpCert = Get-ChildItem Cert:\LocalMachine\TrustedPublisher -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }
if ($tpCert) {
    Log "INFO: cert already in LocalMachine\TrustedPublisher"
} else {
    Log "Adding cert to LocalMachine\TrustedPublisher..."
    try {
        $store = Get-Item Cert:\LocalMachine\TrustedPublisher
        $store.Open('ReadWrite')
        $store.Add($signCert)
        $store.Close()
        Log "PASS: cert added to LocalMachine\TrustedPublisher"
    } catch {
        Log "FAIL: could not add cert to TrustedPublisher: $_"
        exit 3
    }
}

# Step 4: verify INF exists
if (-not (Test-Path $infPath)) {
    Log "FAIL: INF not found at $infPath"
    exit 4
}
Log "PASS: INF found at $infPath"

# Step 5: pnputil /add-driver /install /force — with timeout safety
Log "Running pnputil /add-driver $infPath /install /force..."
$pnpJob = Start-Job -ScriptBlock {
    param($inf)
    $output = & pnputil /add-driver $inf /install /force 2>&1 | Out-String
    return @{ rc = $LASTEXITCODE; output = $output }
} -ArgumentList $infPath

# Wait up to 90 seconds (pnputil can be slow)
$completed = Wait-Job $pnpJob -Timeout 90
if ($completed) {
    $result = Receive-Job $pnpJob
    Remove-Job $pnpJob
    Log "pnputil exited rc=$($result.rc)"
    Log "--- pnputil output ---"
    foreach ($line in ($result.output -split "`r?`n")) {
        if ($line.Trim()) { Log "  $line" }
    }
    Log "--- end pnputil output ---"
    if ($result.rc -eq 0 -or $result.rc -eq 259) {
        Log "PASS: pnputil install succeeded (rc=$($result.rc))"
    } else {
        Log "FAIL: pnputil rc=$($result.rc)"
        exit 5
    }
} else {
    Log "FAIL: pnputil hung beyond 90s timeout — killing job"
    Stop-Job $pnpJob
    Remove-Job $pnpJob -Force
    exit 6
}

# Step 6: verify our package registered
Log "Verifying registration..."
$enumOut = & pnputil /enum-drivers 2>&1 | Out-String
$ourEntry = ($enumOut -split '(?=Published Name:)') | Where-Object {
    $_ -match 'applewirelessmouse' -and $_ -match '6\.3\.0\.0'
}
if ($ourEntry) {
    foreach ($line in (($ourEntry | Out-String) -split "`r?`n" | Select-Object -First 8)) {
        if ($line.Trim()) { Log "  $line" }
    }
    Log "PASS: PATH-A v6.3.0.0 driver registered in DriverStore"
} else {
    Log "WARN: PATH-A v6.3.0.0 not visible in pnputil /enum-drivers — install may have failed silently"
}

Log "=== PATH-A trust-and-install complete ==="
exit 0
