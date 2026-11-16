<#
.SYNOPSIS
    Compiles the nik CLI using a portable Nikrun Free Pascal SDK.

.DESCRIPTION
    Unified build script for both local development and CI pipelines:
    - Locally: '.\build.ps1' compiles bin/nik(.exe) using an installed SDK in ~/.nikrun.
    - In CI (after '.\prepare.ps1'): '.\build.ps1 -Profile release -Clean -StageDist'
      compiles, verifies 'nik --version', and stages the binary, SHA-256 checksum, and
      build-info.json into dist/cli/<targetTriplet>/.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Profile release
    .\build.ps1 -Profile release -Install
    .\build.ps1 -Profile release -Clean -StageDist
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('debug', 'release')]
    [string]$Profile = 'debug',

    [Parameter()]
    [string]$SdkPath = '',

    [Parameter()]
    [string]$NikrunHome = '',

    [Parameter()]
    [string]$OutputPath = '',

    [Parameter()]
    [switch]$StageDist,

    [Parameter()]
    [string]$DistDir = '',

    [Parameter()]
    [switch]$CreateArchive,

    [Parameter()]
    [switch]$Install,

    [Parameter()]
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CliRoot           = $PSScriptRoot
$RepoRoot          = $CliRoot
$SrcDir            = [System.IO.Path]::Combine($CliRoot, 'src')
$LspProtocolSrcDir = [System.IO.Path]::Combine($RepoRoot, 'lsp-protocol', 'src')
$OutDir            = [System.IO.Path]::Combine($CliRoot, 'bin')
$EntryPas          = [System.IO.Path]::Combine($SrcDir, 'nik.pas')

if (-not (Test-Path $LspProtocolSrcDir)) {
    throw "nikrun-lsp-protocol source directory not found at: $LspProtocolSrcDir"
}

$IsWinHost = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
    [bool]$IsWindows
} else {
    ($env:OS -match 'Windows')
}

$HomeDir = if ($IsWinHost -and $env:USERPROFILE) {
    $env:USERPROFILE
} elseif ($env:HOME) {
    $env:HOME
} else {
    $env:USERPROFILE
}

function Resolve-FullPsPath([string]$RawPath) {
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RawPath)
}

$EffectiveNikHome = if (-not [string]::IsNullOrWhiteSpace($NikrunHome)) {
    Resolve-FullPsPath $NikrunHome
} elseif (-not [string]::IsNullOrWhiteSpace($env:NIKRUN_HOME)) {
    Resolve-FullPsPath $env:NIKRUN_HOME
} else {
    [System.IO.Path]::Combine($HomeDir, '.nikrun')
}

function Get-NikCliVersion {
    $typesPas = [System.IO.Path]::Combine($SrcDir, 'nik.types.pas')
    if (-not (Test-Path $typesPas)) {
        throw "nik.types.pas not found at: $typesPas"
    }
    $raw = Get-Content -Path $typesPas -Raw
    if ($raw -match "NIK_VERSION\s*=\s*'([^']+)'") {
        return $Matches[1]
    }
    throw "Could not extract NIK_VERSION constant from $typesPas"
}

