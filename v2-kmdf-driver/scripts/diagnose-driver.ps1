#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Apple Wireless Mouse driver diagnostic script.
    Run from PowerShell as Administrator.
#>

$driverName = "applewirelessmouse"
$sysFile    = "C:\Windows\System32\drivers\$driverName.sys"
$logFile    = "$env:USERPROFILE\Desktop\apple-mouse-diag.txt"

function Write-Log {
    param([string]$text)
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $text"
    Write-Host $line
    Add-Content -Path $logFile -Value $line
}

function Write-Section {
    param([string]$title)
    $bar = "=" * 60
    Write-Log ""
    Write-Log $bar
    Write-Log "  $title"
    Write-Log $bar
}

# Start fresh log
"" | Set-Content $logFile
Write-Log "Apple Wireless Mouse Driver Diagnostic"
Write-Log "Date: $(Get-Date)"

# ── 1. Driver .sys file ──────────────────────────────────────
Write-Section "1. Driver .sys file"
if (Test-Path $sysFile) {
    $file = Get-Item $sysFile
    Write-Log "FOUND: $sysFile"
    Write-Log "  Size:     $($file.Length) bytes"
    Write-Log "  Modified: $($file.LastWriteTime)"

    # Authenticode signature (built-in, no Sysinternals needed)
    $sig = Get-AuthenticodeSignature $sysFile
    Write-Log "  Signature status: $($sig.Status)"
    Write-Log "  Signer:           $($sig.SignerCertificate.Subject)"
} else {
    Write-Log "NOT FOUND: $sysFile  <-- driver binary is missing"
}

# ── 2. Service config ────────────────────────────────────────
Write-Section "2. Service config (sc qc)"
$scOutput = & sc.exe qc $driverName 2>&1
$scOutput | ForEach-Object { Write-Log "  $_" }

Write-Section "2b. Service state (sc query)"
$scQuery = & sc.exe query $driverName 2>&1
$scQuery | ForEach-Object { Write-Log "  $_" }

# ── 3. Autorunsc (Unicode-safe via Select-String) ────────────
Write-Section "3. Autoruns — registered driver entries"
$autorunsPath = @(
    "$env:USERPROFILE\Downloads\autorunsc.exe",
    "C:\Tools\autorunsc.exe",
    "C:\Sysinternals\autorunsc.exe",
    (Get-Command autorunsc.exe -ErrorAction SilentlyContinue)?.Source
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($autorunsPath) {
    Write-Log "Using: $autorunsPath"
    # -nobanner suppresses header noise; pipe to Select-String handles Unicode
    & $autorunsPath -accepteula -nobanner -a d 2>&1 |
        Select-String -Pattern "apple" -CaseSensitive:$false |
        ForEach-Object { Write-Log "  $_" }

    Write-Log ""
    Write-Log "--- Full driver list (all entries) ---"
    & $autorunsPath -accepteula -nobanner -a d 2>&1 |
        ForEach-Object { Write-Log "  $_" }
} else {
    Write-Log "autorunsc.exe not found in common paths. Skipping."
    Write-Log "Download from: https://learn.microsoft.com/sysinternals/downloads/autoruns"
}

# ── 4. Sigcheck (if available) ───────────────────────────────
Write-Section "4. Sigcheck — deep signature verification"
$sigcheckPath = @(
    "$env:USERPROFILE\Downloads\sigcheck.exe",
    "C:\Tools\sigcheck.exe",
    "C:\Sysinternals\sigcheck.exe",
    (Get-Command sigcheck.exe -ErrorAction SilentlyContinue)?.Source
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if ($sigcheckPath -and (Test-Path $sysFile)) {
    & $sigcheckPath -accepteula -i -a $sysFile 2>&1 |
        ForEach-Object { Write-Log "  $_" }
} elseif (-not $sigcheckPath) {
    Write-Log "sigcheck.exe not found. Skipping."
} else {
    Write-Log "Driver .sys not present — skipping sigcheck."
}

# ── 5. pnputil device info ───────────────────────────────────
Write-Section "5. PnP devices — Apple HID/BT entries"
& pnputil /enum-devices 2>&1 |
    Select-String -Pattern "apple|00001124-0000-1000-8000-00805f9b34fb" -CaseSensitive:$false |
    ForEach-Object { Write-Log "  $_" }

Write-Section "5b. INF package info (oem0.inf)"
& pnputil /enum-drivers 2>&1 |
    Select-String -Pattern "apple|oem0\.inf" -CaseSensitive:$false |
    ForEach-Object { Write-Log "  $_" }

# ── 6. Windows Event Log errors ──────────────────────────────
Write-Section "6. System event log — driver/service errors (last 48h)"
$since = (Get-Date).AddHours(-48)
Get-WinEvent -LogName System -ErrorAction SilentlyContinue |
    Where-Object {
        $_.TimeCreated -ge $since -and
        $_.Id -in @(7000, 7001, 7009, 7011, 7022, 7023, 7026, 7034, 7043) -and
        ($_.Message -match "apple|wirelessmouse|hid" -or $_.ProviderName -match "apple")
    } |
    Sort-Object TimeCreated |
    ForEach-Object {
        Write-Log "  [$($_.TimeCreated)] ID=$($_.Id) — $($_.Message -replace '\s+',' ')"
    }

# ── 7. Registry LowerFilters check ───────────────────────────
Write-Section "7. Registry — LowerFilters entry"
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{745a17a0-74d3-11d0-b6fe-00a0c90f57da}\0005"
try {
    $lf = (Get-ItemProperty $regPath -ErrorAction Stop).LowerFilters
    Write-Log "  LowerFilters: $($lf -join ', ')"
} catch {
    Write-Log "  Could not read registry key: $_"
}

# ── Done ─────────────────────────────────────────────────────
Write-Section "DONE"
Write-Log "Full log saved to: $logFile"
Write-Host ""
Write-Host "Log written to: $logFile" -ForegroundColor Cyan
