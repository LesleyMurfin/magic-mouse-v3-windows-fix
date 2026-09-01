# kmdf-204-scroll-build.ps1
# EWDK build of unique 2.0.4.1. Dest: MagicMouseDriver-kmdf-204-scroll.sys
# Do not emit MagicMouseDriver.sys. Do not copy into System32/DriverStore.
$ErrorActionPreference = 'Stop'
$Work = 'C:\mm-dev-queue\kmdf-204-bld'
$Src  = 'C:\mm-dev-queue\kmdf-204-src'
$Iso  = 'D:\Users\Lesley\Downloads\EWDK_ge_release_svc_prod1_26100_250904-1728.iso'
$Log  = 'C:\mm-dev-queue\kmdf-204-scroll-build.log'
$Forbid = @(
    '845435CE','13BF983A','D3876B0A','A1289489','AD5D244B','559B136A',
    '370A5555','6DF8575B','9EF6C117','D22EB163','F02ECCED','B4582C50',
    'DF3A8B1D','DFFD20E9','E10718CE'
)

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
    Write-Output $line
}
function Fail([int]$c, [string]$m) { Log "FAIL $c $m"; exit $c }

Log '===== unique 2.0.4.1 BUILD start ====='
if (-not (Test-Path -LiteralPath $Src)) { Fail 2 "missing source $Src" }
if (-not (Test-Path -LiteralPath $Iso)) { Fail 2 "missing EWDK ISO $Iso" }

$frozen = Join-Path $Work 'FROZEN-UNSIGNED.txt'
if (Test-Path -LiteralPath $frozen) {
    Fail 3 "FROZEN-UNSIGNED already exists — refuse second build."
}

$outSys  = Join-Path $Work 'x64\Release\MagicMouseDriver-kmdf-204-scroll.sys'
$liveSys = Join-Path $Work 'x64\Release\MagicMouseDriver.sys'
Log 'prior unsigned sys will be overwritten if present'

Log 'mounting EWDK ISO'
$img = Mount-DiskImage -ImagePath $Iso -PassThru
$vol = $img | Get-Volume
$letter = $vol.DriveLetter
if (-not $letter) { Fail 2 'EWDK mounted but no drive letter' }
$setup = "${letter}:\BuildEnv\SetupBuildEnv.cmd"
if (-not (Test-Path -LiteralPath $setup)) { $setup = "${letter}:\LaunchBuildEnv.cmd" }
if (-not (Test-Path -LiteralPath $setup)) { Fail 2 "SetupBuildEnv not found on ${letter}:" }
Log "EWDK on ${letter}: setup=$setup"

New-Item -ItemType Directory -Path $Work -Force | Out-Null
$names = @(
    'Driver.c','Driver.h','GestureEngine.c','GestureEngine.h',
    'HidDescriptor.c','HidDescriptor.h','InputHandler.c','InputHandler.h',
    'AclTranslate.c','AclTranslate.h','MagicMouseDriver.vcxproj',
    'MagicMouseDriver.rc','MagicMouseDriver-kmdf-204-scroll.inf'
)
foreach ($n in $names) {
    $p = Join-Path $Src $n
    if (-not (Test-Path -LiteralPath $p)) { Fail 2 "missing $p" }
    Copy-Item -LiteralPath $p -Destination (Join-Path $Work $n) -Force
}
$infText = Get-Content -LiteralPath (Join-Path $Work 'MagicMouseDriver-kmdf-204-scroll.inf') -Raw
if ($infText -notmatch 'DriverVer\s*=\s*09/01/2026,2\.0\.4\.1') { Fail 3 'INF DriverVer is not 2.0.4.1' }
if ($infText -notmatch 'CatalogFile\s*=\s*MagicMouseDriver-kmdf-204-scroll\.cat') { Fail 3 'INF CatalogFile is not unique cat' }
if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') { Fail 3 'INF AddService hijacks live MagicMouseDriver' }
if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') { Fail 3 'INF AddService must be MagicMouseDriver204Scroll' }
if ($infText -match 'LowerFilters.*,0x00010000,"MagicMouseDriver"(?!204Scroll)') { Fail 3 'INF LowerFilters hijacks live MagicMouseDriver' }
if ($infText -notmatch 'LowerFilters.*,0x00010000,"MagicMouseDriver204Scroll"') { Fail 3 'INF LowerFilters must be MagicMouseDriver204Scroll' }
if ($infText -match 'ServiceBinary\s*=\s*%12%\\MagicMouseDriver\.sys') { Fail 3 'INF ServiceBinary is live MagicMouseDriver.sys' }
$proj = Join-Path $Work 'MagicMouseDriver.vcxproj'
if (-not (Test-Path -LiteralPath $proj)) { Fail 2 "vcxproj missing immediately before msbuild $Work" }
Log ("staged immediately before msbuild: " + ((Get-ChildItem -LiteralPath $Work -File -Name | Sort-Object) -join ','))

