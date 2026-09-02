# sign.ps1 — sign MagicKbDesc.sys + .cat with the M12 CN=MagicMouseFix cert.
# Reuses the M12 trust path (cert already in TrustedPublisher).

$ErrorActionPreference = 'Stop'

$sysPath = Join-Path $PSScriptRoot 'x64\Release\MagicKbDesc\MagicKbDesc.sys'
$catPath = Join-Path $PSScriptRoot 'x64\Release\MagicKbDesc\MagicKbDesc.cat'

foreach ($f in @($sysPath, $catPath)) {
    if (-not (Test-Path $f)) {
        throw "Build artifact missing: $f. Run build.ps1 first."
    }
}

# Reuse M12 thumbprint (CN=MagicMouseFix) — see sign-and-install.ps1.
$thumb = 'B902C2864315E2DE359450024768CE7D01715C38'
$timestampUrl = 'http://timestamp.digicert.com'
$signtool = 'F:\Program Files\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe'

if (-not (Test-Path $signtool)) {
    throw "signtool.exe not found at $signtool. EWDK ISO mounted at F:\?"
}

foreach ($f in @($sysPath, $catPath)) {
    Write-Host "Signing $f ..."
    & $signtool sign /sm /sha1 $thumb /fd sha256 /tr $timestampUrl /td sha256 /v $f
    if ($LASTEXITCODE -ne 0) {
        throw "signtool failed on $f (exit=$LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "Signed. Verify with:"
Write-Host "  & '$signtool' verify /pa $sysPath"
