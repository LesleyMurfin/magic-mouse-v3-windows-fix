# kmdf-204-scroll-sign.ps1
# Sign unique 2.0.4.1 sys+cat with thumb 16940C0F. No MagicMouseDriver.sys. No PATH-A.
$ErrorActionPreference = 'Stop'
$Thumb = '16940C0F937D569363560D5FEC5CD8FA6D6D9BCE'
$ForbidB902 = 'B902C2864315E2DE359450024768CE7D01715C38'
$WdkTest = '609447610A54605BE39AB32CFADB661023FD3ED0'
$SrcSys = 'C:\mm-dev-queue\kmdf-204-bld\x64\Release\MagicMouseDriver-kmdf-204-scroll.sys'
$SrcInf = 'C:\mm-dev-queue\kmdf-204-bld\x64\Release\MagicMouseDriver-kmdf-204-scroll.inf'
$Stage = 'C:\mm-dev-queue\kmdf-204-sign'
$Sys = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.sys'
$Inf = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.inf'
$Cat = Join-Path $Stage 'MagicMouseDriver-kmdf-204-scroll.cat'
$Want = 'E73EC0A83BB01393C6ECD4359AAC6F52FAEE53C242B87ED2E49630F967375A55'
$Forbid = @(
    '845435CE','13BF983A','D3876B0A','A1289489','AD5D244B','559B136A',
    '370A5555','6DF8575B','9EF6C117','D22EB163','F02ECCED','B4582C50',
    'EA1F80B4','30F91397','614DFA90','E0BC5661','1405473F','A9450168'
)
$SignTool = 'C:\mm-dev-queue\wdk-packages\Microsoft.Windows.SDK.CPP.10.0.26100.6584\c\bin\10.0.26100.0\x64\signtool.exe'
$Inf2Cat = 'C:\mm-dev-queue\wdk-packages\Microsoft.Windows.WDK.x64.10.0.26100.6584\c\bin\10.0.26100.0\x86\Inf2Cat.exe'

function Fail([int]$c, [string]$m) { Write-Output $m; exit $c }

Write-Output '===== unique 2.0.4.1 SIGN start ====='
if (-not (Test-Path -LiteralPath $SrcSys)) { Fail 2 ('missing sys ' + $SrcSys) }
if (-not (Test-Path -LiteralPath $SrcInf)) { Fail 2 ('missing inf ' + $SrcInf) }
if (-not (Test-Path -LiteralPath $SignTool)) { Fail 2 ('missing signtool ' + $SignTool) }
if (-not (Test-Path -LiteralPath $Inf2Cat)) { Fail 2 ('missing Inf2Cat ' + $Inf2Cat) }
if ($SrcSys -match 'applewirelessmouse|MagicMouseDriver\.sys$') { Fail 3 'REFUSE live or PATH-A sys name' }

$hash = (Get-FileHash -LiteralPath $SrcSys -Algorithm SHA256).Hash.ToUpperInvariant()
Write-Output ('pre_sign_SHA256=' + $hash)
if ($hash -ne $Want) { Fail 3 ('REFUSE hash not frozen 30F91397 got ' + $hash) }
foreach ($p in $Forbid) {
    if ($hash.StartsWith($p)) { Fail 3 ('REFUSE forbidden hash ' + $hash) }
}

$infText = Get-Content -LiteralPath $SrcInf -Raw
if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') { Fail 3 'INF AddService hijacks live MagicMouseDriver' }
if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') { Fail 3 'INF AddService must be MagicMouseDriver204Scroll' }
if ($infText -match 'LowerFilters.*,0x00010000,"MagicMouseDriver"(?!204Scroll)') { Fail 3 'INF LowerFilters hijacks live MagicMouseDriver' }
if ($infText -notmatch 'LowerFilters.*,0x00010000,"MagicMouseDriver204Scroll"') { Fail 3 'INF LowerFilters must be MagicMouseDriver204Scroll' }
if ($infText -match 'ServiceBinary\s*=\s*%12%\\MagicMouseDriver\.sys') { Fail 3 'INF ServiceBinary is live MagicMouseDriver.sys' }

$c = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $Thumb } | Select-Object -First 1
if (-not $c) { Fail 3 'REFUSE 16940C0F missing from LocalMachine\My' }
if (-not $c.HasPrivateKey) { Fail 3 'REFUSE 16940C0F HasPrivateKey=False' }
if ($c.Thumbprint -eq $ForbidB902) { Fail 3 'REFUSE B902C286' }
if ($c.Thumbprint -eq $WdkTest) { Fail 3 'REFUSE WDKTestCert' }

New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Get-ChildItem -LiteralPath $Stage -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $Stage -Force | Out-Null
Copy-Item -LiteralPath $SrcInf -Destination $Inf -Force
Copy-Item -LiteralPath $SrcSys -Destination $Sys -Force

Write-Output '=== Inf2Cat ==='
& $Inf2Cat /driver:$Stage /os:10_X64 /verbose
if ($LASTEXITCODE -ne 0) { Fail $LASTEXITCODE 'Inf2Cat failed' }
if (-not (Test-Path -LiteralPath $Cat)) { Fail 2 'cat missing after Inf2Cat' }

Write-Output '=== sign SYS 16940C0F ==='
& $SignTool sign /sm /s My /sha1 $Thumb /fd sha256 /tr 'http://timestamp.digicert.com' /td sha256 /v $Sys
if ($LASTEXITCODE -ne 0) { Fail $LASTEXITCODE 'sys signing failed' }

Write-Output '=== sign CAT 16940C0F ==='
& $SignTool sign /sm /s My /sha1 $Thumb /fd sha256 /tr 'http://timestamp.digicert.com' /td sha256 /v $Cat
if ($LASTEXITCODE -ne 0) { Fail $LASTEXITCODE 'cat signing failed' }

Write-Output '=== verify ==='
& $SignTool verify /v /pa $Sys
$v1 = $LASTEXITCODE
& $SignTool verify /v /pa $Cat
$v2 = $LASTEXITCODE
if ($v1 -ne 0) { Fail $v1 'sys verify failed' }
if ($v2 -ne 0) { Fail $v2 'cat verify failed' }

$sig = Get-AuthenticodeSignature -LiteralPath $Sys
$th = ''
if ($sig.SignerCertificate) { $th = $sig.SignerCertificate.Thumbprint.ToUpperInvariant() }
Write-Output ('signer_thumb=' + $th)
if ($th -ne $Thumb) { Fail 3 ('REFUSE signer thumb ' + $th) }
Write-Output '===== unique 2.0.4.1 SIGN done ====='
exit 0
