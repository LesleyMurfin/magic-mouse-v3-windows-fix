# kmdf-204-nuget-build.ps1
# Build the unique KMDF package out-of-tree. Dest: MagicMouseDriver-kmdf-204-scroll.sys
# Unlike kmdf-204-scroll-build.ps1 (which mounts the ISO itself, builds in
# C:\mm-dev-queue and writes the FROZEN-UNSIGNED one-shot record), this script is a
# plain compiler driver: -SourceDir in, -OutDir out, no freeze record, no drive
# assumptions, nothing written outside -OutDir. Freezing/signing/installing stay
# separate (Freeze-KmdfArtifact.ps1, kmdf-204-scroll-sign.ps1) and need elevation.
#
# Two toolchains, in priority order:
#
#   Ewdk   PRIMARY. An already-mounted Enterprise WDK. This is what built every
#          frozen artifact: `call <root>\BuildEnv\SetupBuildEnv.cmd amd64` then the
#          same msbuild line as _build-once.cmd. The EWDK root is DISCOVERED, never
#          hardcoded: _build-once.cmd said F:\ and the same image came back as I:\
#          after a remount, which is the only reason the compiler ever looked
#          "missing". Identity is confirmed by <root>\Version.txt, not by letter.
#
#   NuGet  FALLBACK for a host with no EWDK mounted: VS 2022 BuildTools plus the
#          unpacked Microsoft.Windows.WDK.x64 payload. The WDK NuGet package ships
#          the WindowsDriver.*.props/targets but NOT the VSIX-installed platform
#          toolset stub, so this path generates an overlay VCTargetsPath in -OutDir
#          holding that stub and passes it as AdditionalVCTargetsPath (see
#          New-WdkToolsetOverlay). Codegen deviates from the EWDK: BuildTools
#          has no lib\spectre, so SpectreMitigation is forced off and warned about.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourceDir,

    [Parameter(Mandatory = $true)]
    [string]$OutDir,

    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [switch]$Clean,

    [ValidateSet('Auto', 'Ewdk', 'NuGet')]
    [string]$Toolchain = 'Auto',

    # Override for an EWDK mounted somewhere the drive scan will not look.
    [string]$EwdkRoot,

    # Version string required in <root>\Version.txt. '' accepts any EWDK found.
    [string]$EwdkVersion = 'ge_release_svc_prod1.26100.6584',

    # Where the unpacked WDK / SDK NuGet payloads live (fallback toolchain only).
    [string]$NuGetPackageDir = 'C:\mm-dev-queue\wdk-packages'
)

$ErrorActionPreference = 'Stop'

$TargetName = 'MagicMouseDriver-kmdf-204-scroll'
$ProjectFile = 'MagicMouseDriver.vcxproj'
$SourceGlob = @('*.c', '*.h', '*.rc', '*.vcxproj', '*.inf')
# Exit codes: 2 bad input, 3 no toolchain, 4 build failed, 5 no output, 6 forbidden output
$ExitBadInput = 2
$ExitNoToolchain = 3
$ExitBuildFailed = 4
$ExitNoOutput = 5
$ExitForbidden = 6

function Write-Step {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ''
    Write-Host ('== ' + $Message) -ForegroundColor Cyan
}

function Write-Detail {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('   ' + $Message)
}

function Write-Warn {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host ('!! ' + $Message) -ForegroundColor Yellow
}

function Exit-Fail {
    param(
        [Parameter(Mandatory = $true)][int]$Code,
        [Parameter(Mandatory = $true)][string]$Message
    )
    Write-Host ('FAIL ' + $Code + ' ' + $Message) -ForegroundColor Red
    exit $Code
}

