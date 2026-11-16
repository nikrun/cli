<#
.SYNOPSIS
    Prepares the build environment by downloading, verifying, and installing the newest prebuilt Nikrun Free Pascal SDK.

.DESCRIPTION
    Intended primarily for CI workflows (GitHub Actions) or fresh machines before invoking .\build.ps1.
    Detects and validates the host OS (win64, linux, darwin) and 64-bit CPU architecture (x86_64, aarch64),
    installs missing Linux linker prerequisites if required, fetches index.json from the latest
    release of nikrun/sdk, selects the newest matching Nikrun FPC SDK, verifies its SHA-256 checksum, and
    installs + smoke-tests it into ~/.nikrun (or -NikrunHome / $env:NIKRUN_HOME).

.EXAMPLE
    .\prepare.ps1
    .\prepare.ps1 -TargetOs linux -TargetCpu aarch64
    .\prepare.ps1 -SdkVersion 3.3.1
    .\prepare.ps1 -NikrunHome .\.work\test-nikrun-home -IndexUrl .\index.json
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('auto', 'win64', 'linux', 'darwin')]
    [string]$TargetOs = 'auto',

    [Parameter()]
    [ValidateSet('auto', 'x86_64', 'aarch64')]
    [string]$TargetCpu = 'auto',

    [Parameter()]
    [string]$SdkVersion = 'latest',

    [Parameter()]
    [string]$SdkPath = '',

    [Parameter()]
    [string]$IndexUrl = '',

    [Parameter()]
    [Alias('SdkRepository')]
    [string]$Repository = 'nikrun/sdk',

    [Parameter()]
    [string]$SdkReleaseTag = 'latest',

    [Parameter()]
    [string]$NikrunHome = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CliRoot  = $PSScriptRoot
$RepoRoot = $CliRoot

if ([string]::IsNullOrWhiteSpace($Repository)) {
    $Repository = 'nikrun/sdk'
}

function Get-HostOsName {
    if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
        if ($IsWindows) { return 'win64' }
        if ($IsMacOS)   { return 'darwin' }
        if ($IsLinux)   { return 'linux' }
    }
    if ($env:OS -match 'Windows') {
        return 'win64'
    }
    $unameS = (& uname -s).Trim().ToLowerInvariant()
    if ($unameS -eq 'darwin') { return 'darwin' }
    return 'linux'
}

function Get-HostCpuName {
    param([string]$DetectedOs)

    if ($DetectedOs -eq 'win64') {
        $wowArch  = "$env:PROCESSOR_ARCHITEW6432".Trim().ToUpperInvariant()
        $procArch = "$env:PROCESSOR_ARCHITECTURE".Trim().ToUpperInvariant()
        if ($wowArch -eq 'ARM64' -or $procArch -eq 'ARM64') {
            return 'aarch64'
        }
        if ($wowArch -eq 'AMD64' -or $procArch -eq 'AMD64') {
            return 'x86_64'
        }
    }

    try {
        $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToUpperInvariant()
        if ($osArch -eq 'ARM64') { return 'aarch64' }
        if ($osArch -eq 'X64')   { return 'x86_64' }
    } catch {}

    if (Get-Command uname -ErrorAction SilentlyContinue) {
        $unameM = (& uname -m).Trim().ToLowerInvariant()
        if ($unameM -match 'aarch64|arm64') { return 'aarch64' }
        if ($unameM -match 'x86_64|amd64')  { return 'x86_64' }
    }

    throw "Unsupported or undetected 64-bit host CPU architecture."
}

function ConvertTo-ComparableVersion {
    param([string]$RawVersion)
    if ([string]::IsNullOrWhiteSpace($RawVersion)) {
        return [version]'0.0.0.0'
    }
    $clean = ($RawVersion.Trim() -replace '[^0-9.].*$', '').Trim('.')
    $parts = @($clean -split '\.' | Where-Object { $_ -match '^\d+$' })
    while ($parts.Count -lt 4) {
        $parts += '0'
    }
    return [version](($parts[0..3]) -join '.')
}

