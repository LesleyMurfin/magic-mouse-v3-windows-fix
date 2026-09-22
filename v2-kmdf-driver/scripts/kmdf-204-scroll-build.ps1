# kmdf-204-scroll-build.ps1
# EWDK build of the unique KMDF package. Dest: MagicMouseDriver-kmdf-204-scroll.sys
# Do not emit MagicMouseDriver.sys. Do not copy into System32/DriverStore.
# Mount-DiskImage can drop a staging dir - copy sources AFTER the mount,
# immediately before msbuild.
#
# -Version / -DriverVerDate are the INF DriverVer this build REQUIRES: the
# staged INF is checked against them and the build refuses to proceed on a
# mismatch, so a stale sync can never be signed under a new version number.
# Each version builds in its own Work dir, so the FROZEN-UNSIGNED one-shot
# guard blocks rebuilding the SAME version without blocking the next one.
#
# -QueueRoot is the scratch root that holds the synced source, the per-version
# build dirs and the build log. Set the MM_QUEUE_ROOT environment variable, or
# pass -QueueRoot, to move it off the default below.
[CmdletBinding()]
param(
    [string]$Version        = '2.0.4.6',
    [string]$DriverVerDate  = '09/20/2026',
    [string]$QueueRoot      = $(if ($env:MM_QUEUE_ROOT) { $env:MM_QUEUE_ROOT } else { 'C:\mm-dev-queue' })
)

$ErrorActionPreference = 'Stop'
$Work = $QueueRoot + '\kmdf-204-bld-' + ($Version -replace '\.', '')
$Src  = $QueueRoot + '\kmdf-204-src'
$Iso  = 'D:\Users\Lesley\Downloads\EWDK_ge_release_svc_prod1_26100_250904-1728.iso'
$Log  = $QueueRoot + '\kmdf-204-scroll-build.log'
$Forbid = @(
    '845435CE','13BF983A','D3876B0A','A1289489','AD5D244B','559B136A',
    '370A5555','6DF8575B','9EF6C117','D22EB163','F02ECCED','B4582C50',
    'DF3A8B1D','DFFD20E9','E10718CE','EA1F80B4','30F91397'
)

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
    Write-Output $line
}
function Fail([int]$c, [string]$m) { Log "FAIL $c $m"; exit $c }

Log ("===== unique $Version BUILD start (queue SYNC dest) =====")
if (-not (Test-Path -LiteralPath $Src)) { Fail 2 "missing source $Src - run KMDF-204-SYNC first" }
if (-not (Test-Path -LiteralPath $Iso)) { Fail 2 "missing EWDK ISO $Iso" }

$frozen = Join-Path $Work 'FROZEN-UNSIGNED.txt'
if (Test-Path -LiteralPath $frozen) {
    Fail 3 "FROZEN-UNSIGNED already exists - refuse second build."
}

$outSys  = Join-Path $Work 'x64\Release\MagicMouseDriver-kmdf-204-scroll.sys'
$liveSys = Join-Path $Work 'x64\Release\MagicMouseDriver.sys'

