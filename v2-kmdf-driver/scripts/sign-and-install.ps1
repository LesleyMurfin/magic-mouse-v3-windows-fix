# Sign and install a patched HID/BT lower-filter driver for Magic Mouse.
# Run as Administrator in PowerShell.
# Requires: DSE-disabled boot OR test signing mode (this script enables testsigning).
#
# Default targets the v3 reference bundle (AppleWirelessMouse.inf in $PSScriptRoot/driver).
# For PATH-A v5 (renamed-service bundle), invoke with parameters:
#   sign-and-install.ps1 -DriverDir 'C:\mm-dev-queue\PATH-A-v5' `
#                        -InfName  'MagicMouseFixV3.inf' `
#                        -CatName  'MagicMouseFixV3.cat' `
#                        -ServiceName 'MagicMouseFixV3' `
#                        -ExistingCertThumbprint '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
#
# When -ExistingCertThumbprint is provided, the existing cert in LocalMachine\My is
# reused instead of creating a new self-signed cert.
[CmdletBinding()]
param(
    [string]$DriverDir              = (Join-Path $PSScriptRoot "driver"),
    [string]$InfName                = 'AppleWirelessMouse.inf',
    [string]$CatName                = 'applewirelessmouse.cat',
    [string]$ServiceName            = 'applewirelessmouse',
    [string]$ExistingCertThumbprint = ''   # if empty, create new self-signed cert (v3 default behavior)
)

$DRIVER_DIR = $DriverDir
$INF = Join-Path $DRIVER_DIR $InfName
$CAT = Join-Path $DRIVER_DIR $CatName

if (-not (Test-Path $INF)) {
    Write-Error "Driver files not found. Expected: $INF`nDownload from: https://github.com/tealtadpole/MagicMouse2DriversWin11x64"
    exit 1
}

# Step 1 - Use existing cert if thumbprint provided, otherwise create a new self-signed one
if ($ExistingCertThumbprint) {
    Write-Host "Step 1: Using existing cert (thumbprint $ExistingCertThumbprint)..."
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $ExistingCertThumbprint } | Select-Object -First 1
    if (-not $cert) { Write-Error "Cert with thumbprint $ExistingCertThumbprint not found in LocalMachine\My"; exit 1 }
    if (-not $cert.HasPrivateKey) { Write-Error "Cert $ExistingCertThumbprint has no private key  -  cannot sign"; exit 1 }
    Write-Host "  Reused cert: $($cert.Subject) thumb=$($cert.Thumbprint) HasPrivateKey=$($cert.HasPrivateKey)"
} else {
    Write-Host "Step 1: Creating self-signed certificate..."
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=MagicMouseFix" `
        -CertStoreLocation Cert:\LocalMachine\My `
        -KeyUsage DigitalSignature `
        -NotAfter (Get-Date).AddYears(10)
    Write-Host "  Certificate created: $($cert.Thumbprint)"
}

New-Item -ItemType Directory -Path "C:\Temp" -Force | Out-Null
$certPath = "C:\Temp\MagicMouseFix.cer"
Export-Certificate -Cert $cert -FilePath $certPath -Force | Out-Null

# Step 2 - Trust the cert (required for Windows to accept test-signed drivers)
Write-Host "Step 2: Trusting certificate..."
Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
Import-Certificate -FilePath $certPath -CertStoreLocation Cert:\LocalMachine\Root | Out-Null

# Step 3 - Re-enable CatalogFile line in INF (we commented it out earlier)
Write-Host "Step 3: Restoring CatalogFile line in INF..."
$content = Get-Content $INF -Raw
$content = $content -replace '; CatalogFile=applewirelessmouse.cat', 'CatalogFile=applewirelessmouse.cat'
[System.IO.File]::WriteAllText($INF, $content)

# Step 4 - Generate catalog from driver directory
Write-Host "Step 4: Generating file catalog..."
if (Test-Path $CAT) { Remove-Item $CAT -Force }
New-FileCatalog -Path $DRIVER_DIR -CatalogFilePath $CAT -CatalogVersion 2 | Out-Null
Write-Host "  Catalog created: $CAT"

# Step 5 - Sign the catalog
Write-Host "Step 5: Signing catalog..."
$sig = Set-AuthenticodeSignature -FilePath $CAT -Certificate $cert
Write-Host "  Signature status: $($sig.Status)"

