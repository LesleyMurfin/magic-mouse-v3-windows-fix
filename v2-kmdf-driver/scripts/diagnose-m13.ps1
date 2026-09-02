#Requires -RunAsAdministrator
<#
.SYNOPSIS
    M13 driver MVP 1 verification script.
    Reads diagnostic registry keys written by MagicMouseDriver.sys (1 Hz).
    Run from PowerShell as Administrator.

.DESCRIPTION
    MVP 1 success criteria (read from registry, updated every ~1 second):
      IoctlInterceptCount > 0  — driver loaded; 0x410210 IOCTLs intercepted
      SdpScanHits > 0          — HIDDescriptorList (attr 0x0206) found in buffer
      SdpPatchSuccess > 0      — descriptor replaced (Descriptor C injected)

    If SdpScanHits == 0 after re-pair, check LastSdpBytes for the raw SDP
    header bytes — the scanner may need updating for 0x36-length sequences.

.USAGE
    # One-shot check:
    .\diagnose-m13.ps1

    # Live poll (Ctrl+C to stop):
    .\diagnose-m13.ps1 -Poll
#>

param(
    [switch]$Poll,      # poll every 2 seconds until Ctrl+C
    [switch]$Reset      # zero the counters by removing the Diag key (then re-pair)
)

$ServiceName  = "MagicMouseDriver"
$DiagKeyPath  = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Diag"
$ParamsPath   = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters"

function Write-Pass { param($msg) Write-Host "[PASS] $msg" -ForegroundColor Green }
function Write-Fail { param($msg) Write-Host "[FAIL] $msg" -ForegroundColor Red }
function Write-Info { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }
function Write-Warn { param($msg) Write-Host "[WARN] $msg" -ForegroundColor Yellow }

# ── Service status ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== M13 Driver Status ===" -ForegroundColor White

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -eq "Running") {
        Write-Pass "Service '$ServiceName' is RUNNING"
    } else {
        Write-Warn "Service '$ServiceName' status: $($svc.Status)"
    }
} else {
    Write-Fail "Service '$ServiceName' not found — driver not installed"
    Write-Info "Install: pnputil /add-driver MagicMouseDriver.inf /install"
    exit 1
}

# ── Configuration (Parameters key) ───────────────────────────────────────────
Write-Host ""
Write-Host "=== Configuration ===" -ForegroundColor White

if (Test-Path $ParamsPath) {
    $params = Get-ItemProperty $ParamsPath
    $injEnabled = if ($params.EnableInjection -ne $null) { $params.EnableInjection } else { "not set (default 1)" }
    Write-Info "EnableInjection = $injEnabled"
    if ($params.EnableInjection -eq 0) {
        Write-Warn "Injection DISABLED — set EnableInjection=1 to enable"
    }
} else {
    Write-Info "Parameters key not present — EnableInjection defaults to 1 (enabled)"
}

# ── Reset option ──────────────────────────────────────────────────────────────
if ($Reset) {
    if (Test-Path $DiagKeyPath) {
        Remove-Item -Path $DiagKeyPath -Force -Recurse
        Write-Info "Diag key cleared. Re-pair mouse to refresh counters."
    } else {
        Write-Info "Diag key not present — nothing to reset."
    }
}

# ── Diagnostic loop ───────────────────────────────────────────────────────────
function Show-Diag {
    Write-Host ""
    Write-Host "=== M13 Diagnostic Counters ($(Get-Date -Format 'HH:mm:ss')) ===" -ForegroundColor White

    if (-not (Test-Path $DiagKeyPath)) {
        Write-Warn "Diag key not yet written — driver has not fired its 1 Hz timer yet."
        Write-Info "Wait up to 2 seconds after driver loads, or re-pair the mouse."
        return $false
    }

    $d = Get-ItemProperty $DiagKeyPath

    $ic = $d.IoctlInterceptCount
    $sh = $d.SdpScanHits
    $ps = $d.SdpPatchSuccess
    $bs = $d.LastSdpBufSize
    $ns = $d.LastPatchStatusHex

    Write-Host "  IoctlInterceptCount : $ic"
    Write-Host "  SdpScanHits         : $sh"
    Write-Host "  SdpPatchSuccess     : $ps"
    Write-Host "  LastSdpBufSize      : $bs bytes"
    Write-Host "  LastPatchStatusHex  : 0x$('{0:X8}' -f $ns)"

    # LastSdpBytes — hex dump of first 64 bytes
    if ($d.LastSdpBytes -and $d.LastSdpBytes.Length -gt 0) {
        $hexStr = ($d.LastSdpBytes | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        $previewLen = [Math]::Min($d.LastSdpBytes.Length, 32)
        $preview = ($d.LastSdpBytes[0..($previewLen-1)] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
        Write-Host "  LastSdpBytes[0..31] : $preview"
        Write-Host "  (Byte 0 type: 0x$('{0:X2}' -f $d.LastSdpBytes[0]) — 0x35=seq-1B, 0x36=seq-2B)"
    }

    # MVP 1 verdict
    Write-Host ""
    $pass = $true

    if ($ic -gt 0) {
        Write-Pass "IOCTL 0x410210 intercepted ($ic times) — driver loading correctly"
    } else {
        Write-Fail "IoctlInterceptCount = 0 — driver not intercepting SDP IOCTLs"
        Write-Info "  -> Re-pair the mouse to trigger a fresh SDP query"
        $pass = $false
    }

    if ($sh -gt 0) {
        Write-Pass "SDP attribute 0x0206 found ($sh times) — pattern scanner working"
    } elseif ($ic -gt 0) {
        Write-Warn "SdpScanHits = 0 despite IOCTL intercepts"
        Write-Info "  -> Check LastSdpBytes byte[0]: if 0x36, scanner needs 2-byte header support"
        $pass = $false
    }

    if ($ps -gt 0) {
        Write-Pass "Descriptor C injected ($ps times) — MVP 1 COMPLETE"
        Write-Info "  -> Re-pair mouse, confirm scroll works, check battery in tray"
    } elseif ($sh -gt 0) {
        Write-Warn "SdpPatchSuccess = 0 despite scan hits"
        $statusHex = '0x{0:X8}' -f $ns
        Write-Info "  -> LastPatchStatusHex = $statusHex"
        Write-Info "  -> STATUS_BUFFER_TOO_SMALL (0xC0000023) means new desc > buffer"
        Write-Info "  -> STATUS_INVALID_PARAMETER (0xC000000D) means length field overflow"
        $pass = $false
    }

    return $pass
}

if ($Poll) {
    Write-Info "Polling every 2 seconds — Ctrl+C to stop. Re-pair mouse to trigger SDP query."
    while ($true) {
        Show-Diag | Out-Null
        Start-Sleep -Seconds 2
    }
} else {
    $ok = Show-Diag
    Write-Host ""
    if ($ok) {
        Write-Pass "MVP 1 verification PASSED"
    } else {
        Write-Warn "Not yet passing — re-pair mouse and re-run, or use -Poll to watch live"
    }
}
