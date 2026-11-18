<#
.SYNOPSIS
    Builds, tests, and packages the nik CLI using a portable Nikrun Free Pascal SDK.

.DESCRIPTION
    Unified build script aligned with the Nikrun/Niksphere CI & Release pipeline:
    - Resolves CleanVersion and VersionTag from version.txt (or -Version).
    - Compiles bin/nik(.exe) with build-time version injection (without modifying tracked sources).
    - Runs build-lib Pester tests, nikrun-lsp-protocol unit tests, and nik CLI E2E tests when -RunTests is active.
    - Packages nik-<VersionTag>-<targetTriplet>.zip (+ .sha256), release-notes.json, and manifest.json into -OutDir.
    - Supports -ManifestOnly to assemble a unified multi-platform manifest.json from prebuilt CI matrix artifacts.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -RunTests:$false
    .\build.ps1 -Profile release -Install -RunTests:$false
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
    [string]$SdkPath = "",
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
    $SrcDir            = [System.IO.Path]::Combine($RootDir, 'src')
    $BrandIcoPath      = [System.IO.Path]::Combine($RootDir, 'brand', 'ico', 'nikrun.ico')
    $LspProtocolSrcDir = [System.IO.Path]::Combine($RootDir, 'lsp-protocol', 'src')
    $LazUtilsDir       = [System.IO.Path]::Combine($RootDir, 'vendor', 'lazarus', 'components', 'lazutils')
    $CodeToolsDir      = [System.IO.Path]::Combine($RootDir, 'vendor', 'lazarus', 'components', 'codetools')
    $BinOutDir         = [System.IO.Path]::Combine($RootDir, 'bin')
    $EntryPas          = [System.IO.Path]::Combine($SrcDir, 'nik.pas')

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
                [System.IO.Path]::Combine($RootDir, '.work', 'stage'),
                [System.IO.Path]::Combine((Split-Path -Parent $RootDir), 'sdk', '.work', 'stage')
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

    if ($RunTests) {
        Write-Host "  -> Running build-lib Pester tests..."
        Invoke-BuildLibTests -RootDir $RootDir
    }

    $Toolchain = Resolve-FpcToolchain -ExplicitSdkPath $SdkPath
    $CacheDir  = [System.IO.Path]::Combine($RootDir, '.cache', "$($Toolchain.TargetTriplet)-$Profile")
    $ExeExt    = if ($Toolchain.TargetOs -eq 'win64') { '.exe' } else { '' }
    $OutExeName = "nik$ExeExt"

    if ($Clean -and (Test-Path $CacheDir)) {
        Remove-Item -Recurse -Force $CacheDir
    }
    New-Item -ItemType Directory -Force -Path $BinOutDir, $CacheDir | Out-Null

    # Write build-time version include into isolated CacheDir (only rewrite if changed to preserve incremental .ppu timestamps)
    $EscapedVersionTag = $VersionTag.Replace("'", "''")
    $VersionIncPath    = [System.IO.Path]::Combine($CacheDir, 'nik_build_version.inc')
    $VersionIncContent = "NIK_VERSION = '$EscapedVersionTag';`n"
    $ExistingInc       = if (Test-Path $VersionIncPath) { [System.IO.File]::ReadAllText($VersionIncPath) } else { '' }
    if ($ExistingInc -cne $VersionIncContent) {
        [System.IO.File]::WriteAllText($VersionIncPath, $VersionIncContent, [System.Text.UTF8Encoding]::new($false))
    }

    $DefineFlag = if ($Profile -eq 'release') { '-dRELEASE' } else { '-dDEBUG' }

    function Update-Win32IconResource([string]$IcoPath, [string]$ResPath) {
        [byte[]]$IcoBytes = [System.IO.File]::ReadAllBytes($IcoPath)
        if ($IcoBytes.Length -lt 6) {
            throw "Invalid .ico file (too short): $IcoPath"
        }
        $reserved = [System.BitConverter]::ToUInt16($IcoBytes, 0)
        $icoType  = [System.BitConverter]::ToUInt16($IcoBytes, 2)
        $count    = [System.BitConverter]::ToUInt16($IcoBytes, 4)
        if ($reserved -ne 0 -or $icoType -ne 1 -or $count -lt 1) {
            throw "Invalid .ico header: $IcoPath"
        }

        function Write-DwordPad([System.IO.BinaryWriter]$W) {
            $rem = [int]($W.BaseStream.Position % 4)
            if ($rem -ne 0) {
                for ($p = 0; $p -lt (4 - $rem); $p++) { $W.Write([byte]0) }
            }
        }
        function Write-ResHdr([System.IO.BinaryWriter]$W, [uint32]$DataLen, [uint16]$TypeId, [uint16]$NameId, [uint16]$Flags, [uint16]$Lang) {
            $W.Write([uint32]$DataLen)
            $W.Write([uint32]32)
            $W.Write([uint16]0xFFFF); $W.Write([uint16]$TypeId)
            $W.Write([uint16]0xFFFF); $W.Write([uint16]$NameId)
            $W.Write([uint32]0)
            $W.Write([uint16]$Flags); $W.Write([uint16]$Lang)
            $W.Write([uint32]0); $W.Write([uint32]0)
        }

        $resMs = [System.IO.MemoryStream]::new()
        $rw    = [System.IO.BinaryWriter]::new($resMs)
        $grpMs = [System.IO.MemoryStream]::new()
        $gw    = [System.IO.BinaryWriter]::new($grpMs)

        Write-ResHdr $rw 0 0 0 0 0

        $gw.Write([uint16]0)
        $gw.Write([uint16]1)
        $gw.Write([uint16]$count)

        for ($i = 0; $i -lt $count; $i++) {
            $entryOff  = 6 + ($i * 16)
            $imgSize   = [System.BitConverter]::ToUInt32($IcoBytes, $entryOff + 8)
            $imgOffset = [System.BitConverter]::ToUInt32($IcoBytes, $entryOff + 12)
            $iconId    = [uint16]($i + 1)

            Write-ResHdr $rw $imgSize 3 $iconId 0x1010 0x0409
            $rw.Write($IcoBytes, [int]$imgOffset, [int]$imgSize)
            Write-DwordPad $rw

            $gw.Write($IcoBytes, $entryOff, 12)
            $gw.Write($iconId)
        }

        $gw.Flush()
        [byte[]]$grpBytes = $grpMs.ToArray()
        $gw.Dispose(); $grpMs.Dispose()

        Write-ResHdr $rw ([uint32]$grpBytes.Length) 14 1 0x1030 0x0409
        $rw.Write($grpBytes)
        Write-DwordPad $rw
        $rw.Flush()

        [byte[]]$NewResBytes = $resMs.ToArray()
        $rw.Dispose(); $resMs.Dispose()

        $WriteRes = $true
        if (Test-Path $ResPath) {
            [byte[]]$OldResBytes = [System.IO.File]::ReadAllBytes($ResPath)
            if ($OldResBytes.Length -eq $NewResBytes.Length) {
                $WriteRes = $false
                for ($bIdx = 0; $bIdx -lt $NewResBytes.Length; $bIdx++) {
                    if ($OldResBytes[$bIdx] -ne $NewResBytes[$bIdx]) {
                        $WriteRes = $true
                        break
                    }
                }
            }
        }
        if ($WriteRes) {
            [System.IO.File]::WriteAllBytes($ResPath, $NewResBytes)
        }
    }

    $WinResArgs = @()
    if ($Toolchain.TargetOs -eq 'win64') {
        if (-not (Test-Path $BrandIcoPath)) {
            throw "Nikrun brand icon not found at: $BrandIcoPath (run 'git submodule update --init --depth 1')."
        }
        $ResSrcDir      = [System.IO.Path]::Combine($CacheDir, 'res-src')
        New-Item -ItemType Directory -Force -Path $ResSrcDir | Out-Null
        $IconResPath    = [System.IO.Path]::Combine($ResSrcDir, 'nik_build_icon.res')
        Update-Win32IconResource -IcoPath $BrandIcoPath -ResPath $IconResPath
        $RelResPath     = "../.cache/$($Toolchain.TargetTriplet)-$Profile/res-src/nik_build_icon.res"
        $IconIncPath    = [System.IO.Path]::Combine($CacheDir, 'nik_build_icon.inc')
        $IconIncContent = '{$R ''' + $RelResPath + '''}' + "`n"
        $ExistingIconInc = if (Test-Path $IconIncPath) { [System.IO.File]::ReadAllText($IconIncPath) } else { '' }
        if ($ExistingIconInc -cne $IconIncContent) {
            [System.IO.File]::WriteAllText($IconIncPath, $IconIncContent, [System.Text.UTF8Encoding]::new($false))
        }
        $WinResArgs = @('-dNIK_HAS_WIN_RES')
    }

    Write-Host "  -> Compiling nik ($($Toolchain.TargetTriplet), SDK $($Toolchain.SdkId))..."
    $fpcArgs = @(
        '-n',
        "@$($Toolchain.FpcCfg)",
        $DefineFlag,
        '-dNIK_HAS_BUILD_VERSION'
    ) + $WinResArgs + @(
        "-Fi$CacheDir",
        "-Fu$LazUtilsDir",
        "-Fi$LazUtilsDir",
        "-Fu$CodeToolsDir",
        "-Fi$CodeToolsDir",
        "-Fu$LspProtocolSrcDir",
        "-Fu$SrcDir",
        "-FE$BinOutDir",
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

    $BuiltExe = [System.IO.Path]::Combine($BinOutDir, $OutExeName)
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
        & (Join-Path $RootDir "lsp-protocol/test.ps1") -SdkPath $Toolchain.SdkRoot -NikrunHome $EffectiveNikHome | Out-Host
        if ($LASTEXITCODE -ne 0 -and $null -ne $LASTEXITCODE) { throw "lsp-protocol unit tests failed" }

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