# Step 6 - Enable test signing (allows test-signed drivers to be selected and loaded)
Write-Host "Step 6: Enabling test signing mode..."
bcdedit /set testsigning on | Out-Null
Write-Host "  Test signing enabled (small watermark will appear after reboot - removable later)"

# Step 7 - Remove prior copies of OUR INF from DriverStore (matches by Original Name).
# v3 default: matches existing applewirelessmouse.inf entries.
# v5: matches prior MagicMouseFixV3.inf entries; stock Apple oem10.inf left alone.
Write-Host "Step 7: Removing prior copies of $InfName from DriverStore..."
$pnpRaw = (pnputil /enum-drivers 2>$null) | Out-String
$existing = ($pnpRaw -split '(?=Published Name:)') |
    Where-Object { $_ -match [regex]::Escape($InfName) } |
    ForEach-Object { if ($_ -match 'Published Name:\s+(oem\d+\.inf)') { $Matches[1] } }
if ($existing) {
    $existing | ForEach-Object {
        Write-Host "  Removing $_..."
        pnputil /delete-driver $_ /force 2>$null | Out-Null
    }
} else {
    Write-Host "  No prior $InfName in DriverStore - skipping"
}

# Step 8 - Install the now-signed package
Write-Host "Step 8: Installing signed driver package..."
pnputil /add-driver $INF /install /force

# Step 9 - Register startup repair task (runs startup-repair.ps1 at every boot)
# Script is copied to a fixed protected path so the scheduled task cannot be hijacked
# by overwriting a world-writable source directory (LPE mitigation  -  see TEST-PLAN BLK-03).
Write-Host "Step 9: Registering startup repair task..."
$repairScript = Join-Path $PSScriptRoot "startup-repair.ps1"
$installDir   = "C:\Program Files\MagicMouseTray"
$installedScript = Join-Path $installDir "startup-repair.ps1"

if (Test-Path $repairScript) {
    $taskName = "MagicMouseTray-StartupRepair"

    # Copy script to protected install directory (Administrators-only write, not world-writable)
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item $repairScript $installedScript -Force
    # Lock ACL: SYSTEM + Administrators full, Users read-only, no user write
    icacls $installDir /inheritance:r /grant "SYSTEM:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" /grant "Users:(OI)(CI)RX" | Out-Null
    Write-Host "  Script installed to: $installedScript"

    # Create and lock the log directory (prevents TOCTOU symlink attack via SYSTEM log rotation  -  BLK-04)
    $logDir = "C:\ProgramData\MagicMouseTray"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    icacls $logDir /inheritance:r /grant "SYSTEM:(OI)(CI)F" /grant "Administrators:(OI)(CI)F" /grant "Users:(OI)(CI)R" | Out-Null
    Write-Host "  Log directory locked: $logDir"

    $taskExists = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($taskExists) {
        # Update task to point to new install path in case it previously pointed to PSScriptRoot
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "  Existing task removed  -  re-registering with protected path"
    }

    $action  = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installedScript`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $trigger.Delay = "PT30S"   # 30-second delay to let BT stack initialise
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

    Register-ScheduledTask -TaskName $taskName -Action $action `
        -Trigger $trigger -Settings $settings -Principal $principal `
        -Description "Repairs Magic Mouse COL02 battery HID collection at startup" `
        -Force | Out-Null
    Write-Host "  Task '$taskName' registered (runs '$installedScript' at startup with 30s delay, as SYSTEM)"
} else {
    Write-Host "  WARNING: startup-repair.ps1 not found at $repairScript  -  skipping task registration"
    Write-Host "  For persistent battery reading across reboots, run Register-ScheduledTask manually."
}

Write-Host ""
Write-Host "Done. Now:"
Write-Host "  1. Remove the Magic Mouse from Bluetooth Settings"
Write-Host "  2. Re-pair it"
Write-Host "  3. Test scroll"
Write-Host "  4. Reboot normally (test signing takes effect at next boot)"
Write-Host "     Battery reading will be auto-repaired by the startup task."
Write-Host ""
Write-Host "After scroll is confirmed working post-reboot:"
Write-Host "  bcdedit /set testsigning off  (then reboot  -  watermark gone, driver stays)"
