# kmdf-204-pnputil-once.ps1
# pnputil /add-driver the signed unique package in C:\mm-dev-queue\kmdf-204-sign.
# Never oem16, never MagicMouseDriver.sys, never PATH-A.
$ErrorActionPreference = 'Stop'
$Stage = 'C:\mm-dev-queue\kmdf-204-sign'
$Inf = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.inf'
$Sys = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.sys'
$Cat = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.cat'

function Fail([int]$c, [string]$m) { Write-Output $m; exit $c }

Write-Output '===== unique 2.0.4.1 PNPUTIL start ====='
if (-not (Test-Path -LiteralPath $Inf)) { Fail 2 "missing $Inf" }
if (-not (Test-Path -LiteralPath $Sys)) { Fail 2 "missing $Sys" }
if (-not (Test-Path -LiteralPath $Cat)) { Fail 2 "missing $Cat" }
if (Test-Path -LiteralPath (Join-Path $Stage 'MagicMouseDriver.sys')) {
    Fail 3 'REFUSE live MagicMouseDriver.sys in sign stage'
}
if (Test-Path -LiteralPath (Join-Path $Stage 'applewirelessmouse.sys')) {
    Fail 3 'REFUSE PATH-A in sign stage'
}

$infText = Get-Content -LiteralPath $Inf -Raw
if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') { Fail 3 'INF AddService hijacks live MagicMouseDriver' }
if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') { Fail 3 'INF AddService must be MagicMouseDriver204Scroll' }

$sig = Get-AuthenticodeSignature -LiteralPath $Sys
if ($sig.Status -ne 'Valid') { Fail 3 ('REFUSE unsigned or invalid sys ' + $sig.Status) }
$th = ''
if ($sig.SignerCertificate) { $th = $sig.SignerCertificate.Thumbprint.ToUpperInvariant() }
if ($th -notmatch '^16940C0F') { Fail 3 ('REFUSE signer thumb ' + $th) }

Write-Output '=== remove unique oem only (not oem16) ==='
$pnpRaw = & pnputil.exe /enum-drivers 2>$null | Out-String
$blocks = $pnpRaw -split '(?=Published Name:)'
foreach ($block in $blocks) {
    if ($block -notmatch 'MagicMouseDriver-kmdf-204-scroll\.inf') { continue }
    if ($block -match 'Original Name:\s+MagicMouseDriver\.inf') { continue }
    if ($block -match 'Published Name:\s+oem16\.inf') { continue }
    if ($block -match 'Published Name:\s+(oem\d+\.inf)') {
        $oem = $Matches[1]
        if ($oem -eq 'oem16.inf') { Fail 3 'REFUSE delete oem16' }
        Write-Output ("delete unique " + $oem)
        & pnputil.exe /delete-driver $oem /uninstall /force
        Write-Output ('delete_exit=' + $LASTEXITCODE)
    }
}

Write-Output '=== pnputil /add-driver unique INF ==='
& pnputil.exe /add-driver $Inf /install
$add = $LASTEXITCODE
Write-Output ('add_exit=' + $add)
if ($add -ne 0) { Fail $add 'pnputil /add-driver failed' }


$inst = 'BTHENUM\{00001124-0000-1000-8000-00805F9B34FB}_VID&0001004C_PID&0323'
Write-Output '=== restart 0323 HID instance ==='
& pnputil.exe /restart-device $inst
Write-Output ('restart_exit=' + $LASTEXITCODE)

Start-Sleep -Seconds 3

Write-Output '=== F1 SetFeature (restore MT 14+8N) ==='
$f1 = 'C:\mm-dev-queue\mm-f1-once.ps1'
if (Test-Path -LiteralPath $f1) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $f1
    Write-Output ('f1_exit=' + $LASTEXITCODE)
} else {
    Write-Output 'F1 script missing — LastAclReceived will stay 9 until HidD_SetFeature F1'
}


$oem16 = 'C:\Windows\System32\drivers\MagicMouseDriver.sys'
if (Test-Path -LiteralPath $oem16) {
    $h = (Get-FileHash -LiteralPath $oem16 -Algorithm SHA256).Hash.ToUpperInvariant()
    Write-Output ('oem16_sha256=' + $h)
    if (-not $h.StartsWith('AD5D244B')) { Fail 3 ('oem16 hash drifted ' + $h) }
}

Write-Output '===== unique 2.0.4.1 PNPUTIL done ====='
exit 0