Log 'mounting EWDK ISO (sources not copied to Work yet)'
$img = Mount-DiskImage -ImagePath $Iso -PassThru
try {
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
    # Restage AFTER mount, immediately before msbuild.
    foreach ($n in $names) {
        $p = Join-Path $Src $n
        if (-not (Test-Path -LiteralPath $p)) { Fail 2 "missing $p after mount" }
        Copy-Item -LiteralPath $p -Destination (Join-Path $Work $n) -Force
    }
    $infText = Get-Content -LiteralPath (Join-Path $Work 'MagicMouseDriver-kmdf-204-scroll.inf') -Raw
    $wantDriverVer = [regex]::Escape($DriverVerDate) + ',' + [regex]::Escape($Version)
    if ($infText -notmatch ('DriverVer\s*=\s*' + $wantDriverVer)) {
        Fail 3 "INF DriverVer is not $DriverVerDate,$Version"
    }
    if ($infText -notmatch 'CatalogFile\s*=\s*MagicMouseDriver-kmdf-204-scroll\.cat') { Fail 3 'INF CatalogFile is not unique cat' }
    if ($infText -match 'AddService\s*=\s*MagicMouseDriver\s*,') { Fail 3 'INF AddService hijacks live MagicMouseDriver' }
    if ($infText -notmatch 'AddService\s*=\s*MagicMouseDriver204Scroll\s*,') { Fail 3 'INF AddService must be MagicMouseDriver204Scroll' }
    if ($infText -match 'LowerFilters.*,0x00010000,"MagicMouseDriver"(?!204Scroll)') { Fail 3 'INF LowerFilters hijacks live MagicMouseDriver' }
    if ($infText -notmatch 'LowerFilters.*,0x00010000,"MagicMouseDriver204Scroll"') { Fail 3 'INF LowerFilters must be MagicMouseDriver204Scroll' }
    if ($infText -match 'ServiceBinary\s*=\s*%12%\\MagicMouseDriver\.sys') { Fail 3 'INF ServiceBinary is live MagicMouseDriver.sys' }
    $drv = Get-Content -LiteralPath (Join-Path $Work 'Driver.c') -Raw

    # Comment-stripped view for gates that must judge CODE, not prose. The
    # incident write-up in Driver.c's own header names the removed APIs, and a
    # raw -match on that text fails the build on the documentation describing
    # why the code is gone. Same trick the host gates use (tests/_code()).
    $drvCode = [regex]::Replace($drv, '/\*.*?\*/', '', 'Singleline')
    $drvCode = [regex]::Replace($drvCode, '//[^\r\n]*', '')

    if ($drvCode -notmatch 'sdpOk = \(ctx->SdpPatchSuccess != 0\)') { Fail 3 'Driver.c missing SdpPatchSuccess gate' }
    if ($drvCode -notmatch 'OnReadComplete') { Fail 3 'Driver.c missing OnReadComplete' }

    # Refuse the parked kernel HID SetFeature-via-sibling-PDO path. It shipped as
    # 2.0.4.2, was installed live once, and killed pointer AND scroll: the
    # self-issued IOCTL_HID_SET_FEATURE contends with the Bluetooth control
    # channel this filter already owns state for (STATUS.md, 2026-09-08 incident).
    # MT recovery is userspace (scripts/mm-auto-f1-watcher.ps1). This gate makes
    # re-shipping it a build failure, not a judgement call at 3am.
    if ($drvCode -match 'MmHidSetFeatureWorkItemFunc|IoRegisterPlugPlayNotification') {
        Fail 3 'Driver.c contains the parked kernel HID SetFeature path - see STATUS.md 2026-09-08 incident'
    }

    # The scroll detent must stay a registry tunable. Do NOT re-add a single
    # reference finger: it went silent whenever the lowest-id contact rested
    # and killed scroll on hardware (STATUS.md, 2026-09-16). The check runs
    # against stripped code because it is behavioral.
    if ($drvCode -notmatch 'ScrollStep') { Fail 3 'Driver.c missing ScrollStep registry tunable' }
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
        'msbuild MagicMouseDriver.vcxproj /t:Build /m /nr:false /v:minimal /p:Configuration=Release /p:Platform=x64 /p:SignMode=Off /p:RunCodeAnalysis=false /p:EnableInf2cat=false /p:StampInf=false',
        'exit /b %ERRORLEVEL%'
    )
    Set-Content -LiteralPath $bat -Value $batLines -Encoding ASCII
    if (Test-Path -LiteralPath $outSys) { Remove-Item -LiteralPath $outSys -Force }
    Log 'msbuild ONCE'
    & cmd.exe /c $bat > $msbuildLog 2>&1
    $rc = $LASTEXITCODE
    Log ("msbuild exit={0} log={1}" -f $rc, $msbuildLog)
    if ($rc -ne 0) { Fail $rc 'msbuild failed' }
    $msbuildText = ''
    if (Test-Path -LiteralPath $msbuildLog) {
        $msbuildText = Get-Content -LiteralPath $msbuildLog -Raw -ErrorAction SilentlyContinue
    }
    if ($msbuildText -match 'error C[0-9]+') { Fail 1 'msbuild C compile error (not Inf2Cat)' }
    $infPath = Join-Path $Work 'MagicMouseDriver-kmdf-204-scroll.inf'
    $infVerif = "${letter}:\Program Files\Windows Kits\10\Tools\10.0.26100.0\x64\InfVerif.exe"
    if (-not (Test-Path -LiteralPath $infVerif)) { Fail 2 "InfVerif missing $infVerif" }
    # Desktop KMDF lower filter uses DIRID 12 + HKLM Services. /w is Universal
    # (DIRID 13 / HKR) and is the PATHA-V5 gate, not this INF.
    Log "InfVerif (desktop, no /w) $infPath"
    & $infVerif /v $infPath >> $msbuildLog 2>&1
    $iv = $LASTEXITCODE
    Log ("InfVerif exit={0}" -f $iv)
    if ($iv -ne 0) { Fail $iv "InfVerif FAILED" }
}
finally {
    # Runs on success AND on every Fail/exit or terminating-error path, so a
    # failed gate can never leave the EWDK image mounted for the next run.
    try { Dismount-DiskImage -ImagePath $Iso -ErrorAction SilentlyContinue | Out-Null; Log 'EWDK unmounted' } catch { Log "unmount warn $_" }
}
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
$parkDir2 = 'D:\mm3-pr3'
$park2 = Join-Path $parkDir2 $parkName
Copy-Item -LiteralPath $outSys -Destination $park1 -Force
if (-not (Test-Path -LiteralPath $parkDir2)) {
    New-Item -ItemType Directory -Path $parkDir2 -Force | Out-Null
}
Copy-Item -LiteralPath $outSys -Destination $park2 -Force
Copy-Item -LiteralPath (Join-Path $Work 'MagicMouseDriver-kmdf-204-scroll.inf') -Destination (Join-Path $Work 'x64\Release\MagicMouseDriver-kmdf-204-scroll.inf') -Force
$infPath = Join-Path $Work 'x64\Release\MagicMouseDriver-kmdf-204-scroll.inf'
$infHash = (Get-FileHash -LiteralPath $infPath -Algorithm SHA256).Hash.ToUpperInvariant()

$frozenLines = @(
    ('unsigned_sha256={0}' -f $hash),
    ('unsigned_inf_sha256={0}' -f $infHash),
    ('size={0}' -f $size),
    'dest=MagicMouseDriver-kmdf-204-scroll.sys',
    ('artifact={0}' -f $parkName),
    ('DriverVer={0},{1}' -f $DriverVerDate, $Version),
    'AddService=MagicMouseDriver204Scroll',
    ('source=per-contact-scroll-tunable-scrollstep-{0}' -f $Version)
)
Set-Content -LiteralPath $frozen -Encoding ASCII -Value $frozenLines
Log ('FROZEN ' + $frozen)
Log ('parked ' + $park1)
Log ("===== unique $Version BUILD done (unsigned) =====")
Log 'DO NOT pnputil. DO NOT load. Human signs thumb 16940C0F first.'
exit 0