function Ensure-LinuxPrerequisites {
    if (-not (Get-Command ld -ErrorAction SilentlyContinue) -or
        -not (Get-Command as -ErrorAction SilentlyContinue) -or
        (-not (Get-Command curl -ErrorAction SilentlyContinue) -and -not (Get-Command wget -ErrorAction SilentlyContinue))) {
        if (Get-Command apt-get -ErrorAction SilentlyContinue) {
            Write-Host "`n==> Installing missing Linux build/link prerequisites..." -ForegroundColor Cyan
            & sudo apt-get update
            if ($LASTEXITCODE -ne 0) { throw "apt-get update failed with exit code $LASTEXITCODE" }
            & sudo apt-get install -y build-essential binutils curl unzip
            if ($LASTEXITCODE -ne 0) { throw "apt-get install failed with exit code $LASTEXITCODE" }
        } else {
            throw "Required Linux linker tools ('ld', 'as') or HTTP tools ('curl'/'wget') are missing from PATH."
        }
    }
}

function Resolve-LocalPathFromUrlOrPath {
    param([string]$Source)
    if ([string]::IsNullOrWhiteSpace($Source)) { return '' }
    if ($Source -match '^https?://') { return '' }
    if ($Source -match '^file://') {
        return ([System.Uri]$Source).LocalPath
    }
    return $Source
}

function Download-SdkIndexJson {
    param(
        [string]$ExplicitIndexUrl,
        [string]$RepoName,
        [string]$ReleaseTag,
        [string]$DestFile
    )

    $localIdx = Resolve-LocalPathFromUrlOrPath -Source $ExplicitIndexUrl
    if (-not [string]::IsNullOrWhiteSpace($localIdx)) {
        if (-not (Test-Path $localIdx)) {
            throw "Local index.json not found at: $localIdx"
        }
        Copy-Item -Path $localIdx -Destination $DestFile -Force
        return
    }

    if ([string]::IsNullOrWhiteSpace($ExplicitIndexUrl) -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "    Fetching index.json from GitHub Release '$ReleaseTag' ($RepoName) via gh..." -ForegroundColor Gray
        $prevErr = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & gh release download $ReleaseTag --repo $RepoName --pattern 'index.json' --output $DestFile --clobber 2>$null
        $ghExit = $LASTEXITCODE
        $ErrorActionPreference = $prevErr
        if ($ghExit -eq 0 -and (Test-Path $DestFile)) {
            return
        }
    }

    $effectiveUrl = if (-not [string]::IsNullOrWhiteSpace($ExplicitIndexUrl)) {
        $ExplicitIndexUrl
    } else {
        "https://github.com/$RepoName/releases/download/$ReleaseTag/index.json"
    }

    Write-Host "    Fetching index.json from: $effectiveUrl" -ForegroundColor Gray
    try {
        Invoke-WebRequest -Uri $effectiveUrl -OutFile $DestFile -UseBasicParsing
    } catch {
        throw "Failed to download index.json from '$effectiveUrl'. Ensure release '$ReleaseTag' exists in '$RepoName' (and GH_TOKEN is set if the repository is private), or pass -SdkPath. Details: $($_.Exception.Message)"
    }
}