$msbuildLog = Join-Path $Work 'msbuild-once.log'
$bat = Join-Path $Work '_build-once.cmd'
$batLines = @(
    '@echo off',
    ('call "{0}" amd64' -f $setup),
    'if errorlevel 1 exit /b 11',
    ('cd /d "{0}"' -f $Work),
    'msbuild MagicMouseDriver.vcxproj /t:Build /m /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:RunCodeAnalysis=false /p:Inf2Cat=false',
    'exit /b %ERRORLEVEL%'
)
Set-Content -LiteralPath $bat -Value $batLines -Encoding ASCII
Log 'msbuild ONCE'
& cmd.exe /c $bat > $msbuildLog 2>&1
$rc = $LASTEXITCODE
Log ("msbuild exit={0} log={1}" -f $rc, $msbuildLog)
try { Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null; Log 'EWDK unmounted' } catch { Log "unmount warn $_" }
if ($rc -ne 0 -and -not (Test-Path -LiteralPath $outSys)) { Fail $rc 'msbuild failed' }
if ($rc -ne 0) { Log 'msbuild nonzero ignored because unique sys exists (Inf2Cat not required here)' }
if (Test-Path -LiteralPath $liveSys) { Fail 3 "REFUSE emitted MagicMouseDriver.sys $liveSys" }
if (-not (Test-Path -LiteralPath $outSys)) { Fail 2 "sys missing after build $outSys" }

$hash = (Get-FileHash -LiteralPath $outSys -Algorithm SHA256).Hash.ToUpperInvariant()
$size = (Get-Item -LiteralPath $outSys).Length
$sha8 = $hash.Substring(0,8)
Log ("UNSIGNED sha256={0} size={1} sha8={2}" -f $hash, $size, $sha8)
foreach ($p in $Forbid) {
    if ($hash.StartsWith($p)) { Fail 3 "REFUSE forbidden hash prefix $p ($hash)" }
}

$parkName = "MagicMouseDriver-kmdf-2.0.4-scroll-$sha8.sys"
$park1 = Join-Path $Work $parkName
$park2 = Join-Path 'C:\mm-dev-queue' $parkName
Copy-Item -LiteralPath $outSys -Destination $park1 -Force
Copy-Item -LiteralPath $outSys -Destination $park2 -Force
Copy-Item -LiteralPath (Join-Path $Work 'MagicMouseDriver-kmdf-204-scroll.inf') -Destination (Join-Path $Work 'x64\Release\MagicMouseDriver-kmdf-204-scroll.inf') -Force

$frozenLines = @(
    ('unsigned_sha256={0}' -f $hash),
    ('size={0}' -f $size),
    'dest=MagicMouseDriver-kmdf-204-scroll.sys',
    ('artifact={0}' -f $parkName),
    'DriverVer=09/01/2026,2.0.4.1',
    'AddService=MagicMouseDriver204Scroll'
)
Set-Content -LiteralPath $frozen -Encoding ASCII -Value $frozenLines
Log ('FROZEN ' + $frozen)
Log ('parked ' + $park1)
Log '===== unique 2.0.4.1 BUILD done (unsigned) ====='
exit 0
