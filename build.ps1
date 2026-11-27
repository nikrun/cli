<#
.SYNOPSIS
    Builds, tests, and packages the nik CLI with an already installed (bootstrap) nik.

.DESCRIPTION
    Unified build script aligned with the Nikrun/Niksphere CI & Release pipeline:
    - Resolves CleanVersion and VersionTag from version.txt (or -Version).
    - Compiles bin/nik(.exe) with `nik build` (bootstrap nik from -NikPath, PATH or ~/.nikrun/bin; the Free Pascal
      SDK comes from nik.yaml and is installed by nik on demand) with build-time version injection through the
      generated include .work/generated/nik_build_version.inc (without modifying tracked sources).
    - Runs build-lib Pester tests, nikrun-lsp-protocol unit tests, and nik CLI E2E tests when -RunTests is active.
    - Packages nik-<VersionTag>-<targetTriplet>.zip (+ .sha256), release-notes.json, and manifest.json into -OutDir.
    - Supports -ManifestOnly to assemble a unified multi-platform manifest.json from prebuilt CI matrix artifacts.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -RunTests:$false
    .\build.ps1 -Profile release -Install -RunTests:$false
    .\build.ps1 -NikPath C:\tools\nik\nik.exe -RunTests:$false
    .\build.ps1 -OutDir artifacts -Version "v0.1.0-build.42-channel.insider" -RunTests
    .\build.ps1 -OutDir artifacts -Version "v0.1.0-build.42-channel.stable" -ManifestOnly
#>
[CmdletBinding(PositionalBinding = $false)]
param (
    [string]$OutDir = ".out",
    [string]$Version = "",
    [ValidateSet('debug', 'release')]
    [string]$Profile = "release",
    [switch]$RunTests = $true,
    [switch]$GenerateSpecs = $true,
    [switch]$ManifestOnly,
    [string]$NikPath = "",
    [string]$NikrunHome = "",
    [switch]$Install,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$RootDir = $PSScriptRoot
Import-Module (Join-Path $RootDir "build-lib/ps-modules/Common/Common.psd1") -Force

$resolvedVersion = Resolve-BuildVersion -RootDir $RootDir -Version $Version
$VersionTag      = $resolvedVersion.VersionTag
$CleanVersion    = $resolvedVersion.CleanVersion

function Resolve-FullPsPath([string]$RawPath) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RawPath)
}

$ResolvedOutDir = if ([System.IO.Path]::IsPathRooted($OutDir)) {
    Resolve-FullPsPath $OutDir
} else {
    Resolve-FullPsPath (Join-Path $RootDir $OutDir)
}
if (-not (Test-Path $ResolvedOutDir)) {
    New-Item -ItemType Directory -Path $ResolvedOutDir -Force | Out-Null
}

Write-Host "Building nik CLI..." -ForegroundColor Cyan
Write-Host "  Version:       $VersionTag ($CleanVersion)"
Write-Host "  Profile:       $Profile"
Write-Host "  OutDir:        $ResolvedOutDir"
Write-Host "  RunTests:      $RunTests"
Write-Host "  GenerateSpecs: $GenerateSpecs"
if ($ManifestOnly) {
    Write-Host "  Mode:          ManifestOnly (multi-platform aggregation)"
}

$BuiltExe = ""