function Download-SdkArchive {
    param(
        [object]$SdkEntry,
        [bool]$UsedDefaultIndex,
        [string]$RepoName,
        [string]$ReleaseTag,
        [string]$DestZip
    )

    $localZip = Resolve-LocalPathFromUrlOrPath -Source ([string]$SdkEntry.downloadUrl)
    if (-not [string]::IsNullOrWhiteSpace($localZip)) {
        if (-not (Test-Path $localZip)) {
            throw "Local SDK archive not found at: $localZip"
        }
        Copy-Item -Path $localZip -Destination $DestZip -Force
        return
    }

    if ($UsedDefaultIndex -and (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "    Downloading '$($SdkEntry.fileName)' from release '$ReleaseTag' ($RepoName) via gh..." -ForegroundColor Gray
        $prevErr = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & gh release download $ReleaseTag --repo $RepoName --pattern "$($SdkEntry.fileName)" --output $DestZip --clobber
        $ghExit = $LASTEXITCODE
        $ErrorActionPreference = $prevErr
        if ($ghExit -eq 0 -and (Test-Path $DestZip)) {
            return
        }
    }

    Write-Host "    Downloading '$($SdkEntry.fileName)' from: $($SdkEntry.downloadUrl)" -ForegroundColor Gray
    Invoke-WebRequest -Uri ([string]$SdkEntry.downloadUrl) -OutFile $DestZip -UseBasicParsing
}

function Install-AndVerifySdk {
    param(
        [string]$ZipPath = '',
        [string]$InstallRoot = '',
        [string]$ExistingSdkPath = '',
        [string]$SmokeWorkRoot = ''
    )

    $ResolvedSdkDir = $ExistingSdkPath
    if ([string]::IsNullOrWhiteSpace($ResolvedSdkDir)) {
        if (-not (Test-Path $ZipPath)) {
            throw "FPC SDK archive not found: $ZipPath"
        }
        $SdkName        = [System.IO.Path]::GetFileNameWithoutExtension($ZipPath)
        $ResolvedSdkDir = Join-Path $InstallRoot $SdkName

        Write-Host "`n==> Installing FPC SDK '$SdkName'..." -ForegroundColor Cyan
        Write-Host "    Source Archive : $ZipPath" -ForegroundColor Gray
        Write-Host "    Destination    : $ResolvedSdkDir" -ForegroundColor Gray

        if (Test-Path $ResolvedSdkDir) {
            Remove-Item -Recurse -Force $ResolvedSdkDir
        }
        New-Item -ItemType Directory -Force -Path $ResolvedSdkDir | Out-Null

        if (($env:OS -match 'Windows') -and (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
            & tar.exe -xf $ZipPath -C $ResolvedSdkDir
            if ($LASTEXITCODE -ne 0) { throw "Failed to extract $ZipPath via tar.exe" }
        } elseif (Get-Command unzip -ErrorAction SilentlyContinue) {
            & unzip -q $ZipPath -d $ResolvedSdkDir
            if ($LASTEXITCODE -ne 0) { throw "Failed to extract $ZipPath via unzip" }
        } else {
            Expand-Archive -Path $ZipPath -DestinationPath $ResolvedSdkDir -Force
        }

        $ManifestFile = Join-Path $ResolvedSdkDir 'sdk-manifest.json'
        if (-not (Test-Path $ManifestFile)) {
            throw "Invalid FPC SDK archive: sdk-manifest.json missing in $ResolvedSdkDir"
        }
        $Manifest = Get-Content $ManifestFile -Raw | ConvertFrom-Json

        $BinDir   = Join-Path $ResolvedSdkDir ($Manifest.paths.binDir -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar)
        $UnitsDir = Join-Path $ResolvedSdkDir ($Manifest.paths.unitsDir -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar)
        $FpcCfg   = Join-Path $BinDir 'fpc.cfg'

        if ($Manifest.targetOs -ne 'win64' -and (Get-Command chmod -ErrorAction SilentlyContinue)) {
            & chmod -R +x $BinDir
        }

        $NormalizedBin   = $BinDir.Replace('\', '/')
        $NormalizedUnits = $UnitsDir.Replace('\', '/')

        $ExtraPlatformCfg = ""
        if ($Manifest.targetOs -eq 'darwin') {
            $darwinLines = @()
            $minMacOs = if ($Manifest.targetCpu -eq 'aarch64') { '11.0' } else { '10.15' }
            $darwinLines += "-WM$minMacOs"
            if (Get-Command xcrun -ErrorAction SilentlyContinue) {
                $macSdk = (& xcrun --show-sdk-path 2>$null | Select-Object -First 1).Trim()
                if (-not [string]::IsNullOrWhiteSpace($macSdk)) {
                    $darwinLines += "-XR$macSdk"
                    if (Test-Path "$macSdk/usr/lib") {
                        $darwinLines += "-Fl$macSdk/usr/lib"
                    }
                }
            }
            if (Test-Path '/Library/Developer/CommandLineTools/usr/bin') {
                $darwinLines += "-FD/Library/Developer/CommandLineTools/usr/bin"
            }
            $ExtraPlatformCfg = "`n# macOS SDK sysroot, library stubs, and toolchain paths`n" + ($darwinLines -join "`n")
        } elseif ($Manifest.targetOs -eq 'linux') {
            $linuxLibLines = @()
            foreach ($candidate in @(
                "/lib/$($Manifest.targetCpu)-linux-gnu",
                "/usr/lib/$($Manifest.targetCpu)-linux-gnu",
                "/lib64",
                "/usr/lib64",
                "/lib",
                "/usr/lib"
            )) {
                if (Test-Path $candidate) {
                    $linuxLibLines += "-Fl$candidate"
                }
            }
            if (Get-Command gcc -ErrorAction SilentlyContinue) {
                $crtBegin = (& gcc -print-file-name=crtbegin.o 2>$null | Select-Object -First 1).Trim()
                if (-not [string]::IsNullOrWhiteSpace($crtBegin) -and (Test-Path $crtBegin)) {
                    $gccLibDir = Split-Path -Parent $crtBegin
                    $linuxLibLines += "-Fl$gccLibDir"
                }
            }
            if ($Manifest.targetCpu -eq 'aarch64') {
                $linuxLibLines += "-k--defsym=__libc_csu_init=0"
                $linuxLibLines += "-k--defsym=__libc_csu_fini=0"
            }
            if ($linuxLibLines.Count -gt 0) {
                $ExtraPlatformCfg = "`n# System C library search paths`n" + ($linuxLibLines -join "`n")
            }
        }

        $CfgContent = @"
# ==============================================================================
# Nikrun Portable FreePascal SDK Configuration (Auto-generated)
# SDK: $($Manifest.sdkId) (FPC $($Manifest.fpcVersion), $($Manifest.targetTriplet))
# ==============================================================================

# Default to Object Pascal mode with AnsiStrings unless overridden in source
-Mobjfpc
-Sh
-Sc
-Si

# Enable DWARF debug info & line info when -dDEBUG is passed, strip in -dRELEASE
#IFDEF DEBUG
-gl
-gw2
-Cr
-Ci
-Co
#ENDIF

#IFDEF RELEASE
-O2
-Xs
-CX
-XX
#ENDIF

# Unit search paths (RTL & Packages)
-Fu$NormalizedUnits
-Fu$NormalizedUnits/*
-Fu$NormalizedUnits/rtl

# Binary & Binutils search path (ld, as, ar, windres)
-FD$NormalizedBin

# Library search path
-Fl$NormalizedUnits$ExtraPlatformCfg

# Display errors, warnings, and notes with full file paths for IDE Problem Matchers
-viwn
-vb
-l-
"@

        $CfgContent | Set-Content -Path $FpcCfg -Encoding ASCII
        $UnixEtcDir = Join-Path (Split-Path -Parent $BinDir) 'etc'
        New-Item -ItemType Directory -Force -Path $UnixEtcDir | Out-Null
        $CfgContent | Set-Content -Path (Join-Path $UnixEtcDir 'fpc.cfg') -Encoding ASCII
        Write-Host " [OK] Generated clean fpc.cfg at: $FpcCfg" -ForegroundColor Green
    }

    # Verify SDK manifest & run compiler smoke test
    $ManifestPath = Join-Path $ResolvedSdkDir 'sdk-manifest.json'
    if (-not (Test-Path $ManifestPath)) {
        throw "Verification failed: sdk-manifest.json missing in $ResolvedSdkDir"
    }
    $Manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
    $FpcBin   = Join-Path $ResolvedSdkDir ($Manifest.paths.fpcBinary -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar)
    $FpcCfg   = Join-Path (Join-Path $ResolvedSdkDir ($Manifest.paths.binDir -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar)) 'fpc.cfg'

    foreach ($reqPath in @($FpcBin, $FpcCfg)) {
        if (-not (Test-Path $reqPath)) {
            throw "Verification failed: expected SDK file missing at $reqPath"
        }
    }

    $TestWorkDir = Join-Path $SmokeWorkRoot 'sdk-smoke-test'
    if (Test-Path $TestWorkDir) { Remove-Item -Recurse -Force $TestWorkDir }
    $TestSrcDir   = Join-Path $TestWorkDir 'src'
    $TestCacheDir = Join-Path $TestWorkDir '.cache'
    $TestBinDir   = Join-Path $TestWorkDir 'bin'
    New-Item -ItemType Directory -Force -Path $TestSrcDir, $TestCacheDir, $TestBinDir | Out-Null

    $SmokePas = Join-Path $TestSrcDir 'smoketest.pas'
    @"
program smoketest;
{`$mode objfpc}{`$H+}
uses SysUtils;
begin
  WriteLn('OK:', {`$I %FPCVERSION%});
end.
"@ | Set-Content -Path $SmokePas -Encoding UTF8

    & $FpcBin -n "@$FpcCfg" -dDEBUG "-FE$TestBinDir" "-FU$TestCacheDir" $SmokePas | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "SDK smoke test compilation failed with exit code $LASTEXITCODE"
    }
    $ExeExt   = if ($Manifest.targetOs -eq 'win64') { '.exe' } else { '' }
    $SmokeExe = Join-Path $TestBinDir "smoketest$ExeExt"
    $SmokeOut = (& $SmokeExe).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $SmokeOut.StartsWith('OK:')) {
        throw "SDK smoke test execution failed: $SmokeOut"
    }
    Write-Host " [OK] Verified SDK compiler smoke test ($SmokeOut)" -ForegroundColor Green

    return $ResolvedSdkDir
}

# 1. Detect and validate target OS & 64-bit CPU
$HostOs  = Get-HostOsName
$HostCpu = Get-HostCpuName -DetectedOs $HostOs

$EffectiveOs  = if ($TargetOs -eq 'auto')  { $HostOs }  else { $TargetOs }
$EffectiveCpu = if ($TargetCpu -eq 'auto') { $HostCpu } else { $TargetCpu }

if ($EffectiveOs -ne $HostOs -or $EffectiveCpu -ne $HostCpu) {
    throw "Requested target '$EffectiveCpu-$EffectiveOs' does not match current host runner '$HostCpu-$HostOs'."
}

$TargetTriplet = "$EffectiveCpu-$EffectiveOs"

$HomeDir = if ($EffectiveOs -eq 'win64' -and $env:USERPROFILE) {
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

$SdksDir     = [System.IO.Path]::Combine($EffectiveNikHome, 'sdks')
$SdkCacheDir = [System.IO.Path]::Combine($RepoRoot, '.work', 'sdk-cache')
$PrepWorkDir = [System.IO.Path]::Combine($RepoRoot, '.work', 'prepare', $TargetTriplet)

Write-Host "`n==> Preparing Nikrun Free Pascal SDK ($TargetTriplet)..." -ForegroundColor Cyan
Write-Host "    Toolchain Root : $EffectiveNikHome" -ForegroundColor Gray

if ($EffectiveOs -eq 'linux') {
    Ensure-LinuxPrerequisites
}

New-Item -ItemType Directory -Force -Path $SdksDir, $SdkCacheDir, $PrepWorkDir | Out-Null

# 2. Resolve, download, SHA-256 verify, and install the newest Nikrun FPC SDK
$InstalledSdkDir = ''

if (-not [string]::IsNullOrWhiteSpace($SdkPath)) {
    $ResolvedSdkInput = Resolve-FullPsPath $SdkPath
    if (-not (Test-Path $ResolvedSdkInput)) {
        throw "Specified -SdkPath does not exist: $ResolvedSdkInput"
    }

    if ((Get-Item $ResolvedSdkInput).PSIsContainer) {
        Write-Host "    Using explicit local SDK directory: $ResolvedSdkInput" -ForegroundColor Gray
        $InstalledSdkDir = Install-AndVerifySdk -ExistingSdkPath $ResolvedSdkInput -SmokeWorkRoot $PrepWorkDir
    } else {
        Write-Host "    Installing explicit local SDK archive: $ResolvedSdkInput" -ForegroundColor Gray
        $InstalledSdkDir = Install-AndVerifySdk -ZipPath $ResolvedSdkInput -InstallRoot $SdksDir -SmokeWorkRoot $PrepWorkDir
    }
} else {
    $IndexFile        = [System.IO.Path]::Combine($PrepWorkDir, 'index.json')
    $UsedDefaultIndex = [string]::IsNullOrWhiteSpace($IndexUrl)

    Download-SdkIndexJson `
        -ExplicitIndexUrl $IndexUrl `
        -RepoName         $Repository `
        -ReleaseTag       $SdkReleaseTag `
        -DestFile         $IndexFile

    $IndexData = Get-Content -Path $IndexFile -Raw | ConvertFrom-Json
    $AllSdks   = @($IndexData.sdks)

    $MatchingSdks = @(
        $AllSdks | Where-Object {
            ([string]$_.targetTriplet -eq $TargetTriplet) -and
            ($SdkVersion -eq 'latest' -or [string]$_.fpcVersion -eq $SdkVersion)
        }
    )

    if ($MatchingSdks.Count -eq 0) {
        $available = @(
            $AllSdks | ForEach-Object { "$($_.fpcVersion) ($($_.targetTriplet))" }
        ) -join ', '
        throw "No prebuilt Nikrun FPC SDK in index.json matched target='$TargetTriplet' and version='$SdkVersion'. Available: [$available]"
    }

    $SelectedSdk = $MatchingSdks |
        Sort-Object `
            @{ Expression = { ConvertTo-ComparableVersion ([string]$_.fpcVersion) }; Descending = $true }, `
            @{ Expression = { [string]$_.builtAtUtc }; Descending = $true }, `
            @{ Expression = { [string]$_.sdkId }; Descending = $true } |
        Select-Object -First 1

    $ExpectedSha = ([string]$SelectedSdk.sha256).Trim().ToLowerInvariant()
    Write-Host " [OK] Selected newest SDK: $($SelectedSdk.sdkId) (FPC $($SelectedSdk.fpcVersion), ref '$($SelectedSdk.gitRef)')" -ForegroundColor Green

    $CachedZip    = [System.IO.Path]::Combine($SdkCacheDir, [string]$SelectedSdk.fileName)
    $NeedDownload = $true
    if ((Test-Path $CachedZip) -and (-not [string]::IsNullOrWhiteSpace($ExpectedSha))) {
        $ExistingSha = (Get-FileHash -Path $CachedZip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($ExistingSha -eq $ExpectedSha) {
            Write-Host " [OK] Using SHA-256 verified cached SDK archive: $CachedZip" -ForegroundColor Green
            $NeedDownload = $false
        } else {
            Remove-Item -Force $CachedZip -ErrorAction SilentlyContinue
        }
    }

    if ($NeedDownload) {
        $PartZip = "$CachedZip.partial"
        if (Test-Path $PartZip) { Remove-Item -Force $PartZip -ErrorAction SilentlyContinue }

        Download-SdkArchive `
            -SdkEntry         $SelectedSdk `
            -UsedDefaultIndex $UsedDefaultIndex `
            -RepoName         $Repository `
            -ReleaseTag       $SdkReleaseTag `
            -DestZip          $PartZip

        if (-not [string]::IsNullOrWhiteSpace($ExpectedSha)) {
            $ActualSha = (Get-FileHash -Path $PartZip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($ActualSha -ne $ExpectedSha) {
                Remove-Item -Force $PartZip -ErrorAction SilentlyContinue
                throw "SHA-256 checksum mismatch for '$($SelectedSdk.fileName)': expected $ExpectedSha, got $ActualSha"
            }
            Write-Host " [OK] Verified SDK SHA-256: $ActualSha" -ForegroundColor Green
        }

        Move-Item -Path $PartZip -Destination $CachedZip -Force
    }

    $InstalledSdkDir = Install-AndVerifySdk -ZipPath $CachedZip -InstallRoot $SdksDir -SmokeWorkRoot $PrepWorkDir
}

# 3. Verify prepared SDK manifest
$ManifestPath = [System.IO.Path]::Combine($InstalledSdkDir, 'sdk-manifest.json')
if (-not (Test-Path $ManifestPath)) {
    throw "Prepared SDK manifest missing at: $ManifestPath"
}
$Manifest = Get-Content -Path $ManifestPath -Raw | ConvertFrom-Json

Write-Host "`n [OK] SDK preparation complete: $($Manifest.sdkId) (FPC $($Manifest.fpcVersion))" -ForegroundColor Green
return $InstalledSdkDir