# Discovery, not assumption: every fixed-or-removable filesystem drive is probed for
# BuildEnv\SetupBuildEnv.cmd, then identified from Version.txt. Prefers an exact
# $EwdkVersion match so a second, older image cannot silently win.
function Resolve-EwdkRoot {
    param(
        [string]$Override,
        [string]$RequiredVersion
    )

    $candidate = @()
    if ($Override) {
        $candidate = @($Override.TrimEnd('\'))
    }
    else {
        $candidate = Get-PSDrive -PSProvider FileSystem |
            Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
            ForEach-Object { $_.Root.TrimEnd('\') } |
            Sort-Object
    }

    $searched = @()
    $found = @()
    foreach ($root in $candidate) {
        $setup = Join-Path $root 'BuildEnv\SetupBuildEnv.cmd'
        $searched += $setup
        if (-not (Test-Path -LiteralPath $setup -PathType Leaf)) { continue }

        $versionFile = Join-Path $root 'Version.txt'
        $versionText = ''
        if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
            $versionText = ((Get-Content -LiteralPath $versionFile -ErrorAction SilentlyContinue) -join ' ').Trim()
        }
        $found += [pscustomobject]@{
            Root    = $root
            Setup   = $setup
            Version = $versionText
            Matched = ($RequiredVersion -ne '' -and $versionText -like ('*' + $RequiredVersion + '*'))
        }
    }

    if ($found.Count -eq 0) {
        Write-Detail 'no EWDK found. Probed:'
        foreach ($s in $searched) { Write-Detail ('  ' + $s) }
        return $null
    }

    foreach ($f in $found) {
        Write-Detail ('candidate ' + $f.Root + ' Version.txt="' + $f.Version + '" matched=' + $f.Matched)
    }

    if ($RequiredVersion -eq '') { return ($found | Select-Object -First 1) }

    $exact = $found | Where-Object { $_.Matched } | Select-Object -First 1
    if ($exact) { return $exact }

    Write-Warn ('found ' + $found.Count + ' EWDK root(s) but none reporting "' + $RequiredVersion + '".')
    Write-Warn 'pass -EwdkVersion '''' to accept a different image (codegen will not match the frozen artifacts).'
    return $null
}

function Resolve-NuGetToolchain {
    param([Parameter(Mandatory = $true)][string]$PackageDir)

    # amd64\MSBuild.exe first, deliberately: WindowsDriver.Shared.Props:307-322 picks
    # ApiValidator.exe / ApiExtractor by $(PROCESSOR_ARCHITECTURE) of the MSBuild
    # process, and the 32-bit host reports x86 - a directory the x64-only WDK package
    # does not ship, so a Universal driver build dies after linking.
    $msbuild = $null
    $vsRoot = @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022')
    )
    $relative = @('MSBuild\Current\Bin\amd64\MSBuild.exe', 'MSBuild\Current\Bin\MSBuild.exe')
    foreach ($root in $vsRoot) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        $editions = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object -Property Name
        foreach ($rel in $relative) {
            $hit = $editions |
                ForEach-Object { Join-Path $_.FullName $rel } |
                Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                Select-Object -First 1
            if ($hit) { $msbuild = $hit; break }
        }
        if ($msbuild) { break }
    }
    if (-not $msbuild) {
        Exit-Fail $ExitNoToolchain ('no MSBuild.exe under ' + ($vsRoot -join ' or ') +
            ' - install VS 2022 Build Tools with the "Desktop development with C++" workload.')
    }

    if (-not (Test-Path -LiteralPath $PackageDir -PathType Container)) {
        Exit-Fail $ExitNoToolchain ('missing WDK NuGet payload dir ' + $PackageDir +
            ' - unpack Microsoft.Windows.WDK.x64.<ver>.nupkg there or pass -NuGetPackageDir.')
    }
    $wdk = Get-ChildItem -LiteralPath $PackageDir -Directory -Filter 'Microsoft.Windows.WDK.x64.*' -ErrorAction SilentlyContinue |
        Sort-Object -Property Name -Descending |
        Select-Object -First 1
    if (-not $wdk) {
        Exit-Fail $ExitNoToolchain ('no Microsoft.Windows.WDK.x64.* package under ' + $PackageDir)
    }
    $wdkProps = Join-Path $wdk.FullName 'build\native\Microsoft.Windows.WDK.x64.props'
    if (-not (Test-Path -LiteralPath $wdkProps -PathType Leaf)) {
        Exit-Fail $ExitNoToolchain ('WDK package is incomplete - missing ' + $wdkProps)
    }
    $wdkContentRoot = Join-Path $wdk.FullName 'c'
    $wdkBuildDir = Join-Path $wdkContentRoot 'build'
    $buildFolder = Get-ChildItem -LiteralPath $wdkBuildDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'WindowsDriver.Common.props') } |
        Sort-Object -Property Name -Descending |
        Select-Object -First 1
    if (-not $buildFolder) {
        Exit-Fail $ExitNoToolchain ('no WindowsDriver.Common.props under ' + $wdkBuildDir)
    }

    # The WDK package carries only the km/wdf headers and libs. shared\sdkddkver.h,
    # um\windows.h (the .rc needs it) and rc.exe live in Microsoft.Windows.SDK.CPP,
    # and the um import libs in Microsoft.Windows.SDK.CPP.x64. Three roots, where an
    # installed SDK/EWDK has one - hence the explicit path wiring in the overlay.
    $sdk = Get-ChildItem -LiteralPath $PackageDir -Directory -Filter 'Microsoft.Windows.SDK.CPP.1*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName ('c\Include\' + $buildFolder.Name + '\shared\sdkddkver.h')) } |
        Sort-Object -Property Name -Descending |
        Select-Object -First 1
    if (-not $sdk) {
        Exit-Fail $ExitNoToolchain ('no Microsoft.Windows.SDK.CPP.* package with c\Include\' +
            $buildFolder.Name + '\shared\sdkddkver.h under ' + $PackageDir)
    }
    $sdkLib = Get-ChildItem -LiteralPath $PackageDir -Directory -Filter 'Microsoft.Windows.SDK.CPP.x64.*' -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'c\um\x64\gdi32.lib') } |
        Sort-Object -Property Name -Descending |
        Select-Object -First 1
    if (-not $sdkLib) {
        Exit-Fail $ExitNoToolchain ('no Microsoft.Windows.SDK.CPP.x64.* package with c\um\x64\gdi32.lib under ' + $PackageDir)
    }

    return [pscustomobject]@{
        MSBuild        = $msbuild
        WdkPackage     = $wdk.FullName
        WdkProps       = $wdkProps
        WdkContentRoot = $wdkContentRoot
        WdkBuildFolder = $buildFolder.Name
        SdkRoot        = (Join-Path $sdk.FullName 'c')
        SdkLibRoot     = (Join-Path $sdkLib.FullName 'c')
    }
}

function Copy-DriverSource {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    if (-not (Test-Path -LiteralPath $To)) {
        New-Item -ItemType Directory -Path $To -Force | Out-Null
    }
    $copied = 0
    foreach ($pattern in $SourceGlob) {
        foreach ($file in (Get-ChildItem -LiteralPath $From -File -Filter $pattern -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $To $file.Name) -Force
            $copied++
        }
    }
    Write-Detail ('staged ' + $copied + ' source file(s) -> ' + $To)
    return $copied
}

# cmd.exe cannot hold a UNC working directory and SetupBuildEnv.cmd only sets its
# environment inside the cmd session it runs in, so both have to happen in ONE cmd
# process. The generated .cmd therefore mirrors _build-once.cmd exactly, except that
# it re-enters its own directory with `pushd "%~dp0"` (which maps a UNC build dir to
# a temporary drive letter) instead of `cd /d` (which cannot enter a UNC path).
# The generated .cmd stays in the build dir as the reproduction record.
function Invoke-EwdkBuild {
    param(
        [Parameter(Mandatory = $true)][string]$Ewdk,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $cmdFile = Join-Path $BuildDir '_ewdk-build.cmd'
    $lines = @(
        '@echo off',
        'set "_BLD=%~dp0"',
        ('call "' + (Join-Path $Ewdk 'BuildEnv\SetupBuildEnv.cmd') + '" amd64'),
        'if errorlevel 1 exit /b 11',
        'pushd "%_BLD%"',
        'if errorlevel 1 exit /b 12',
        ('msbuild ' + $ProjectFile + ' /t:Build /m /nr:false /v:minimal' +
            ' /p:Configuration=' + $Configuration + ' /p:Platform=x64 /p:SignMode=Off' +
            ' /p:RunCodeAnalysis=false /p:EnableInf2cat=false /p:StampInf=false'),
        'set "_RC=%ERRORLEVEL%"',
        'popd',
        'exit /b %_RC%'
    )
    Set-Content -LiteralPath $cmdFile -Value $lines -Encoding ASCII
    Write-Detail ('wrote ' + $cmdFile)
    Write-Detail ('cmd.exe /d /c "' + $cmdFile + '"')

    $output = & cmd.exe /d /c $cmdFile 2>&1
    $code = $LASTEXITCODE
    $output | Out-File -LiteralPath $LogPath -Encoding UTF8
    $output | ForEach-Object { Write-Host ('   | ' + $_) }
    return $code
}

# The WDK VSIX normally installs, into the VS install:
#   <VCTargetsPath>\Platforms\x64\PlatformToolsets\WindowsKernelModeDriver10.0\Toolset.props
#   <VCTargetsPath>\Platforms\x64\ImportAfter\WDK.x64.*.Platform.props
# The NuGet payload carries the ImportAfter glue and every WindowsDriver.*.props /
# .targets, but NOT that toolset stub - and VCTargetsPath lives under Program Files,
# which is off-limits. So build a tiny OVERLAY VCTargetsPath in -OutDir holding only
# Platforms\x64\{Platform.props,Platform.targets,ImportAfter\*,PlatformToolsets\
# WindowsKernelModeDriver10.0\{Toolset.props,Toolset.targets}} and hand it to MSBuild
# as AdditionalVCTargetsPath. Microsoft.Cpp.props:68-74 resolves the toolset with
# FindRootFolderWhereAllFilesExist($(CurrentVCTargetsPath);$(AdditionalVCTargetsPath),
# Platform.props;Platform.targets;Toolset.props;Toolset.targets), so the overlay wins
# for those four files while Microsoft.Cpp.ToolsetLocation.props:103-106 restores
# VCTargetsPath to the real install for everything else.
#
# Why not the alternatives: /p:ForceImportBeforeCppProps is evaluated after the
# toolset lookup has already failed, and a full copy of VCTargetsPath into a WSL
# worktree breaks on case - MSBuild asks for Microsoft.BuildSteps.Targets while the
# file on disk is Microsoft.BuildSteps.targets, which resolves on NTFS and 404s on
# the case-sensitive share ("error MSB4019: The imported project ... was not found").
function New-WdkToolsetOverlay {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$MSBuildPath,
        [Parameter(Mandatory = $true)][string]$WdkContentRoot,
        [Parameter(Mandatory = $true)][string]$WdkBuildFolder,
        [Parameter(Mandatory = $true)][string]$SdkRoot,
        [Parameter(Mandatory = $true)][string]$SdkLibRoot
    )

    # Walk up from MSBuild.exe rather than counting directories: the 32-bit and
    # amd64 hosts sit at different depths under the VS install.
    $vcTargets = $null
    $probe = Split-Path -Parent $MSBuildPath
    while ($probe) {
        $candidate = Join-Path $probe 'MSBuild\Microsoft\VC\v170'
        if (Test-Path -LiteralPath (Join-Path $candidate 'Microsoft.Cpp.Default.props')) {
            $vcTargets = $candidate
            break
        }
        $probe = Split-Path -Parent $probe
    }
    if (-not $vcTargets) {
        Exit-Fail $ExitNoToolchain ('no MSBuild\Microsoft\VC\v170\Microsoft.Cpp.Default.props above ' +
            $MSBuildPath + ' - the "Desktop development with C++" workload is not installed.')
    }
    if (-not (Test-Path -LiteralPath (Join-Path $vcTargets 'Platforms\x64\PlatformToolsets\v143\Toolset.props'))) {
        Exit-Fail $ExitNoToolchain ('no v143 platform toolset under ' + $vcTargets)
    }

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    $platformDir = Join-Path $Destination 'Platforms\x64'
    $toolsetDir = Join-Path $platformDir 'PlatformToolsets\WindowsKernelModeDriver10.0'
    $importAfter = Join-Path $platformDir 'ImportAfter'
    New-Item -ItemType Directory -Path $toolsetDir -Force | Out-Null
    New-Item -ItemType Directory -Path $importAfter -Force | Out-Null

    Copy-Item -Path (Join-Path $WdkContentRoot ('build\' + $WdkBuildFolder + '\x64\ImportAfter\*')) `
        -Destination $importAfter -Force
    Write-Detail ('WDK platform ImportAfter glue -> ' + $importAfter)

    $generated = '  <!-- Generated by kmdf-204-nuget-build.ps1: stands in for the WDK VSIX toolset stub. -->'
    $head = '<Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003">'

    # ImportAfter\*.props is imported alphabetically after the toolset props, so the
    # WDK glue (WDK.x64.*) has already set IncludePath from the kernel macros by the
    # time this one runs - "ZZ" keeps it last. cl and rc both take INCLUDE from
    # IncludePath; km\crt stays ahead of ucrt because KernelMode.props put it first.
    Set-Content -LiteralPath (Join-Path $importAfter 'ZZ.kmdf-204-nuget-sdk-include.props') -Encoding ASCII -Value @(
        $head,
        $generated,
        '  <PropertyGroup>',
        ('    <IncludePath>$(IncludePath);' + $SdkRoot.TrimEnd('\') + '\Include\' + $WdkBuildFolder + '\um;' +
            $SdkRoot.TrimEnd('\') + '\Include\' + $WdkBuildFolder + '\ucrt</IncludePath>'),
        '  </PropertyGroup>',
        '</Project>'
    )

    # $(VCTargetsPath) still points at this overlay while props are evaluated, so the
    # real install is addressed through $(CurrentVCTargetsPath).
    Set-Content -LiteralPath (Join-Path $platformDir 'Platform.props') -Encoding ASCII -Value @(
        $head,
        $generated,
        '  <PropertyGroup>',
        '    <_PlatformFolder>$(MSBuildThisFileDirectory)</_PlatformFolder>',
        '  </PropertyGroup>',
        '  <Import Project="$(CurrentVCTargetsPath)Microsoft.Cpp.Platform.props" />',
        '</Project>'
    )
    Set-Content -LiteralPath (Join-Path $platformDir 'Platform.targets') -Encoding ASCII -Value @(
        $head,
        $generated,
        '  <Import Project="$(VCTargetsPath)\Microsoft.Cpp.Platform.targets" />',
        '</Project>'
    )
    # v143\Toolset.props:21 imports $(_PlatformFolder)Platform.Common.props, i.e. out
    # of this overlay, so that one needs a shim too.
    Set-Content -LiteralPath (Join-Path $platformDir 'Platform.Common.props') -Encoding ASCII -Value @(
        $head,
        $generated,
        '  <Import Project="$(CurrentVCTargetsPath)Platforms\$(Platform)\Platform.Common.props" />',
        '</Project>'
    )

    $wdkRoot = $WdkContentRoot.TrimEnd('\') + '\'
    $sdkRoot = $SdkRoot.TrimEnd('\') + '\'
    $sdkLibRoot = $SdkLibRoot.TrimEnd('\') + '\'
    Set-Content -LiteralPath (Join-Path $toolsetDir 'Toolset.props') -Encoding ASCII -Value @(
        $head,
        $generated,
        '  <PropertyGroup>',
        '    <!-- v143 Toolset.props and the WDK props reach for $(VCTargetsPath), which at',
        '         this point still names this overlay; point it back at the real install. -->',
        '    <VCTargetsPath>$(CurrentVCTargetsPath)</VCTargetsPath>',
        '  </PropertyGroup>',
        '  <PropertyGroup>',
        ('    <WDKContentRoot>' + $wdkRoot + '</WDKContentRoot>'),
        ('    <WDKBuildFolder>' + $WdkBuildFolder + '</WDKBuildFolder>'),
        ('    <WindowsSdkDir>' + $sdkRoot + '</WindowsSdkDir>'),
        ('    <WindowsSdkDir_10>' + $sdkRoot + '</WindowsSdkDir_10>'),
        ('    <UCRTContentRoot>' + $sdkRoot + '</UCRTContentRoot>'),
        '    <WDK_NuGet>true</WDK_NuGet>',
        '    <IsKernelModeToolset>true</IsKernelModeToolset>',
        '    <IsUserModeToolset>false</IsUserModeToolset>',
        '    <!-- WindowsDriver.Common.targets:70 switches to its NuGet tool-path branch',
        '         only when this is set; it is what gets rc.exe out of the SDK package',
        '         instead of $(WDKBinRoot)\x86, which the x64 package does not ship. -->',
        ('    <WindowsSDKVersionedBinRoot>' + $sdkRoot + 'bin\' + $WdkBuildFolder + '</WindowsSDKVersionedBinRoot>'),
        '    <IsDriverAppToolset>false</IsDriverAppToolset>',
        '    <DDKPlatform>x64</DDKPlatform>',
        '    <!-- _CheckWindowsSDKInstalled (Microsoft.Cpp.WindowsSDK.targets:32-46) wants',
        '         one SDK root with Include\<ver>\shared and Lib\<ver>\um\x64 under it. The',
        '         NuGet packages are three separate roots, so the layout probe can only',
        '         fail (MSB8036); the paths below are wired explicitly instead. -->',
        '    <WindowsSDKInstalled>true</WindowsSDKInstalled>',
        '    <WindowsSDK_Desktop_Support>true</WindowsSDK_Desktop_Support>',
        '    <WindowsSDK_UAP_Support>false</WindowsSDK_UAP_Support>',
        ('    <WindowsSDK_LibraryPath_x64>' + $sdkLibRoot + 'um\x64</WindowsSDK_LibraryPath_x64>'),
        '    <!-- Single directory, not a list: WindowsDriver.Shared.Props:105 builds the',
        '         forced include as $(KIT_SHARED_IncludePath)\warning.h. The um and ucrt',
        '         header dirs are appended to IncludePath by the ImportAfter file below. -->',
        ('    <KIT_SHARED_IncludePath>' + $sdkRoot + 'Include\' + $WdkBuildFolder + '\shared</KIT_SHARED_IncludePath>'),
        '    <!-- stampinf.exe: the x64 NuGet package ships bin\<ver>\x64 only, while',
        '         WindowsDriver.Common.targets:130 defaults InfToolPath to $(WDKBinRoot)\x86. -->',
        ('    <InfToolPath>' + $wdkRoot + 'bin\' + $WdkBuildFolder + '\x64\</InfToolPath>'),
        '  </PropertyGroup>',
        '  <Import Project="$(WDKContentRoot)build\$(WDKBuildFolder)\WindowsDriver.Default.props" />',
        '  <!-- KM_IncludePath / CRT_IncludePath / DDK_LIB_PATH / KMDF_*_PATH: normally',
        '       auto-imported from an installed kit, here imported by path. -->',
        ('  <Import Project="$(WDKContentRoot)DesignTime\CommonConfiguration\Neutral\WDK\' +
            '$(WDKBuildFolder)\WDK.props" />'),
        '  <Import Project="$(CurrentVCTargetsPath)Platforms\$(Platform)\PlatformToolsets\v143\Toolset.props" />',
        ('  <Import Project="$(WDKContentRoot)build\$(WDKBuildFolder)\x64\WindowsKernelModeDriver\' +
            'WDK.x64.WindowsKernelModeDriver.props" />'),
        '</Project>'
    )
    # WindowsDriver.Common.props imports WindowsDriver.x64.props itself (line 97) and
    # the ImportAfter glue pulls in Common/KernelMode/LateEvaluation, so neither is
    # imported here - doing so produces "MSB4011 cannot be imported again".
    Set-Content -LiteralPath (Join-Path $toolsetDir 'Toolset.targets') -Encoding ASCII -Value @(
        $head,
        $generated,
        '  <Import Project="$(VCTargetsPath)\Platforms\$(Platform)\PlatformToolsets\v143\Toolset.targets" />',
        '  <Import Project="$(WDKContentRoot)build\$(WDKBuildFolder)\WindowsDriver.Common.targets" />',
        '</Project>'
    )
    Write-Detail ('WindowsKernelModeDriver10.0 toolset stub -> ' + $toolsetDir)
    return $Destination
}

function Invoke-NuGetBuild {
    param(
        [Parameter(Mandatory = $true)][psobject]$Tools,
        [Parameter(Mandatory = $true)][string]$BuildDir,
        [Parameter(Mandatory = $true)][string]$Overlay,
        [Parameter(Mandatory = $true)][string]$LogPath
    )

    $msbuildArgs = @(
        (Join-Path $BuildDir $ProjectFile),
        '/t:Build', '/m', '/nr:false', '/v:minimal',
        ('/p:Configuration=' + $Configuration),
        '/p:Platform=x64',
        '/p:SignMode=Off',
        '/p:RunCodeAnalysis=false',
        '/p:EnableInf2cat=false',
        '/p:StampInf=false',
        ('/p:AdditionalVCTargetsPath=' + $Overlay.TrimEnd('\') + '\'),
        ('/p:WDKContentRoot=' + $Tools.WdkContentRoot.TrimEnd('\') + '\'),
        ('/p:WDKBuildFolder=' + $Tools.WdkBuildFolder),
        '/p:SpectreMitigation=false',
        # DPVerifierTask loads x86\InfVerif.dll, which the x64-only NuGet package does
        # not ship; the INF is verified separately by the desktop InfVerif anyway.
        '/p:SkipPackageVerification=true'
    )
    Write-Detail ($Tools.MSBuild + ' ' + ($msbuildArgs -join ' '))
    $output = & $Tools.MSBuild $msbuildArgs 2>&1
    $code = $LASTEXITCODE
    $output | Out-File -LiteralPath $LogPath -Encoding UTF8
    $output | ForEach-Object { Write-Host ('   | ' + $_) }
    return $code
}

Write-Step 'kmdf-204-nuget-build: inputs'
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
    Exit-Fail $ExitBadInput ('missing -SourceDir ' + $SourceDir)
}
$SourceDir = (Resolve-Path -LiteralPath $SourceDir).ProviderPath.TrimEnd('\')
if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $ProjectFile) -PathType Leaf)) {
    Exit-Fail $ExitBadInput ('-SourceDir ' + $SourceDir + ' has no ' + $ProjectFile)
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}
$OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath.TrimEnd('\')
if ($OutDir -match '^[Cc]:\\') {
    Exit-Fail $ExitForbidden ('-OutDir ' + $OutDir + ' is on C:\ - this script never writes to C:\.')
}
Write-Detail ('SourceDir     ' + $SourceDir)
Write-Detail ('OutDir        ' + $OutDir)
Write-Detail ('Configuration ' + $Configuration)
Write-Detail ('Toolchain     ' + $Toolchain)

$BuildDir = Join-Path $OutDir 'build'
if ($Clean) {
    Write-Step 'clean'
    foreach ($stale in @($BuildDir, (Join-Path $OutDir 'vctargets-overlay'))) {
        if (Test-Path -LiteralPath $stale) {
            Remove-Item -LiteralPath $stale -Recurse -Force
            Write-Detail ('removed ' + $stale)
        }
    }
    Get-ChildItem -LiteralPath $OutDir -File -Filter '*.sys' -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Force
            Write-Detail ('removed ' + $_.FullName)
        }
}

Write-Step 'resolve toolchain'
$ewdk = $null
if ($Toolchain -ne 'NuGet') {
    $ewdk = Resolve-EwdkRoot -Override $EwdkRoot -RequiredVersion $EwdkVersion
}
if (-not $ewdk -and $Toolchain -eq 'Ewdk') {
    Exit-Fail $ExitNoToolchain ('no Enterprise WDK found. Mount the EWDK ISO (or pass -EwdkRoot) ' +
        'and retry; -Toolchain NuGet uses the BuildTools fallback instead.')
}

$nuget = $null
if (-not $ewdk) {
    Write-Warn 'no EWDK - falling back to VS BuildTools + WDK NuGet payload (secondary path).'
    $nuget = Resolve-NuGetToolchain -PackageDir $NuGetPackageDir
    Write-Detail ('MSBuild        ' + $nuget.MSBuild)
    Write-Detail ('WDK package    ' + $nuget.WdkPackage)
    Write-Detail ('WDKContentRoot ' + $nuget.WdkContentRoot)
    Write-Detail ('WDKBuildFolder ' + $nuget.WdkBuildFolder)
}
else {
    Write-Detail ('EWDK root      ' + $ewdk.Root)
    Write-Detail ('EWDK version   ' + $ewdk.Version)
    Write-Detail ('env script     ' + $ewdk.Setup)
}

Write-Step 'stage sources'
if ((Copy-DriverSource -From $SourceDir -To $BuildDir) -eq 0) {
    Exit-Fail $ExitBadInput ('no driver sources matched ' + ($SourceGlob -join ';') + ' in ' + $SourceDir)
}

$logPath = Join-Path $OutDir 'msbuild.log'
if ($ewdk) {
    Write-Step ('build (EWDK ' + $ewdk.Root + ')')
    $rc = Invoke-EwdkBuild -Ewdk $ewdk.Root -BuildDir $BuildDir -LogPath $logPath
}
else {
    Write-Step 'generate the WindowsKernelModeDriver10.0 toolset overlay'
    $overlay = New-WdkToolsetOverlay -Destination (Join-Path $OutDir 'vctargets-overlay') `
        -MSBuildPath $nuget.MSBuild -WdkContentRoot $nuget.WdkContentRoot -WdkBuildFolder $nuget.WdkBuildFolder `
        -SdkRoot $nuget.SdkRoot -SdkLibRoot $nuget.SdkLibRoot
    Write-Step 'build (BuildTools + WDK NuGet)'
    Write-Warn 'SpectreMitigation=false: BuildTools has no VC\Tools\MSVC\*\lib\spectre.'
    Write-Warn 'The .sys produced by this fallback is NOT Spectre-mitigated and is a codegen'
    Write-Warn 'deviation from every EWDK-built artifact. Prefer -Toolchain Ewdk for shipping.'
    $rc = Invoke-NuGetBuild -Tools $nuget -BuildDir $BuildDir -Overlay $overlay -LogPath $logPath
}

Write-Detail ('msbuild exit ' + $rc + ', log ' + $logPath)
if ($rc -ne 0) {
    Exit-Fail $ExitBuildFailed ('build failed (exit ' + $rc + ') - see ' + $logPath)
}

Write-Step 'collect output'
$builtSys = Join-Path $BuildDir ('x64\' + $Configuration + '\' + $TargetName + '.sys')
if (-not (Test-Path -LiteralPath $builtSys -PathType Leaf)) {
    Exit-Fail $ExitNoOutput ('build reported success but ' + $builtSys + ' is missing')
}
$stray = Join-Path $BuildDir ('x64\' + $Configuration + '\MagicMouseDriver.sys')
if (Test-Path -LiteralPath $stray -PathType Leaf) {
    Exit-Fail $ExitForbidden ('REFUSE emitted MagicMouseDriver.sys ' + $stray)
}

$outSys = Join-Path $OutDir ($TargetName + '.sys')
Copy-Item -LiteralPath $builtSys -Destination $outSys -Force
$releaseDir = Join-Path $BuildDir ('x64\' + $Configuration)
$releaseInf = Join-Path $releaseDir ($TargetName + '.inf')
$stagedInf = Join-Path $BuildDir ($TargetName + '.inf')
if (-not (Test-Path -LiteralPath $stagedInf -PathType Leaf)) {
    Exit-Fail $ExitNoOutput ('no ' + $TargetName + '.inf in ' + $SourceDir)
}
# The WDK stamps a synthetic DriverVer into x64\<cfg>\<target>.inf even with
# StampInf=false (the frozen msbuild-once.log shows the same "Stamping [Version]
# section with DriverVer=09/16/2026,1.44.13.690"), so the staged source INF is
# copied over it - same restore kmdf-204-scroll-build.ps1:170 does - and it is that
# INF, carrying the real DriverVer, which gets hashed into FROZEN-UNSIGNED.txt.
Copy-Item -LiteralPath $stagedInf -Destination $releaseInf -Force
Copy-Item -LiteralPath $releaseInf -Destination (Join-Path $OutDir ($TargetName + '.inf')) -Force

$hash = (Get-FileHash -LiteralPath $outSys -Algorithm SHA256).Hash.ToUpperInvariant()
$size = (Get-Item -LiteralPath $outSys).Length
$sha8 = $hash.Substring(0, 8)
$infHash = (Get-FileHash -LiteralPath $releaseInf -Algorithm SHA256).Hash.ToUpperInvariant()
$driverVer = ''
foreach ($line in (Get-Content -LiteralPath $releaseInf)) {
    if ($line -match '^\s*DriverVer\s*=\s*(.+?)\s*$') { $driverVer = $Matches[1] }
}

# Same key/value shape kmdf-204-scroll-sign.ps1:32-42 parses, in the same build-dir
# location, so the existing sign path works against this build unmodified. Unlike
# kmdf-204-scroll-build.ps1 there is no one-shot guard: re-running overwrites this.
$frozenFile = Join-Path $BuildDir 'FROZEN-UNSIGNED.txt'
Set-Content -LiteralPath $frozenFile -Encoding ASCII -Value @(
    ('unsigned_sha256=' + $hash),
    ('unsigned_inf_sha256=' + $infHash),
    ('size=' + $size),
    ('dest=' + $TargetName + '.sys'),
    ('artifact=MagicMouseDriver-kmdf-2.0.4-scroll-' + $sha8 + '.sys'),
    ('DriverVer=' + $driverVer),
    ('source=' + $SourceDir)
)

Write-Host ''
Write-Host 'BUILD OK' -ForegroundColor Green
if ($ewdk) { Write-Host ('tool   EWDK ' + $ewdk.Root + ' (' + $ewdk.Version + ')') }
else { Write-Host ('tool   BuildTools + ' + $nuget.WdkPackage + ' (Spectre mitigation OFF)') }
Write-Host ('sys    ' + $outSys)
Write-Host ('sha256 ' + $hash)
Write-Host ('size   ' + $size)
Write-Host ('sha8   ' + $sha8)
Write-Host ('inf    ' + $releaseInf)
Write-Host ('frozen ' + $frozenFile)
Write-Host ('build  ' + $releaseDir)
Write-Host ''
Write-Host 'Unsigned. Sign with scripts\kmdf-204-scroll-sign.ps1 (thumb 16940C0F) and install'
Write-Host 'elevated - this script deliberately does neither.'
exit 0