if (-not $ManifestOnly) {
    $BrandIcoPath      = [System.IO.Path]::Combine($RootDir, 'brand', 'ico', 'nikrun.ico')
    $LspProtocolSrcDir = [System.IO.Path]::Combine($RootDir, 'lsp-protocol', 'src')
    $CodeToolsDir      = [System.IO.Path]::Combine($RootDir, 'vendor', 'lazarus', 'components', 'codetools')
    $BinOutDir         = [System.IO.Path]::Combine($RootDir, 'bin')
    $GeneratedDir      = [System.IO.Path]::Combine($RootDir, '.work', 'generated')

    if (-not (Test-Path $LspProtocolSrcDir)) {
        throw "nikrun-lsp-protocol source directory not found at: $LspProtocolSrcDir"
    }
    if (-not (Test-Path ([System.IO.Path]::Combine($CodeToolsDir, 'codetoolmanager.pas')))) {
        throw "Lazarus CodeTools submodule not found at: $CodeToolsDir (run 'git submodule update --init --depth 1')."
    }

    $IsWinHost = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
        [bool]$IsWindows
    } else {
        ($env:OS -match 'Windows')
    }

    # src/nik.rc embeds brand/ico/nikrun.ico into Windows builds.
    if ($IsWinHost -and -not (Test-Path $BrandIcoPath)) {
        throw "Nikrun brand icon not found at: $BrandIcoPath (run 'git submodule update --init --depth 1')."
    }

    $HomeDir = if ($IsWinHost -and $env:USERPROFILE) {
        $env:USERPROFILE
    } elseif ($env:HOME) {
        $env:HOME
    } else {
        $env:USERPROFILE
    }

    $EffectiveNikHome = if (-not [string]::IsNullOrWhiteSpace($NikrunHome)) {
        Resolve-FullPsPath $NikrunHome
    } elseif (-not [string]::IsNullOrWhiteSpace($env:NIKRUN_HOME)) {
        Resolve-FullPsPath $env:NIKRUN_HOME
    } else {
        [System.IO.Path]::Combine($HomeDir, '.nikrun')
    }

    function Resolve-BootstrapNik {
        param([string]$ExplicitPath)

        if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
            $resolvedExplicit = Resolve-FullPsPath $ExplicitPath
            if (-not (Test-Path $resolvedExplicit)) {
                throw "Specified -NikPath does not exist: $resolvedExplicit"
            }
            return $resolvedExplicit
        }

        $onPath = Get-Command nik -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $onPath) {
            return $onPath.Source
        }

        $homeNik = [System.IO.Path]::Combine($EffectiveNikHome, 'bin', $(if ($IsWinHost) { 'nik.exe' } else { 'nik' }))
        if (Test-Path $homeNik) {
            return $homeNik
        }

        throw "No bootstrap nik found (checked -NikPath, PATH and '$homeNik'). Install a released nik first (see https://nikrun.dev, or use the nikrun/github-setup-nik action in CI)."
    }

    if ($RunTests) {
        Write-Host "  -> Running build-lib Pester tests..."
        Invoke-BuildLibTests -RootDir $RootDir
    }

    $ExeExt     = if ($IsWinHost) { '.exe' } else { '' }
    $OutExePath = [System.IO.Path]::Combine($BinOutDir, "nik$ExeExt")
    New-Item -ItemType Directory -Force -Path $BinOutDir, $GeneratedDir | Out-Null

    # Write the build-time version include (picked up through nik.yaml build.includePaths + NIK_HAS_BUILD_VERSION).
    # Only rewritten when changed so FPC's include-file tracking keeps incremental .ppu files valid.
    $EscapedVersionTag = $VersionTag.Replace("'", "''")
    $VersionIncPath    = [System.IO.Path]::Combine($GeneratedDir, 'nik_build_version.inc')
    $VersionIncContent = "NIK_VERSION = '$EscapedVersionTag';`n"
    $ExistingInc       = if (Test-Path $VersionIncPath) { [System.IO.File]::ReadAllText($VersionIncPath) } else { '' }
    if ($ExistingInc -cne $VersionIncContent) {
        [System.IO.File]::WriteAllText($VersionIncPath, $VersionIncContent, [System.Text.UTF8Encoding]::new($false))
    }

    $BootstrapNik = Resolve-BootstrapNik -ExplicitPath $NikPath
    if ([string]::Equals([System.IO.Path]::GetFullPath($BootstrapNik), [System.IO.Path]::GetFullPath($OutExePath), [System.StringComparison]::OrdinalIgnoreCase)) {
        # The bootstrap nik is the file about to be overwritten: use a private copy instead.
        $BootstrapDir = [System.IO.Path]::Combine($RootDir, '.work', 'bootstrap')
        New-Item -ItemType Directory -Force -Path $BootstrapDir | Out-Null
        $BootstrapCopy = [System.IO.Path]::Combine($BootstrapDir, "nik$ExeExt")
        Copy-Item -Path $BootstrapNik -Destination $BootstrapCopy -Force
        $BootstrapNik = $BootstrapCopy
    }

    Write-Host "  -> Compiling nik with bootstrap $BootstrapNik ..."
    $nikBuildArgs = @('--no-color', '--nikrun-home', $EffectiveNikHome, 'build', '-p', $Profile, '--json')
    if ($Clean) {
        $nikBuildArgs += '--clean'
    }

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    Push-Location $RootDir
    try {
        $buildAll    = & $BootstrapNik @nikBuildArgs 2>&1
        $CompileExit = $LASTEXITCODE
    } finally {
        Pop-Location
        $ErrorActionPreference = $prevErr
    }
    $buildStdout = @($buildAll | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $buildStderr = @($buildAll | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $jsonText    = (($buildStdout | ForEach-Object { "$_" }) -join "`n").Trim()
    $stderrText  = (($buildStderr | ForEach-Object { "$_" }) -join "`n").Trim()

    $Report = $null
    try { $Report = $jsonText | ConvertFrom-Json } catch { $Report = $null }
    if ($null -eq $Report) {
        throw "'nik build' returned no JSON report (exit $CompileExit):`n$jsonText`n$stderrText"
    }

    $BuildOk = ($null -ne $Report.PSObject.Properties['success']) -and [bool]$Report.success
    if ($CompileExit -ne 0 -or -not $BuildOk) {
        if ($null -ne $Report.PSObject.Properties['error']) {
            Write-Host "  error: $($Report.error)" -ForegroundColor Red
        }
        foreach ($diag in @($Report.diagnostics)) {
            if ($diag.severity -in @('error', 'fatal')) {
                Write-Host "  $($diag.file)($($diag.line),$($diag.column)) $($diag.severity) [$($diag.code)]: $($diag.message)" -ForegroundColor Red
            }
        }
        throw "nik CLI compilation failed with exit code $CompileExit"
    }

    $SdkCommit = ''
    $SdkManifestPath = Join-Path ([string]$Report.toolchain.installPath) 'sdk-manifest.json'
    if (Test-Path $SdkManifestPath) {
        $sdkManifest = Get-Content $SdkManifestPath -Raw | ConvertFrom-Json
        if ($null -ne $sdkManifest.PSObject.Properties['gitCommit']) {
            $SdkCommit = [string]$sdkManifest.gitCommit
        }
    }
    $Toolchain = [PSCustomObject]@{
        SdkId         = [string]$Report.toolchain.sdkId
        FpcVersion    = [string]$Report.toolchain.fpcVersion
        TargetTriplet = [string]$Report.toolchain.targetTriplet
        GitCommit     = $SdkCommit
    }
    Write-Host "  -> nik build ($($Toolchain.TargetTriplet), SDK $($Toolchain.SdkId)): $($Report.counts.warnings) warning(s), $($Report.durationMs) ms"

    $BuiltExe = [string]$Report.output.binaryPath
    if (-not (Test-Path $BuiltExe)) {
        throw "Expected CLI binary was not produced at: $BuiltExe"
    }

    if ((-not $IsWinHost) -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod +x $BuiltExe
    }

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $verLines = & $BuiltExe --no-color --nikrun-home $EffectiveNikHome --version 2>&1
    $verCode  = $LASTEXITCODE
    $ErrorActionPreference = $prevErr
    $verText  = (($verLines | ForEach-Object { "$_" }) -join "`n").Trim()

    if ($verCode -ne 0) {
        throw "'nik --version' verification failed (exit $verCode): $verText"
    }
    $expectedVer = "nik $VersionTag ($($Toolchain.TargetTriplet), FPC $($Toolchain.FpcVersion))"
    if ($verText -ne $expectedVer) {
        throw "Unexpected 'nik --version' output: expected '$expectedVer', got '$verText'"
    }

    $SizeKb = [math]::Round((Get-Item $BuiltExe).Length / 1KB, 1)
    Write-Host "  -> Verified binary: $verText ($SizeKb KB)" -ForegroundColor Green

    if ($Install) {
        $InstallBinDir = [System.IO.Path]::Combine($EffectiveNikHome, 'bin')
        New-Item -ItemType Directory -Force -Path $InstallBinDir | Out-Null
        $InstalledExe = [System.IO.Path]::Combine($InstallBinDir, "nik$ExeExt")
        Copy-Item -Path $BuiltExe -Destination $InstalledExe -Force
        if ((-not $IsWinHost) -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
            & chmod +x $InstalledExe
        }
        Write-Host "  -> Installed nik CLI to: $InstalledExe" -ForegroundColor Green
    }

    if ($RunTests) {
        Write-Host "  -> Running nikrun-lsp-protocol unit tests..."
        & (Join-Path $RootDir "lsp-protocol/test.ps1") -NikBinaryPath $BuiltExe -NikrunHome $EffectiveNikHome | Out-Host
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "lsp-protocol unit tests failed" }

        Write-Host "  -> Running nik unit tests (nik test)..."
        & $BuiltExe --no-color --nikrun-home $EffectiveNikHome test -m $RootDir | Out-Host
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "nik unit tests failed" }

        Write-Host "  -> Running nik CLI & LSP integration tests..."
        & (Join-Path $RootDir "test.ps1") -SkipBuild -NikBinaryPath $BuiltExe | Out-Host
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "nik CLI integration tests failed" }
    }

    $ZipName    = "nik-${VersionTag}-$($Toolchain.TargetTriplet).zip"
    $ZipOutPath = Join-Path $ResolvedOutDir $ZipName
    Write-Host "  -> Packaging archive: $ZipOutPath"
    $LicenseFile = Join-Path $RootDir "LICENSE"
    New-ZipArchive -SourceFiles @($BuiltExe, $LicenseFile) -DestinationZipPath $ZipOutPath | Out-Null
    $ZipSha256  = Get-FileSha256 -FilePath $ZipOutPath

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_STEP_SUMMARY)) {
        $commitStr   = $Toolchain.GitCommit
        $shortCommit = if ($commitStr.Length -ge 8) { $commitStr.Substring(0, 8) } else { $commitStr }
        $sdkDisplay  = if (-not [string]::IsNullOrWhiteSpace($shortCommit)) {
            "``$($Toolchain.SdkId)`` (FPC ``$($Toolchain.FpcVersion)`` @ ``$shortCommit``)"
        } else {
            "``$($Toolchain.SdkId)`` (FPC ``$($Toolchain.FpcVersion)``)"
        }
        $summaryMd = @(
            "### ``nik`` CLI Build — ``$($Toolchain.TargetTriplet)``"
            ""
            "| Property | Value |"
            "| :--- | :--- |"
            "| **Version** | ``$VersionTag`` (``$Profile``) |"
            "| **Target** | ``$($Toolchain.TargetTriplet)`` |"
            "| **Archive** | ``$ZipName`` |"
            "| **SHA-256** | ``$ZipSha256`` |"
            "| **Compiler SDK** | $sdkDisplay |"
            ""
        ) -join "`n"
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summaryMd, [System.Text.UTF8Encoding]::new($false))
    }
}