function Resolve-FpcToolchain {
    param([string]$ExplicitSdkPath)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($ExplicitSdkPath)) {
        $resolvedExplicit = Resolve-FullPsPath $ExplicitSdkPath
        if (-not (Test-Path $resolvedExplicit)) {
            throw "Specified -SdkPath does not exist: $resolvedExplicit"
        }
        $candidates += $resolvedExplicit
    } else {
        $sdksDir = [System.IO.Path]::Combine($EffectiveNikHome, 'sdks')
        if (Test-Path $sdksDir) {
            foreach ($d in (Get-ChildItem -Path $sdksDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                $candidates += $d.FullName
            }
        }

        foreach ($stageRoot in @(
            [System.IO.Path]::Combine($RepoRoot, '.work', 'stage'),
            [System.IO.Path]::Combine((Split-Path -Parent $RepoRoot), 'sdk', '.work', 'stage')
        )) {
            if (Test-Path $stageRoot) {
                foreach ($d in (Get-ChildItem -Path $stageRoot -Directory -Filter 'nikrun-fpc-sdk-*' -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                    $candidates += $d.FullName
                }
            }
        }
    }

    foreach ($cand in $candidates) {
        $manifestPath = [System.IO.Path]::Combine($cand, 'sdk-manifest.json')
        if (Test-Path $manifestPath) {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            $binDir   = [System.IO.Path]::Combine($cand, ($manifest.paths.binDir -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar))
            $ppcProp  = $manifest.paths.PSObject.Properties['ppcBinary']
            $ppcBin   = if ($null -ne $ppcProp -and -not [string]::IsNullOrWhiteSpace([string]$ppcProp.Value)) {
                [System.IO.Path]::Combine($cand, ([string]$ppcProp.Value -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar))
            } else {
                ''
            }
            $fpcCfg = [System.IO.Path]::Combine($binDir, 'fpc.cfg')

            $gitRefProp    = $manifest.PSObject.Properties['gitRef']
            $gitCommitProp = $manifest.PSObject.Properties['gitCommit']

            if ((-not [string]::IsNullOrWhiteSpace($ppcBin)) -and (Test-Path $ppcBin) -and (Test-Path $fpcCfg)) {
                return [PSCustomObject]@{
                    SdkId         = [string]$manifest.sdkId
                    SdkRoot       = $cand
                    FpcVersion    = [string]$manifest.fpcVersion
                    GitRef        = if ($null -ne $gitRefProp)    { [string]$gitRefProp.Value }    else { '' }
                    GitCommit     = if ($null -ne $gitCommitProp) { [string]$gitCommitProp.Value } else { '' }
                    TargetOs      = [string]$manifest.targetOs
                    TargetCpu     = [string]$manifest.targetCpu
                    TargetTriplet = [string]$manifest.targetTriplet
                    BinDir        = $binDir
                    CompilerBin   = $ppcBin
                    FpcCfg        = $fpcCfg
                }
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitSdkPath)) {
        throw "Invalid or unconfigured Nikrun Free Pascal SDK at '$ExplicitSdkPath' (expected sdk-manifest.json, ppc* binary, and fpc.cfg)."
    }

    throw "No portable Nikrun Free Pascal SDK found in '$EffectiveNikHome'. Run .\prepare.ps1 first."
}

$Toolchain  = Resolve-FpcToolchain -ExplicitSdkPath $SdkPath
$CliVersion = Get-NikCliVersion
$CacheDir   = [System.IO.Path]::Combine($CliRoot, '.cache', "$($Toolchain.TargetTriplet)-$Profile")

$ExeExt = if ($Toolchain.TargetOs -eq 'win64') { '.exe' } else { '' }
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $ResolvedOut = Resolve-FullPsPath $OutputPath
    $OutDir      = Split-Path -Parent $ResolvedOut
    $OutExeName  = [System.IO.Path]::GetFileName($ResolvedOut)
} else {
    $OutExeName  = "nik$ExeExt"
}

if ($Clean -and (Test-Path $CacheDir)) {
    Remove-Item -Recurse -Force $CacheDir
}
New-Item -ItemType Directory -Force -Path $OutDir, $CacheDir | Out-Null

$DefineFlag = if ($Profile -eq 'release') { '-dRELEASE' } else { '-dDEBUG' }

Write-Host "`n==> Building nik CLI ($Profile)..." -ForegroundColor Cyan
Write-Host "    CLI Version : $CliVersion" -ForegroundColor Gray
Write-Host "    Toolchain   : $($Toolchain.SdkId)" -ForegroundColor Gray
Write-Host "    Compiler    : $($Toolchain.CompilerBin)" -ForegroundColor Gray

$fpcArgs = @(
    '-n',
    "@$($Toolchain.FpcCfg)",
    $DefineFlag,
    "-Fu$LspProtocolSrcDir",
    "-Fu$SrcDir",
    "-FE$OutDir",
    "-FU$CacheDir",
    "-o$OutExeName",
    $EntryPas
)

$PrevPath = $env:PATH
try {
    if (-not [string]::IsNullOrWhiteSpace($Toolchain.BinDir) -and (Test-Path $Toolchain.BinDir)) {
        $env:PATH = "$($Toolchain.BinDir)$([System.IO.Path]::PathSeparator)$PrevPath"
    }
    & $Toolchain.CompilerBin @fpcArgs | Out-Host
    $CompileExit = $LASTEXITCODE
} finally {
    $env:PATH = $PrevPath
}

if ($CompileExit -ne 0) {
    throw "nik CLI compilation failed with exit code $CompileExit"
}

$BuiltExe = [System.IO.Path]::Combine($OutDir, $OutExeName)
if (-not (Test-Path $BuiltExe)) {
    throw "Expected CLI binary was not produced at: $BuiltExe"
}

if ((-not $IsWinHost) -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
    & chmod +x $BuiltExe
}

$SizeKb = [math]::Round((Get-Item $BuiltExe).Length / 1KB, 1)
Write-Host " [OK] Built CLI binary: $BuiltExe ($SizeKb KB)" -ForegroundColor Green

if ($Install) {
    $InstallBinDir = [System.IO.Path]::Combine($EffectiveNikHome, 'bin')
    New-Item -ItemType Directory -Force -Path $InstallBinDir | Out-Null
    $InstalledExe = [System.IO.Path]::Combine($InstallBinDir, "nik$ExeExt")
    Copy-Item -Path $BuiltExe -Destination $InstalledExe -Force
    if ((-not $IsWinHost) -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod +x $InstalledExe
    }
    Write-Host " [OK] Installed nik CLI to: $InstalledExe" -ForegroundColor Green
}

if ($StageDist) {
    Write-Host "`n==> Verifying & staging CLI distribution artifacts..." -ForegroundColor Cyan

    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $verLines = & $BuiltExe --no-color --nikrun-home $EffectiveNikHome --version 2>&1
    $verCode  = $LASTEXITCODE
    $ErrorActionPreference = $prevErr
    $verText  = (($verLines | ForEach-Object { "$_" }) -join "`n").Trim()

    if ($verCode -ne 0) {
        throw "'nik --version' verification failed (exit $verCode): $verText"
    }
    $expectedVer = "nik $CliVersion ($($Toolchain.TargetTriplet), FPC $($Toolchain.FpcVersion))"
    if ($verText -ne $expectedVer) {
        throw "Unexpected 'nik --version' output: expected '$expectedVer', got '$verText'"
    }
    Write-Host " [OK] Verified binary execution: $verText" -ForegroundColor Green

    $EffectiveDistDir = if (-not [string]::IsNullOrWhiteSpace($DistDir)) {
        Resolve-FullPsPath $DistDir
    } else {
        [System.IO.Path]::Combine($RepoRoot, 'dist', 'cli', $Toolchain.TargetTriplet)
    }

    if (Test-Path $EffectiveDistDir) {
        Remove-Item -Recurse -Force $EffectiveDistDir
    }
    New-Item -ItemType Directory -Force -Path $EffectiveDistDir | Out-Null

    $DistBinName = "nik$ExeExt"
    $StagedExe   = [System.IO.Path]::Combine($EffectiveDistDir, $DistBinName)
    Copy-Item -Path $BuiltExe -Destination $StagedExe -Force
    if ((-not $IsWinHost) -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
        & chmod +x $StagedExe
    }

    $ExeSizeBytes = (Get-Item $StagedExe).Length
    $ExeSha256    = (Get-FileHash -Path $StagedExe -Algorithm SHA256).Hash.ToLowerInvariant()
    [System.IO.File]::WriteAllText("$StagedExe.sha256", "$ExeSha256  $DistBinName`n", [System.Text.UTF8Encoding]::new($false))

    $BuiltAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $BuildInfo  = [ordered]@{
        schemaVersion = 1
        cliVersion    = $CliVersion
        profile       = $Profile
        targetOs      = $Toolchain.TargetOs
        targetCpu     = $Toolchain.TargetCpu
        targetTriplet = $Toolchain.TargetTriplet
        binaryName    = $DistBinName
        sizeBytes     = $ExeSizeBytes
        sha256        = $ExeSha256
        fpcSdkId      = $Toolchain.SdkId
        fpcVersion    = $Toolchain.FpcVersion
        fpcGitRef     = $Toolchain.GitRef
        fpcGitCommit  = $Toolchain.GitCommit
        builtAtUtc    = $BuiltAtUtc
    }
    $BuildInfoPath = [System.IO.Path]::Combine($EffectiveDistDir, 'build-info.json')
    [System.IO.File]::WriteAllText($BuildInfoPath, ($BuildInfo | ConvertTo-Json -Depth 4) + "`n", [System.Text.UTF8Encoding]::new($false))

    if ($CreateArchive) {
        $ArchiveName = "nik-$CliVersion-$($Toolchain.TargetTriplet).zip"
        $ArchivePath = [System.IO.Path]::Combine($EffectiveDistDir, $ArchiveName)
        if ((-not $IsWinHost) -and (Get-Command zip -ErrorAction SilentlyContinue)) {
            Push-Location $EffectiveDistDir
            try {
                & zip -q $ArchivePath $DistBinName
                if ($LASTEXITCODE -ne 0) { throw "zip failed with exit code $LASTEXITCODE" }
            } finally {
                Pop-Location
            }
        } elseif ($IsWinHost -and (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
            Push-Location $EffectiveDistDir
            try {
                & tar.exe -a -cf $ArchivePath $DistBinName
                if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
            } finally {
                Pop-Location
            }
        } else {
            Compress-Archive -Path $StagedExe -DestinationPath $ArchivePath -Force
        }
        $ArchiveSha = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText("$ArchivePath.sha256", "$ArchiveSha  $ArchiveName`n", [System.Text.UTF8Encoding]::new($false))
        Write-Host " [OK] Packaged archive : $ArchivePath" -ForegroundColor Green
    }

    Write-Host " [OK] Staged CLI binary: $StagedExe ($SizeKb KB)" -ForegroundColor Green
    Write-Host " [OK] SHA-256          : $ExeSha256" -ForegroundColor Green
    Write-Host " [OK] Build metadata   : $BuildInfoPath" -ForegroundColor Green

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
            "| **CLI Version** | ``$CliVersion`` (``$Profile``) |"
            "| **Target** | ``$($Toolchain.TargetTriplet)`` |"
            "| **Binary** | ``$DistBinName`` ($SizeKb KB) |"
            "| **SHA-256** | ``$ExeSha256`` |"
            "| **Compiler SDK** | $sdkDisplay |"
            ""
        ) -join "`n"
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $summaryMd, [System.Text.UTF8Encoding]::new($false))
    }

    if (-not [string]::IsNullOrWhiteSpace($env:GITHUB_OUTPUT)) {
        $ghOut = @(
            "binary_path=$StagedExe"
            "artifact_dir=$EffectiveDistDir"
            "cli_version=$CliVersion"
            "target_triplet=$($Toolchain.TargetTriplet)"
            "sha256=$ExeSha256"
            "sdk_id=$($Toolchain.SdkId)"
        ) -join "`n"
        [System.IO.File]::AppendAllText($env:GITHUB_OUTPUT, "$ghOut`n", [System.Text.UTF8Encoding]::new($false))
    }
}

return $BuiltExe