$downloads = [ordered]@{}
$knownTriplets = @(
    "aarch64-darwin",
    "aarch64-linux",
    "aarch64-win64",
    "x86_64-darwin",
    "x86_64-linux",
    "x86_64-win64"
)

foreach ($triplet in $knownTriplets) {
    $zipName = "nik-${VersionTag}-${triplet}.zip"
    $zipPath = Join-Path $ResolvedOutDir $zipName
    if (Test-Path $zipPath) {
        $sha256 = Get-FileSha256 -FilePath $zipPath
        $downloads[$triplet] = [ordered]@{
            "url"    = $zipName
            "size"   = (Get-Item $zipPath).Length
            "sha256" = $sha256
        }
    }
}

$releaseNotesFile = $null
if ($GenerateSpecs) {
    Write-Host "  -> Generating release-notes.json and manifest.json..."
    $changelogPath = Join-Path $RootDir "changelog.yml"
    $releaseNotesFile = New-ReleaseNotesSpec `
        -ChangelogPath $changelogPath `
        -CleanVersion $CleanVersion `
        -ProductKey "nik" `
        -VersionTag $VersionTag `
        -OutDir $ResolvedOutDir

    $mdOutPath = Join-Path (Join-Path $RootDir ".work") "release-notes.md"
    New-ReleaseNotesMarkdown `
        -ChangelogPath $changelogPath `
        -CleanVersion $CleanVersion `
        -ProductName "Nikrun CLI (nik)" `
        -VersionTag $VersionTag `
        -OutputPath $mdOutPath | Out-Null
} else {
    Write-Host "  -> Skipping release-notes.json generation (GenerateSpecs = false); generating manifest.json..."
}

$specs = [ordered]@{}
if ($releaseNotesFile) {
    $specs["release-notes"] = $releaseNotesFile
}

New-Manifest `
    -ProductKey "nik" `
    -ProductName "Nikrun CLI" `
    -VersionTag $VersionTag `
    -OutDir $ResolvedOutDir `
    -Downloads $downloads `
    -Specs $specs | Out-Null

Write-Host "Build complete! Output in $ResolvedOutDir" -ForegroundColor Green

if (-not $ManifestOnly) {
    return $BuiltExe
}
