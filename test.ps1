<#
.SYNOPSIS
    Runs end-to-end automated integration tests for the nik CLI (`nik sdk` commands).

.EXAMPLE
    .\test.ps1
    .\test.ps1 -SkipBuild
    .\test.ps1 -SkipRealArchive
#>
[CmdletBinding()]
param(
    [Parameter()]
    [switch]$SkipBuild,

    [Parameter()]
    [switch]$SkipRealArchive,

    [Parameter()]
    [string]$NikBinaryPath = '',

    [Parameter()]
    [string]$RealSdkZipPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$CliRoot  = $PSScriptRoot
$RepoRoot = $CliRoot
$IsWin    = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
    [bool]$IsWindows
} else {
    ($env:OS -match 'Windows')
}

if (-not [string]::IsNullOrWhiteSpace($NikBinaryPath)) {
    $NikExe = [System.IO.Path]::GetFullPath($NikBinaryPath)
} elseif (-not $SkipBuild) {
    $NikExe = & (Join-Path $CliRoot 'build.ps1') -Profile debug -RunTests:$false -GenerateSpecs:$false
} else {
    $ExeExt = if ($IsWin) { '.exe' } else { '' }
    $NikExe = [System.IO.Path]::Combine($CliRoot, 'bin', "nik$ExeExt")
}

if (-not (Test-Path $NikExe)) {
    throw "nik CLI binary not found at $NikExe"
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
    Write-Host " [PASS] $Message" -ForegroundColor Green
}

function Invoke-Nik {
    param(
        [string]$NikHome,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $allArgs = @('--no-color', '--nikrun-home', $NikHome) + $Arguments
    $prevErr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $outLines = & $NikExe @allArgs 2>&1
    $code = $LASTEXITCODE
    if ($AllowFailure) {
        $global:LASTEXITCODE = 0
    }
    $ErrorActionPreference = $prevErr

    $outText = ($outLines | ForEach-Object { "$_" }) -join "`n"
    if ((-not $AllowFailure) -and ($code -ne 0)) {
        throw "Command failed (exit $code): nik $($Arguments -join ' ')`nOutput:`n$outText"
    }

    return [PSCustomObject]@{
        ExitCode = $code
        Output   = $outText
    }
}

# Detect host OS & CPU matching nik.platform.pas
if ($IsWin) {
    $HostOs = 'win64'
    $ArchRaw = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $HostCpu = if ($ArchRaw -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
} else {
    $unameS = (& uname -s).Trim().ToLowerInvariant()
    $unameM = (& uname -m).Trim().ToLowerInvariant()
    $HostOs = if ($unameS -eq 'darwin') { 'darwin' } else { 'linux' }
    $HostCpu = if ($unameM -match 'arm64|aarch64') { 'aarch64' } else { 'x86_64' }
}

$WorkDir   = [System.IO.Path]::Combine($RepoRoot, '.work', 'cli-test')
if (Test-Path $WorkDir) {
    Remove-Item -Recurse -Force $WorkDir
}
$TestHome  = Join-Path $WorkDir 'nikrun-home'
$ServerDir = Join-Path $WorkDir 'http-root'
$StageRoot = Join-Path $WorkDir 'mock-stage'
New-Item -ItemType Directory -Force -Path $TestHome, $ServerDir, $StageRoot | Out-Null

function New-MockSdkZip {
    param(
        [string]$Version,
        [string]$GitRef,
        [string]$GitCommit,
        [string]$TargetOs,
        [string]$TargetCpu
    )

    $shortSha = $GitCommit.Substring(0, 8).ToLowerInvariant()
    $triplet  = "$TargetCpu-$TargetOs"
    $sdkId    = "nikrun-fpc-sdk-$Version-$shortSha-$triplet"
    $dir      = Join-Path $StageRoot $sdkId
    $binDir   = [System.IO.Path]::Combine($dir, 'bin', $triplet)
    $unitDir  = [System.IO.Path]::Combine($dir, 'units', $triplet, 'rtl')
    $rtlSrc   = [System.IO.Path]::Combine($dir, 'source', 'rtl')
    $pkgSrc   = [System.IO.Path]::Combine($dir, 'source', 'packages')
    New-Item -ItemType Directory -Force -Path $binDir, $unitDir, $rtlSrc, $pkgSrc | Out-Null

    $fpcName = if ($TargetOs -eq 'win64') { 'fpc.exe' } else { 'fpc' }
    $ppcName = if ($TargetCpu -eq 'aarch64') {
        if ($TargetOs -eq 'win64') { 'ppca64.exe' } else { 'ppca64' }
    } else {
        if ($TargetOs -eq 'win64') { 'ppcx64.exe' } else { 'ppcx64' }
    }

    "mock-fpc-$Version" | Set-Content -Path (Join-Path $binDir $fpcName) -Encoding ASCII
    "mock-ppc-$Version" | Set-Content -Path (Join-Path $binDir $ppcName) -Encoding ASCII
    "unit system; interface implementation end." | Set-Content -Path (Join-Path $rtlSrc 'system.pas') -Encoding ASCII
    "unit fpjson; interface implementation end." | Set-Content -Path (Join-Path $pkgSrc 'fpjson.pp') -Encoding ASCII

    $manifest = [ordered]@{
        schemaVersion  = 1
        sdkId          = $sdkId
        fpcVersion     = $Version
        gitRepo        = 'https://gitlab.com/freepascal.org/fpc/source.git'
        gitRef         = $GitRef
        gitCommit      = $GitCommit.ToLowerInvariant()
        gitCommitShort = $shortSha
        targetOs       = $TargetOs
        targetCpu      = $TargetCpu
        targetTriplet  = $triplet
        builtAtUtc     = '2026-11-10T12:00:00Z'
        paths          = [ordered]@{
            binDir            = "bin/$triplet"
            fpcBinary         = "bin/$triplet/$fpcName"
            ppcBinary         = "bin/$triplet/$ppcName"
            fpcmkcfgBinary    = "bin/$triplet/fpcmkcfg"
            unitsDir          = "units/$triplet"
            rtlSourceDir      = "source/rtl"
            packagesSourceDir = "source/packages"
        }
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $dir 'sdk-manifest.json') -Encoding UTF8

    $zipPath = Join-Path $ServerDir "$sdkId.zip"
    if ($IsWin -and (Get-Command tar.exe -ErrorAction SilentlyContinue)) {
        Push-Location $dir
        try { & tar.exe -a -cf $zipPath * | Out-Null } finally { Pop-Location }
    } else {
        Compress-Archive -Path (Join-Path $dir '*') -DestinationPath $zipPath -Force
    }

    $sha = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $len = (Get-Item $zipPath).Length

    return [PSCustomObject]@{
        SdkId         = $sdkId
        FpcVersion    = $Version
        GitRef        = $GitRef
        GitCommit     = $GitCommit.ToLowerInvariant()
        TargetOs      = $TargetOs
        TargetCpu     = $TargetCpu
        TargetTriplet = $triplet
        FileName      = "$sdkId.zip"
        ZipPath       = $zipPath
        SizeBytes     = $len
        Sha256        = $sha
    }
}

Write-Host "`n==> Preparing mock SDK archives and local HTTP test server..." -ForegroundColor Cyan
$Arch322 = if ($HostOs -eq 'win64' -and $HostCpu -eq 'aarch64') { 'x86_64' } else { $HostCpu }
$Mock322 = New-MockSdkZip -Version '3.2.2' -GitRef 'release_3_2_2' -GitCommit '0d122c49534b480be9284c21bd60b53d99904346' -TargetOs $HostOs -TargetCpu $Arch322
$Mock331 = New-MockSdkZip -Version '3.3.1' -GitRef 'main'          -GitCommit '4774b8cd0e7522c0af70a4d3e2a740908e767b61' -TargetOs $HostOs -TargetCpu $HostCpu
$MockBad = New-MockSdkZip -Version '9.9.9' -GitRef 'corrupt'       -GitCommit 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' -TargetOs $HostOs -TargetCpu $HostCpu

# Start lightweight local TCP HTTP server on an OS-assigned ephemeral port (no admin privileges or port-probe race)
$PortFile = Join-Path $WorkDir 'server.port'
$ServerJob = Start-Job -ArgumentList $ServerDir, $PortFile -ScriptBlock {
    param([string]$RootDir, [string]$BoundPortFile)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $boundPort = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    [System.IO.File]::WriteAllText($BoundPortFile, "$boundPort", [System.Text.Encoding]::ASCII)
    try {
        while ($true) {
            if (-not $listener.Pending()) {
                Start-Sleep -Milliseconds 15
                continue
            }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::ASCII, $false, 1024, $true)
                $reqLine = $reader.ReadLine()
                while ($true) {
                    $hdr = $reader.ReadLine()
                    if ([string]::IsNullOrEmpty($hdr)) { break }
                }
                if (-not [string]::IsNullOrEmpty($reqLine)) {
                    $parts = $reqLine -split ' '
                    $relPath = ($parts[1].TrimStart('/')) -replace '\?.*$', ''
                    $filePath = Join-Path $RootDir $relPath
                    if (Test-Path $filePath -PathType Leaf) {
                        $bytes = [System.IO.File]::ReadAllBytes($filePath)
                        $respHdr = "HTTP/1.1 200 OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                        $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($respHdr)
                        $stream.Write($hdrBytes, 0, $hdrBytes.Length)
                        $stream.Write($bytes, 0, $bytes.Length)
                    } else {
                        $body = [System.Text.Encoding]::ASCII.GetBytes("Not Found")
                        $respHdr = "HTTP/1.1 404 Not Found`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n"
                        $hdrBytes = [System.Text.Encoding]::ASCII.GetBytes($respHdr)
                        $stream.Write($hdrBytes, 0, $hdrBytes.Length)
                        $stream.Write($body, 0, $body.Length)
                    }
                    $stream.Flush()
                }
            } catch {
                # Ignore transient client disconnect errors so the test server stays alive
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
    }
}

$Port = 0
$PortWaitSw = [System.Diagnostics.Stopwatch]::StartNew()
while ($PortWaitSw.ElapsedMilliseconds -lt 15000) {
    if ($ServerJob.State -in @('Failed', 'Stopped', 'Blocked')) {
        $jobErr = (Receive-Job -Job $ServerJob -ErrorAction Continue 2>&1) -join "`n"
        throw "Mock HTTP server job terminated unexpectedly (state=$($ServerJob.State)): $jobErr"
    }
    if (Test-Path $PortFile) {
        $rawPort = ([System.IO.File]::ReadAllText($PortFile)).Trim()
        if ($rawPort -match '^\d+$') {
            $Port = [int]$rawPort
            break
        }
    }
    Start-Sleep -Milliseconds 50
}
if ($Port -le 0) {
    Remove-Job -Job $ServerJob -Force -ErrorAction SilentlyContinue | Out-Null
    throw "Timed out waiting for local HTTP mock server to bind an ephemeral port."
}

$BaseUrl = "http://127.0.0.1:$Port"
$IndexObj = [ordered]@{
    schemaVersion = 1
    releaseTag    = 'fpc-sdk-test'
    updatedAtUtc  = '2026-11-10T12:00:00Z'
    sdks          = @(
        [ordered]@{
            sdkId         = $Mock322.SdkId
            fpcVersion    = $Mock322.FpcVersion
            gitRef        = $Mock322.GitRef
            gitCommit     = $Mock322.GitCommit
            targetOs      = $Mock322.TargetOs
            targetCpu     = $Mock322.TargetCpu
            targetTriplet = $Mock322.TargetTriplet
            builtAtUtc    = '2026-11-10T12:00:00Z'
            fileName      = $Mock322.FileName
            sizeBytes     = $Mock322.SizeBytes
            sha256        = $Mock322.Sha256
            downloadUrl   = "$BaseUrl/$($Mock322.FileName)"
        },
        [ordered]@{
            sdkId         = $Mock331.SdkId
            fpcVersion    = $Mock331.FpcVersion
            gitRef        = $Mock331.GitRef
            gitCommit     = $Mock331.GitCommit
            targetOs      = $Mock331.TargetOs
            targetCpu     = $Mock331.TargetCpu
            targetTriplet = $Mock331.TargetTriplet
            builtAtUtc    = '2026-11-10T12:00:00Z'
            fileName      = $Mock331.FileName
            sizeBytes     = $Mock331.SizeBytes
            sha256        = $Mock331.Sha256
            downloadUrl   = "$BaseUrl/$($Mock331.FileName)"
        },
        [ordered]@{
            sdkId         = $MockBad.SdkId
            fpcVersion    = '9.9.9'
            gitRef        = 'corrupt'
            gitCommit     = $MockBad.GitCommit
            targetOs      = $MockBad.TargetOs
            targetCpu     = $MockBad.TargetCpu
            targetTriplet = $MockBad.TargetTriplet
            builtAtUtc    = '2026-11-10T12:00:00Z'
            fileName      = $MockBad.FileName
            sizeBytes     = $MockBad.SizeBytes
            sha256        = ('0' * 64)
            downloadUrl   = "$BaseUrl/$($MockBad.FileName)"
        }
    )
}
$IndexPath = Join-Path $ServerDir 'index.json'
$IndexObj | ConvertTo-Json -Depth 6 | Set-Content -Path $IndexPath -Encoding UTF8
$IndexUrl = "$BaseUrl/index.json"

$ServerReady = $false
$ReadySw = [System.Diagnostics.Stopwatch]::StartNew()
while ($ReadySw.ElapsedMilliseconds -lt 10000) {
    try {
        $probeResp = Invoke-WebRequest -Uri $IndexUrl -UseBasicParsing -TimeoutSec 2
        if ($probeResp.StatusCode -eq 200) {
            $ServerReady = $true
            break
        }
    } catch {
        Start-Sleep -Milliseconds 50
    }
}
if (-not $ServerReady) {
    Remove-Job -Job $ServerJob -Force -ErrorAction SilentlyContinue | Out-Null
    throw "Local HTTP mock server at $IndexUrl did not become ready within 10s."
}

try {
    Write-Host "`n==> Running nik CLI & SDK command tests..." -ForegroundColor Cyan

    # 1. Version & Help
    $expectedCleanVer = [regex]::Escape(((Get-Content -Path (Join-Path $CliRoot 'version.txt') -Raw).Trim() -replace '^v', ''))
    $ver = Invoke-Nik -NikHome $TestHome -Arguments @('--version')
    Assert-True ($ver.Output -match "^nik v?$expectedCleanVer\b") 'nik --version prints CLI version'

    $help = Invoke-Nik -NikHome $TestHome -Arguments @('--help')
    Assert-True ($help.Output -match 'COMMANDS:' -and $help.Output -match 'init' -and $help.Output -match 'sdk') 'nik --help lists init and sdk commands'

    $sdkHelp = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', '--help')
    Assert-True ($sdkHelp.Output -match 'install' -and $sdkHelp.Output -notmatch '\bdefault\b' -and $sdkHelp.Output -match 'uninstall' -and $sdkHelp.Output -match 'info') 'nik sdk --help lists subcommands without removed default command'

    # 2. Empty local list & verify nik sdk default is removed
    $emptyJson = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--json')).Output | ConvertFrom-Json
    Assert-True ($null -eq $emptyJson.PSObject.Properties['defaultSdkId'] -and $emptyJson.sdks.Count -eq 0) 'nik sdk list --json reports empty state without defaultSdkId'

    $removedDef = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'default') -AllowFailure
    Assert-True ($removedDef.ExitCode -ne 0 -and $removedDef.Output -match "Unknown sdk subcommand 'default'") 'nik sdk default subcommand is removed cleanly'

    # 2b. nik init without installed SDK and without --fpc / template.yaml fails cleanly
    $EmptyInitDir = Join-Path $WorkDir 'init-no-sdk'
    $initNoSdkRes = Invoke-Nik -NikHome $TestHome -Arguments @('init', $EmptyInitDir) -AllowFailure
    Assert-True ($initNoSdkRes.ExitCode -ne 0 -and $initNoSdkRes.Output -match 'Cannot determine Free Pascal version') 'nik init fails cleanly when no SDK is installed and no --fpc or template.yaml is given'

    # 3. Remote list over HTTP
    $remJson = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--remote', '--index-url', $IndexUrl, '--json')).Output | ConvertFrom-Json
    Assert-True ($remJson.sdks.Count -eq 3) 'nik sdk list --remote fetches remote index over HTTP'
    Assert-True ($null -eq $remJson.sdks[0].PSObject.Properties['channel'] -and $null -eq $remJson.sdks[0].PSObject.Properties['default']) 'nik sdk list --remote --json omits removed channel and default properties'

    $rem322 = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--remote', '--version', '3.2.2', '--index-url', $IndexUrl, '--json')).Output | ConvertFrom-Json
    Assert-True ($rem322.sdks.Count -eq 1 -and $rem322.sdks[0].fpcVersion -eq '3.2.2') 'nik sdk list --remote --version 3.2.2 filters properly'

    # 4. Install 3.2.2 over HTTP (stateless: no config.json written)
    $inst322 = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', '3.2.2', '--index-url', $IndexUrl)
    Assert-True ($inst322.Output -match 'Verified SHA-256' -and $inst322.Output -notmatch 'Default SDK') 'nik sdk install 3.2.2 downloads and verifies SHA-256 without setting a default SDK'

    $cfgPath = Join-Path $TestHome 'config.json'
    Assert-True (-not (Test-Path $cfgPath)) 'nik sdk install does not create global config.json'

    $genFpcCfg = ((Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', '3.2.2', '--json')).Output | ConvertFrom-Json).paths.fpcCfg
    Assert-True (Test-Path $genFpcCfg) 'fpc.cfg generated in SDK bin directory'

    # 5. Re-running install without --force skips re-download
    $reInst = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', '3.2.2', '--index-url', $IndexUrl)
    Assert-True ($reInst.Output -match 'already installed') 'nik sdk install skips re-download when already installed'

    # 6. Branch names, SemVer ranges, and SDK IDs are rejected by nik sdk install
    $branchRej = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', 'main', '--index-url', $IndexUrl) -AllowFailure
    Assert-True ($branchRej.ExitCode -ne 0 -and $branchRej.Output -match 'Invalid Free Pascal SDK version') 'nik sdk install rejects Git branch names (e.g. main)'

    $idRej = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', $Mock331.SdkId, '--index-url', $IndexUrl) -AllowFailure
    Assert-True ($idRej.ExitCode -ne 0 -and $idRej.Output -match 'Invalid Free Pascal SDK version') 'nik sdk install rejects SDK IDs and requires exact version or local path'

    $noDefRej = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', '3.3.1', '--no-default', '--index-url', $IndexUrl) -AllowFailure
    Assert-True ($noDefRej.ExitCode -ne 0 -and $noDefRej.Output -match 'Unknown option') 'nik sdk install rejects removed --no-default flag'

    # 7. Install 3.3.1 alongside 3.2.2
    $inst331 = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', '3.3.1', '--index-url', $IndexUrl)
    $listTwo = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--json')).Output | ConvertFrom-Json
    Assert-True ($listTwo.sdks.Count -eq 2 -and $null -eq $listTwo.PSObject.Properties['defaultSdkId'] -and $null -eq $listTwo.sdks[0].PSObject.Properties['default']) 'nik sdk list --json lists both installed SDKs cleanly without default properties'

    # 7b. Human table layout checks (VERSION TARGET PATH only)
    $localHuman = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list')).Output
    Assert-True ($localHuman -match '(?m)^VERSION\s+TARGET\s+PATH\r?$' -and $localHuman -cnotmatch 'DEFAULT' -and $localHuman -cnotmatch 'SDK ID') 'nik sdk list displays VERSION TARGET PATH header without DEFAULT or SDK ID'

    $remoteHuman = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--remote', '--index-url', $IndexUrl)).Output
    Assert-True ($remoteHuman -match '(?m)^VERSION\s+TARGET\s+COMMIT\s+SIZE\s+INSTALLED$' -and $remoteHuman -notmatch 'SDK ID' -and $remoteHuman -notmatch 'available') 'nik sdk list --remote displays clean VERSION TARGET COMMIT SIZE INSTALLED header'
    Assert-True ($remoteHuman -match '(?m)^3\.2\.2\s+.*\s+Yes$' -and $remoteHuman -match '(?m)^9\.9\.9\s+(?!.*Yes).*$') 'nik sdk list --remote marks installed SDKs with Yes and leaves uninstalled blank'

    # 8. nik sdk info requires explicit <version> and rejects missing argument or SDK IDs
    $infoNoArg = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info') -AllowFailure
    Assert-True ($infoNoArg.ExitCode -ne 0 -and $infoNoArg.Output -match 'Missing Free Pascal SDK version') 'nik sdk info requires explicit version argument'

    $infoById = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', $Mock322.SdkId) -AllowFailure
    Assert-True ($infoById.ExitCode -ne 0 -and $infoById.Output -match 'Invalid Free Pascal SDK version') 'nik sdk info rejects SDK IDs and only accepts exact versions'

    $info322 = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', '3.2.2', '--json')).Output | ConvertFrom-Json
    Assert-True ($info322.sdkId -eq $Mock322.SdkId -and $info322.gitCommit -eq $Mock322.GitCommit -and $null -eq $info322.PSObject.Properties['default'] -and $info322.healthy -eq $true) 'nik sdk info 3.2.2 inspects SDK, gitCommit, and verifies health'

    $info331 = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', '3.3.1', '--json')).Output | ConvertFrom-Json
    Assert-True ($info331.sdkId -eq $Mock331.SdkId -and $info331.gitRef -eq 'main' -and $info331.gitCommit -eq $Mock331.GitCommit -and $info331.healthy -eq $true) 'nik sdk info 3.3.1 inspects installed 3.3.1 SDK'

    # 9. Corrupted SHA-256 checksum rejection
    $badRes = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', '9.9.9', '--index-url', $IndexUrl) -AllowFailure
    Assert-True ($badRes.ExitCode -ne 0 -and $badRes.Output -match 'SHA-256 checksum mismatch') 'nik sdk install rejects archive with invalid SHA-256 checksum'
    Assert-True (-not (Test-Path (Join-Path (Join-Path $TestHome 'sdks') $MockBad.SdkId))) 'Rejected archive leaves no partial SDK directory behind'

    # 10. nik init & ~/.nikrun/template.yaml tests
    $InitProgDir = Join-Path $WorkDir 'init-default-prog'
    $initProgJson = (Invoke-Nik -NikHome $TestHome -Arguments @('init', $InitProgDir, '--json')).Output | ConvertFrom-Json
    Assert-True ($initProgJson.success -eq $true -and $initProgJson.kind -eq 'program' -and $initProgJson.fpcVersion -eq '3.3.1' -and $initProgJson.usedTemplate -eq $false) 'nik init detects highest installed SDK version when no template.yaml exists'
    Assert-True ((Test-Path (Join-Path $InitProgDir 'nik.yaml')) -and (Test-Path (Join-Path (Join-Path $InitProgDir 'src') 'main.pas')) -and (Test-Path (Join-Path $InitProgDir '.gitignore'))) 'nik init creates nik.yaml, src/main.pas, and .gitignore'

    $dupInit = Invoke-Nik -NikHome $TestHome -Arguments @('init', $InitProgDir) -AllowFailure
    Assert-True ($dupInit.ExitCode -ne 0 -and $dupInit.Output -match 'already exists') 'nik init refuses to overwrite existing nik.yaml without --force'

    # 10b. ~/.nikrun/template.yaml applied by nik init (--lib and --pkg) + typo validation
    $TemplateYamlPath = Join-Path $TestHome 'template.yaml'
    @"
schemaVersion: 1

template:
  license: Apache-2.0
  authors: ["Jane Doe"]
  toolchain:
    fpc: 3.2.2
  build:
    mode: delphi
    cOperators: true
    modeSwitches: [advancedRecords]
    warnings:
      hints: true
      suppress: [5024]
  profiles:
    release:
      build:
        optimization: 3
"@ | Set-Content -Path $TemplateYamlPath -Encoding UTF8

    $InitLibDir = Join-Path $WorkDir 'init-tpl-lib'
    $initLibJson = (Invoke-Nik -NikHome $TestHome -Arguments @('init', $InitLibDir, '--lib', '--json')).Output | ConvertFrom-Json
    Assert-True ($initLibJson.success -eq $true -and $initLibJson.kind -eq 'library' -and $initLibJson.fpcVersion -eq '3.2.2' -and $initLibJson.usedTemplate -eq $true) 'nik init --lib applies ~/.nikrun/template.yaml automatically'
    $genLibYaml = Get-Content -Path (Join-Path $InitLibDir 'nik.yaml') -Raw
    Assert-True ($genLibYaml -match 'license:\s*Apache-2\.0' -and $genLibYaml -match 'mode:\s*delphi' -and $genLibYaml -match 'cOperators:\s*true' -and $genLibYaml -match 'optimization:\s*3') 'Generated nik.yaml carries template metadata, toolchain.fpc, build options, and profiles'

    $InitPkgDir = Join-Path $WorkDir 'init-tpl-pkg'
    $initPkgJson = (Invoke-Nik -NikHome $TestHome -Arguments @('init', $InitPkgDir, '--pkg', '--fpc', '3.3.1', '--json')).Output | ConvertFrom-Json
    Assert-True ($initPkgJson.success -eq $true -and $initPkgJson.kind -eq 'package' -and $initPkgJson.fpcVersion -eq '3.3.1') 'nik init --pkg --fpc 3.3.1 overrides template toolchain.fpc cleanly'
    Remove-Item -Force $TemplateYamlPath

    # 11. Uninstall SDKs by exact version (rejects SDK IDs)
    $uninstById = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'uninstall', $Mock322.SdkId) -AllowFailure
    Assert-True ($uninstById.ExitCode -ne 0 -and $uninstById.Output -match 'Invalid Free Pascal SDK version') 'nik sdk uninstall rejects SDK IDs and requires exact version'

    $uninst322 = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'uninstall', '3.2.2')
    Assert-True ($uninst322.ExitCode -eq 0) 'nik sdk uninstall 3.2.2 removes 3.2.2 SDK'
    $uninst331 = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'uninstall', '3.3.1')
    Assert-True ($uninst331.ExitCode -eq 0) 'nik sdk uninstall 3.3.1 removes 3.3.1 SDK'
    Assert-True (-not (Test-Path $cfgPath)) 'No config.json created or left behind after SDK lifecycle'

    # 12. Install from a local extracted SDK directory
    $LocalSdkDir = Join-Path $StageRoot $Mock322.SdkId
    $instDir = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', $LocalSdkDir)
    Assert-True ($instDir.ExitCode -eq 0 -and $instDir.Output -match 'Installed SDK to') 'nik sdk install <local-dir> installs local extracted SDK directory'
    $null = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'uninstall', '3.2.2')

    # 13. nik build help & strict nik.yaml schema validation (artifact roots, typo detection, JSON preflight errors)
    $buildHelp = Invoke-Nik -NikHome $TestHome -Arguments @('build', '--help')
    Assert-True ($buildHelp.ExitCode -eq 0 -and $buildHelp.Output -match '--profile') 'nik build --help displays usage and options'

    # 13a. Root artifact key typo detection
    $BadRootDir = Join-Path $WorkDir 'bad-root-proj'
    New-Item -ItemType Directory -Force -Path $BadRootDir | Out-Null
    @"
progarm:
  name: typo-root
  entry: main.pas
"@ | Set-Content -Path (Join-Path $BadRootDir 'nik.yaml') -Encoding UTF8
    $badRootRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $BadRootDir) -AllowFailure
    Assert-True ($badRootRes.ExitCode -ne 0 -and $badRootRes.Output -match "Unknown key 'progarm'" -and $badRootRes.Output -match "did you mean 'program'") 'nik build detects root artifact key typos with suggestion'

    # 13b. Typo inside 'program:' section & JSON preflight error
    $BadProjDir = Join-Path $WorkDir 'bad-yaml-proj'
    New-Item -ItemType Directory -Force -Path $BadProjDir | Out-Null
    @"
program:
  name: typo-app
  entry: main.pas
  buid:
    mode: objfpc
"@ | Set-Content -Path (Join-Path $BadProjDir 'nik.yaml') -Encoding UTF8

    $typoRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $BadProjDir) -AllowFailure
    Assert-True ($typoRes.ExitCode -ne 0 -and $typoRes.Output -match "Unknown key 'buid'" -and $typoRes.Output -match "did you mean 'build'") 'nik build detects nested YAML key typos with line number and suggestion'

    $typoJson = (Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $BadProjDir, '--json') -AllowFailure).Output | ConvertFrom-Json
    Assert-True ($typoJson.success -eq $false -and $typoJson.error -match "Unknown key 'buid'") 'nik build --json emits valid JSON on manifest validation error'

    # 13c. 'library:' without 'entry' hints about 'package:' for source unit collections
    $LibNoEntryDir = Join-Path $WorkDir 'lib-no-entry'
    New-Item -ItemType Directory -Force -Path $LibNoEntryDir | Out-Null
    @"
library:
  name: confused-lib
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $LibNoEntryDir 'nik.yaml') -Encoding UTF8
    $libNoEntryRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $LibNoEntryDir) -AllowFailure
    Assert-True ($libNoEntryRes.ExitCode -ne 0 -and $libNoEntryRes.Output -match "Did you mean 'package'") "nik build hints about 'package' when 'library' omits 'entry'"

    # 13e. 'package:' rejects top-level 'entry', and direct 'nik build' explains package nature
    $PkgWithEntryDir = Join-Path $WorkDir 'pkg-with-entry'
    $ValidPkgDir = Join-Path $WorkDir 'valid-pkg-only'
    New-Item -ItemType Directory -Force -Path $PkgWithEntryDir, $ValidPkgDir | Out-Null
    @"
package:
  name: invalid-pkg
  entry: main.pas
"@ | Set-Content -Path (Join-Path $PkgWithEntryDir 'nik.yaml') -Encoding UTF8
    $pkgEntryRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $PkgWithEntryDir) -AllowFailure
    Assert-True ($pkgEntryRes.ExitCode -ne 0 -and $pkgEntryRes.Output -match "cannot specify 'entry'") "nik build rejects 'entry' directly inside 'package'"

    @"
package:
  name: pure-units
  version: 0.1.0
  toolchain:
    fpc: 3.2.2
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $ValidPkgDir 'nik.yaml') -Encoding UTF8
    $pkgBuildRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $ValidPkgDir) -AllowFailure
    Assert-True ($pkgBuildRes.ExitCode -ne 0 -and $pkgBuildRes.Output -match "source unit package without a binary target") "nik build on 'package' explains that packages have no binary target"

    # 13f. Required exact toolchain.fpc validation (rejects missing fpc, SemVer ranges, and SDK IDs)
    $MissingFpcDir = Join-Path $WorkDir 'missing-fpc-proj'
    $RangeFpcDir   = Join-Path $WorkDir 'range-fpc-proj'
    New-Item -ItemType Directory -Force -Path $MissingFpcDir, $RangeFpcDir | Out-Null
    @"
program:
  name: no-fpc-app
  entry: main.pas
"@ | Set-Content -Path (Join-Path $MissingFpcDir 'nik.yaml') -Encoding UTF8
    $noFpcRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $MissingFpcDir) -AllowFailure
    Assert-True ($noFpcRes.ExitCode -ne 0 -and $noFpcRes.Output -match "Missing required 'program\.toolchain\.fpc'") 'nik build requires explicit toolchain.fpc in nik.yaml'

    @"
program:
  name: range-fpc-app
  entry: main.pas
  toolchain:
    fpc: ">=3.2.2"
"@ | Set-Content -Path (Join-Path $RangeFpcDir 'nik.yaml') -Encoding UTF8
    $rangeFpcRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $RangeFpcDir) -AllowFailure
    Assert-True ($rangeFpcRes.ExitCode -ne 0 -and $rangeFpcRes.Output -match "Invalid program\.toolchain\.fpc '>=3\.2\.2'") 'nik build rejects SemVer ranges in toolchain.fpc'

    # 13f. Target selector typo detection in 'targets:'
    $BadTargetDir = Join-Path $WorkDir 'bad-target-proj'
    New-Item -ItemType Directory -Force -Path $BadTargetDir | Out-Null
    @"
program:
  name: bad-target
  entry: main.pas
  targets:
    windwos:
      build:
        defines: [WIN]
"@ | Set-Content -Path (Join-Path $BadTargetDir 'nik.yaml') -Encoding UTF8
    $badTargetRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $BadTargetDir) -AllowFailure
    Assert-True ($badTargetRes.ExitCode -ne 0 -and $badTargetRes.Output -match "Unknown target selector 'windwos'" -and $badTargetRes.Output -match "did you mean 'windows'") "nik build detects target selector typos in 'targets'"

    # 14. End-to-end real FPC SDK archive install + nik build tests (if dist/, .work/sdk-cache/, or -RealSdkZipPath exists)
    if (-not $SkipRealArchive) {
        $RealZip = if (-not [string]::IsNullOrWhiteSpace($RealSdkZipPath) -and (Test-Path $RealSdkZipPath)) {
            Get-Item $RealSdkZipPath
        } else {
            $SearchDirs = @(@(
                (Join-Path $RepoRoot 'dist'),
                ([System.IO.Path]::Combine($RepoRoot, '.work', 'sdk-cache')),
                ([System.IO.Path]::Combine((Split-Path -Parent $RepoRoot), 'sdk', 'dist'))
            ) | Where-Object { Test-Path $_ })

            if ($SearchDirs.Count -gt 0) {
                Get-ChildItem -Path $SearchDirs -Filter "nikrun-fpc-sdk-*-$HostCpu-$HostOs.zip" -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            } else {
                $null
            }
        }

        if ($null -ne $RealZip) {
            Write-Host "`n==> Running real FPC SDK archive + nik build end-to-end tests ($($RealZip.Name))..." -ForegroundColor Cyan
            $realInst = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'install', $RealZip.FullName)
            Assert-True ($realInst.ExitCode -eq 0) "Installed real FPC SDK archive via 'nik sdk install <zip>'"

            $realList = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--json')).Output | ConvertFrom-Json
            $realFpcVersion = [string]$realList.sdks[0].fpcVersion
            $realInfo = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', $realFpcVersion, '--json')).Output | ConvertFrom-Json
            Assert-True ($realInfo.healthy -eq $true) 'Real FPC SDK passes nik sdk info <version> health check'

            # End-to-end nik init -> nik build -> run executable
            $QuickInitDir = Join-Path $WorkDir 'quick-init-app'
            $quickInitRes = Invoke-Nik -NikHome $TestHome -Arguments @('init', $QuickInitDir)
            Assert-True ($quickInitRes.ExitCode -eq 0) 'nik init scaffolds runnable program project with installed real SDK'
            $quickBuild = (Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $QuickInitDir, '--json')).Output | ConvertFrom-Json
            Assert-True ($quickBuild.success -eq $true -and (Test-Path $quickBuild.output.binaryPath)) 'nik build compiles freshly initialized nik init project out of the box'
            $quickOut = (& $quickBuild.output.binaryPath).Trim()
            Assert-True ($quickOut -eq 'Hello from quick-init-app!') "Compiled nik init starter binary runs cleanly ($quickOut)"

            # Create a local 'package:' dependency + multi-profile 'program:' + shared 'library:'
            $DepDir = Join-Path $WorkDir 'ext-greeting'
            $DepSrc = Join-Path $DepDir 'src'
            $AppDir = Join-Path $WorkDir 'sample-app'
            $AppSrc = Join-Path $AppDir 'src'
            $AppInc = Join-Path $AppDir 'inc'
            $LibDir = Join-Path $WorkDir 'sample-lib'
            $LibSrc = Join-Path $LibDir 'src'
            New-Item -ItemType Directory -Force -Path $DepSrc, $AppSrc, $AppInc, $LibSrc | Out-Null

            @"
package:
  name: ext-greeting
  version: 0.3.0
  description: "Sample local unit package"
  license: MIT
  toolchain:
    fpc: $($realInfo.fpcVersion)
  build:
    mode: objfpc
    unitPaths: [src]
  test:
    entry: tests/pkg_test.pas
    dependencies:
      mock-assert: "^0.1.0"
"@ | Set-Content -Path (Join-Path $DepDir 'nik.yaml') -Encoding UTF8

            @"
unit ExtGreeting;
{`$mode objfpc}{`$H+}
interface
function GetGreetingPrefix: string;
implementation
function GetGreetingPrefix: string;
begin
  Result := 'EXT_OK';
end;
end.
"@ | Set-Content -Path (Join-Path $DepSrc 'ExtGreeting.pas') -Encoding UTF8

            @"
const APP_BANNER = 'INC_OK';
"@ | Set-Content -Path (Join-Path $AppInc 'banner.inc') -Encoding UTF8

            @"
unit AppHelper;
interface
type
  TIntHelper = type helper for Integer
    function AddTen: Integer;
  end;

function UnusedParamCheck(AUsed, AUnused: Integer): Integer;

implementation

function TIntHelper.AddTen: Integer;
begin
  Result := Self + 10;
end;

function UnusedParamCheck(AUsed, AUnused: Integer): Integer;
begin
  Result := AUsed;
end;

end.
"@ | Set-Content -Path (Join-Path $AppSrc 'AppHelper.pas') -Encoding UTF8

            @"
program MainEntry;
uses
  SysUtils, ExtGreeting, AppHelper;
{`$I banner.inc}
var
  N: Integer;
  Tags: string;
begin
  N := 30;
  N += 2; // C-style operator enabled via build.cOperators
  N := UnusedParamCheck(N.AddTen, 99); // Type helper enabled via build.modeSwitches
  Assert(N = 42, 'Expected 42');
  Tags := GetGreetingPrefix + '|' + APP_BANNER + '|' + IntToStr(N) + '|STR' + IntToStr(SizeOf(Char));
  {`$IFDEF BASE_TAG}Tags := Tags + '|BASE';{`$ENDIF}
  {`$IFDEF TARGET_OS_OK}Tags := Tags + '|TOS';{`$ENDIF}
  {`$IFDEF TARGET_CPU_OK}Tags := Tags + '|TCPU';{`$ENDIF}
  {`$IFDEF DEBUG}Tags := Tags + '|DEBUG';{`$ENDIF}
  {`$IFDEF EXTRA_DBG}Tags := Tags + '|EXTRA_DBG';{`$ENDIF}
  {`$IFDEF RELEASE}Tags := Tags + '|RELEASE';{`$ENDIF}
  {`$IFDEF ONLY_CUSTOM}Tags := Tags + '|ONLY_CUSTOM';{`$ENDIF}
  WriteLn(Tags);
end.
"@ | Set-Content -Path (Join-Path $AppSrc 'MainEntry.pas') -Encoding UTF8

            @"
schemaVersion: 1

program:
  name: sample-app
  version: 0.2.0
  entry: src/MainEntry.pas
  output: out/custom-binary

  toolchain:
    fpc: $($realInfo.fpcVersion)

  build:
    mode: objfpc
    longStrings: true
    cOperators: true
    modeSwitches: [advancedRecords, typeHelpers]
    includePaths: [inc]
    unitPaths: [src]
    defines: [BASE_TAG]
    warnings:
      hints: true
      suppress: [5024]

  dependencies:
    ext-greeting:
      path: ../ext-greeting

  test:
    entry: tests/test_all.pas
    build:
      unitPaths: [tests]
      defines: [TESTING]
      heaptrc: true
    dependencies:
      test-only-helper: "^1.0.0"

  targets:
    windows:
      build:
        defines: [TARGET_OS_OK]
    unix:
      build:
        defines: [TARGET_OS_OK]
    "$($realInfo.targetTriplet.Split('-')[0])":
      build:
        defines: [TARGET_CPU_OK]

  profiles:
    debug:
      build:
        defines: [EXTRA_DBG]
        debugInfo: dwarf2
    custom:
      output: out/alt-binary
      build:
        defines: [`$reset, ONLY_CUSTOM]
    missing-sdk:
      toolchain:
        fpc: "9.8.7"
"@ | Set-Content -Path (Join-Path $AppDir 'nik.yaml') -Encoding UTF8

            # 14a. Default debug profile build (--json) -> direct ppc* invocation, package dep, targets, modeswitches, warnings.suppress
            $dbgBuildRaw = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '--json')
            $dbgBuild = $dbgBuildRaw.Output | ConvertFrom-Json
            Assert-True ($dbgBuild.success -eq $true -and $dbgBuild.project.kind -eq 'program' -and $dbgBuild.project.profile -eq 'debug') 'nik build --json succeeds for program manifest in default debug profile'
            Assert-True ($dbgBuild.toolchain.compilerBinary -match 'ppc') 'nik build invokes SDK ppc* backend directly (bypassing fpc wrapper)'
            Assert-True (Test-Path $dbgBuild.output.binaryPath) 'nik build produces binary at custom program.output path'
            Assert-True (Test-Path $dbgBuild.output.cacheDir) 'nik build creates isolated .nik/cache/<sdk>-<profile> directory'
            Assert-True (@($dbgBuild.diagnostics | Where-Object { $_.code -eq 5024 }).Count -eq 0) 'warnings.suppress [5024] suppresses unused parameter hint cleanly'

            $dbgRunOut = (& $dbgBuild.output.binaryPath).Trim()
            Assert-True ($dbgRunOut -match '^EXT_OK\|INC_OK\|42\|' -and $dbgRunOut -match '\|BASE\|TOS\|TCPU\|DEBUG\|EXTRA_DBG$') "Debug binary reflects package dep, cOperators, modeSwitches, targets overlays, and profile defines ($dbgRunOut)"

            # 14b. Release profile build (-p release) -> separate cache, smaller stripped binary, RELEASE define
            $legacyRelOpt = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '--release') -AllowFailure
            Assert-True ($legacyRelOpt.ExitCode -ne 0 -and $legacyRelOpt.Output -match '--profile release') 'nik build rejects --release shorthand in favor of uniform -p/--profile'

            $relBuild = (Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '-p', 'release', '--json')).Output | ConvertFrom-Json
            Assert-True ($relBuild.success -eq $true -and $relBuild.project.profile -eq 'release') 'nik build -p release builds release profile'
            Assert-True ($relBuild.output.cacheDir -ne $dbgBuild.output.cacheDir) 'Release and debug profiles use distinct checkout-local cache directories'
            Assert-True ($relBuild.output.sizeBytes -lt $dbgBuild.output.sizeBytes) 'Release profile produces smaller stripped binary than DWARF debug profile'
            $relRunOut = (& $relBuild.output.binaryPath).Trim()
            Assert-True ($relRunOut -match '\|BASE\|TOS\|TCPU\|RELEASE$') "Release binary carries BASE_TAG + target overlays + RELEASE defines ($relRunOut)"

            # 14c. Custom profile overriding program.output and $reset defines
            $custBuild = (Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '--profile', 'custom', '--json')).Output | ConvertFrom-Json
            Assert-True ($custBuild.success -eq $true -and $custBuild.output.binaryPath -match 'alt-binary') 'Custom profile overrides program.output'
            $custRunOut = (& $custBuild.output.binaryPath).Trim()
            Assert-True ($custRunOut -notmatch 'BASE' -and $custRunOut -match '\|ONLY_CUSTOM$') "Custom profile `$reset replaces base and target defines cleanly ($custRunOut)"

            # 14d. Profile overriding toolchain.fpc triggers target SDK lookup
            $missSdkRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '--profile', 'missing-sdk') -AllowFailure
            Assert-True ($missSdkRes.ExitCode -ne 0 -and $missSdkRes.Output -match "Installed Free Pascal SDK '9\.8\.7' not found") 'Profile toolchain.fpc override selects profile-specific SDK version'

            # 14e. Shared 'library:' build produces native .dll/.so/.dylib automatically
            @"
library SampleLib;
{`$mode objfpc}{`$H+}

function MultiplyInts(A, B: Int32): Int32; cdecl;
begin
  Result := A * B;
end;

exports
  MultiplyInts;

begin
end.
"@ | Set-Content -Path (Join-Path $LibSrc 'SampleLib.pas') -Encoding UTF8

            @"
library:
  name: samplemath
  version: 0.1.0
  entry: src/SampleLib.pas
  output: out/samplemath
  toolchain:
    fpc: $($realInfo.fpcVersion)
"@ | Set-Content -Path (Join-Path $LibDir 'nik.yaml') -Encoding UTF8

            $libBuild = (Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $LibDir, '-p', 'release', '--json')).Output | ConvertFrom-Json
            Assert-True ($libBuild.success -eq $true -and $libBuild.project.kind -eq 'library') "nik build compiles 'library:' manifest cleanly"
            Assert-True ((Test-Path $libBuild.output.binaryPath) -and ($libBuild.output.binaryPath -match '\.(dll|so|dylib)$')) "Shared library output automatically uses OS extension ($($libBuild.output.binaryPath))"

            # 14f. Structured compiler diagnostics on broken source (--json)
            $BrokenDir = Join-Path $WorkDir 'broken-app'
            New-Item -ItemType Directory -Force -Path $BrokenDir | Out-Null
            @"
program:
  name: broken-app
  entry: broken.pas
  toolchain:
    fpc: $($realInfo.fpcVersion)
"@ | Set-Content -Path (Join-Path $BrokenDir 'nik.yaml') -Encoding UTF8
            @"
program broken;
begin
  DoesNotExist := 123;
end.
"@ | Set-Content -Path (Join-Path $BrokenDir 'broken.pas') -Encoding UTF8

            $brokenRes = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $BrokenDir, '--json') -AllowFailure
            Assert-True ($brokenRes.ExitCode -eq 1) 'nik build --json exits with code 1 on compiler error'
            $brokenJson = $brokenRes.Output | ConvertFrom-Json
            Assert-True ($brokenJson.success -eq $false -and $brokenJson.exitCode -eq 1 -and $brokenJson.counts.errors -ge 1) 'nik build --json reports normalized exitCode 1 and error count on failed compile'
            $errDiag = @($brokenJson.diagnostics | Where-Object { $_.severity -eq 'error' })[0]
            Assert-True ($errDiag.line -eq 3 -and $errDiag.code -eq 5000 -and $errDiag.message -match 'DoesNotExist') 'nik build --json extracts exact file, line, column, code (5000), and message'
        }
    }

    # 15. Standalone nikrun-lsp-protocol unit suite + End-to-End 'nik lsp' session over binary stdio
    Write-Host "`n==> Running standalone nikrun-lsp-protocol unit tests..." -ForegroundColor Cyan
    & ([System.IO.Path]::Combine($RepoRoot, 'lsp-protocol', 'test.ps1'))

    Write-Host "`n==> Running 'nik lsp' Language Server end-to-end tests..." -ForegroundColor Cyan
    $lspHelp = Invoke-Nik -NikHome $TestHome -Arguments @('lsp', '--help')
    Assert-True ($lspHelp.ExitCode -eq 0 -and $lspHelp.Output -match '--stdio' -and $lspHelp.Output -match '--socket') 'nik lsp --help prints usage and transport options'

    $HostHomeDir = if (($HostOs -eq 'win64') -and $env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $CandidateLspHome = ''
    $CandidateLspFpcVersion = ''
    foreach ($candHome in @($TestHome, ([System.IO.Path]::Combine($HostHomeDir, '.nikrun')))) {
        $candSdks = [System.IO.Path]::Combine($candHome, 'sdks')
        if (Test-Path $candSdks) {
            foreach ($sd in (Get-ChildItem -Path $candSdks -Directory -ErrorAction SilentlyContinue)) {
                $mf = [System.IO.Path]::Combine($sd.FullName, 'sdk-manifest.json')
                if (Test-Path $mf) {
                    $mObj = Get-Content $mf -Raw | ConvertFrom-Json
                    $ppcRel = [string]$mObj.paths.ppcBinary
                    if ($ppcRel -and (Test-Path ([System.IO.Path]::Combine($sd.FullName, ($ppcRel -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar))))) {
                        # Skip tiny mock SDKs whose ppcBinary is just a dummy file (< 100 KB)
                        $ppcFull = [System.IO.Path]::Combine($sd.FullName, ($ppcRel -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar))
                        if ((Get-Item $ppcFull).Length -gt 102400) {
                            $CandidateLspHome = $candHome
                            $CandidateLspFpcVersion = [string]$mObj.fpcVersion
                            break
                        }
                    }
                }
            }
        }
        if ($CandidateLspHome) { break }
    }

    if ($CandidateLspHome) {
        function Format-LspFrame([hashtable]$Msg) {
            $json = ConvertTo-Json -InputObject $Msg -Depth 6 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $header = [System.Text.Encoding]::ASCII.GetBytes("Content-Length: $($bytes.Length)`r`n`r`n")
            $combined = New-Object byte[] ($header.Length + $bytes.Length)
            [System.Buffer]::BlockCopy($header, 0, $combined, 0, $header.Length)
            [System.Buffer]::BlockCopy($bytes, 0, $combined, $header.Length, $bytes.Length)
            return ,$combined
        }

        function ConvertTo-FileUri([string]$LocalFile) {
            $norm = ([System.IO.Path]::GetFullPath($LocalFile)).Replace('\', '/')
            if ($norm -match '^([A-Za-z]):(.*)$') {
                return "file:///$($Matches[1].ToLowerInvariant()):$($Matches[2])"
            }
            return "file://$norm"
        }

        function Invoke-LspSession([string]$NikHomeDir, [string]$ProjectPath, [string]$LogPath, [array]$Messages) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $NikExe
            $logArg = if ($LogPath) { " --log-file `"$LogPath`"" } else { '' }
            $psi.Arguments = "--no-color --nikrun-home `"$NikHomeDir`" lsp --stdio -m `"$ProjectPath`"$logArg"
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($psi)
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            $accum = [System.Collections.Generic.List[byte]]::new()
            $parsedFrames = [System.Collections.Generic.List[object]]::new()
            $readBuf = New-Object byte[] 8192
            $state = @{
                ParsePos    = 0
                PendingRead = $proc.StandardOutput.BaseStream.ReadAsync($readBuf, 0, $readBuf.Length)
            }

            $pumpOutput = {
                param([int]$WaitMs)
                while ($null -ne $state.PendingRead) {
                    if (-not $state.PendingRead.Wait($WaitMs)) {
                        break
                    }
                    $n = $state.PendingRead.Result
                    if ($n -le 0) {
                        $state.PendingRead = $null
                    } else {
                        for ($k = 0; $k -lt $n; $k++) {
                            $accum.Add($readBuf[$k])
                        }
                        $state.PendingRead = $proc.StandardOutput.BaseStream.ReadAsync($readBuf, 0, $readBuf.Length)
                    }

                    while ($state.ParsePos -lt $accum.Count) {
                        $sep = -1
                        for ($i = $state.ParsePos; $i -le ($accum.Count - 4); $i++) {
                            if ($accum[$i] -eq 13 -and $accum[$i + 1] -eq 10 -and $accum[$i + 2] -eq 13 -and $accum[$i + 3] -eq 10) {
                                $sep = $i
                                break
                            }
                        }
                        if ($sep -lt 0) { break }
                        $hdrBytes = $accum.GetRange($state.ParsePos, $sep - $state.ParsePos).ToArray()
                        $hdr = [System.Text.Encoding]::ASCII.GetString($hdrBytes)
                        if ($hdr -notmatch 'Content-Length:\s*(\d+)') {
                            throw "Invalid LSP frame header: $hdr"
                        }
                        $len = [int]$Matches[1]
                        $bodyStart = $sep + 4
                        if (($bodyStart + $len) -gt $accum.Count) { break }
                        $bodyBytes = $accum.GetRange($bodyStart, $len).ToArray()
                        $jsonBody = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
                        $parsedFrames.Add(($jsonBody | ConvertFrom-Json))
                        $state.ParsePos = $bodyStart + $len
                    }
                    # Drain any immediately buffered bytes without blocking again
                    $WaitMs = 0
                }
            }

            foreach ($m in $Messages) {
                if ($m -is [hashtable] -and $m.ContainsKey('__sleepMs')) {
                    $proc.StandardInput.BaseStream.Flush()
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    $targetMs = [int]$m['__sleepMs']
                    while ($sw.ElapsedMilliseconds -lt $targetMs) {
                        $rem = [Math]::Max(1, [int]($targetMs - $sw.ElapsedMilliseconds))
                        & $pumpOutput ([Math]::Min(25, $rem))
                    }
                } elseif ($m -is [hashtable] -and $m.ContainsKey('__waitDiagCount')) {
                    $proc.StandardInput.BaseStream.Flush()
                    $waitCfg   = $m['__waitDiagCount']
                    $targetUri = [string]$waitCfg['uri']
                    $minCount  = [int]$waitCfg['count']
                    $timeoutMs = if ($waitCfg.ContainsKey('timeoutMs')) { [int]$waitCfg['timeoutMs'] } else { 15000 }
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    while ($sw.ElapsedMilliseconds -lt $timeoutMs) {
                        $matched = @($parsedFrames | Where-Object {
                            $_.PSObject.Properties['method'] -and
                            $_.method -eq 'textDocument/publishDiagnostics' -and
                            $_.params.uri -eq $targetUri
                        }).Count
                        if ($matched -ge $minCount) {
                            break
                        }
                        if ($proc.HasExited -and $null -eq $state.PendingRead) {
                            break
                        }
                        & $pumpOutput 50
                    }
                } else {
                    $frm = Format-LspFrame $m
                    $proc.StandardInput.BaseStream.Write($frm, 0, $frm.Length)
                    & $pumpOutput 0
                }
            }

            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()

            $exitSw = [System.Diagnostics.Stopwatch]::StartNew()
            while ((-not $proc.HasExited) -and ($exitSw.ElapsedMilliseconds -lt 20000)) {
                & $pumpOutput 50
            }
            $exited = $proc.WaitForExit(1000)

            $drainSw = [System.Diagnostics.Stopwatch]::StartNew()
            while (($null -ne $state.PendingRead) -and ($drainSw.ElapsedMilliseconds -lt 5000)) {
                & $pumpOutput 50
            }
            $stderrTask.Wait(5000) | Out-Null
            $stderrText = $stderrTask.Result

            return [PSCustomObject]@{
                Exited   = $exited
                ExitCode = $proc.ExitCode
                Frames   = $parsedFrames.ToArray()
                Stderr   = $stderrText
            }
        }

        $LspPkgDir = Join-Path $WorkDir 'lsp-dep-pkg'
        $LspPkgSrc = Join-Path $LspPkgDir 'src'
        $LspAppDir = Join-Path $WorkDir 'lsp-app'
        $LspAppSrc = Join-Path $LspAppDir 'src'
        $LspErrDir = Join-Path $WorkDir 'lsp-broken'
        New-Item -ItemType Directory -Force -Path $LspPkgSrc, $LspAppSrc, $LspErrDir | Out-Null

        @"
package:
  name: lsp-dep-pkg
  version: 0.1.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $LspPkgDir 'nik.yaml') -Encoding UTF8

        @"
unit GreeterUnit;
{`$mode objfpc}{`$H+}
interface

/// Builds a friendly greeting string for the given user.
function BuildGreeting(const AName: string): string;

implementation

function BuildGreeting(const AName: string): string;
begin
  Result := 'Hello, ' + AName;
end;

end.
"@ | Set-Content -Path (Join-Path $LspPkgSrc 'GreeterUnit.pas') -Encoding UTF8

        @"
program:
  name: lsp-app
  entry: src/AppMain.pas
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
  dependencies:
    lsp-dep-pkg:
      path: ../lsp-dep-pkg
"@ | Set-Content -Path (Join-Path $LspAppDir 'nik.yaml') -Encoding UTF8

        $AppMainPas = Join-Path $LspAppSrc 'AppMain.pas'
        @"
program AppMain;
{`$mode objfpc}{`$H+}
uses
  SysUtils, GreeterUnit;

type
  TRunner = class
  public
    procedure Execute;
  end;

procedure TRunner.Execute;
begin
  WriteLn(BuildGreeting('Nikrun'));
end;

begin
end.
"@ | Set-Content -Path $AppMainPas -Encoding UTF8

        @"
program:
  name: lsp-broken
  entry: broken_lsp.pas
  toolchain:
    fpc: $CandidateLspFpcVersion
"@ | Set-Content -Path (Join-Path $LspErrDir 'nik.yaml') -Encoding UTF8

        $BrokenLspPas = Join-Path $LspErrDir 'broken_lsp.pas'
        @"
program broken_lsp;
begin
  UnknownSymbolXYZ := 42;
end.
"@ | Set-Content -Path $BrokenLspPas -Encoding UTF8

        # Session 1: Live ppc* -Cn compiler diagnostics on broken source + trace logging
        $lspLogFile  = Join-Path $WorkDir 'nik-lsp.log'
        $brokenUri   = ConvertTo-FileUri $BrokenLspPas
        $brokenRoot  = ConvertTo-FileUri $LspErrDir
        $brokenText  = [System.IO.File]::ReadAllText($BrokenLspPas)

        $sess1 = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspErrDir -LogPath $lspLogFile -Messages @(
            @{ jsonrpc = '2.0'; id = 1; method = 'initialize'; params = @{ processId = $PID; rootUri = $brokenRoot; clientInfo = @{ name = 'nik-e2e'; version = '1.0' } } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $brokenUri; languageId = 'objectpascal'; version = 1; text = $brokenText } } },
            @{ __waitDiagCount = @{ uri = $brokenUri; count = 1 } },
            @{ jsonrpc = '2.0'; id = 2; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )

        Assert-True ($sess1.Exited -and $sess1.ExitCode -eq 0) "nik lsp exits cleanly with code 0 after shutdown+exit (got $($sess1.ExitCode))"
        $initResp = @($sess1.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 1 })[0]
        Assert-True ($null -ne $initResp -and $initResp.result.serverInfo.name -eq 'nik lsp') 'nik lsp responds to initialize with serverInfo and capabilities'
        $diagNotifs = @($sess1.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' })
        Assert-True ($diagNotifs.Count -ge 1 -and $diagNotifs[0].params.diagnostics[0].code -eq 5000 -and $diagNotifs[0].params.diagnostics[0].message -match 'UnknownSymbolXYZ') 'nik lsp publishes exact ppc* -Cn compiler diagnostics (code 5000) on didOpen'
        Assert-True (Test-Path $lspLogFile) 'nik lsp writes protocol trace log when --log-file is specified'

        # Session 2: DocumentSymbol, Cross-Package Go-to-Definition, Hover (with PasDoc), SignatureHelp & Completion
        $appMainUri  = ConvertTo-FileUri $AppMainPas
        $appRootUri  = ConvertTo-FileUri $LspAppDir
        $appMainText = [System.IO.File]::ReadAllText($AppMainPas)

        # Line 13 (0-based): "  WriteLn(BuildGreeting('Nikrun'));" -> 'BuildGreeting' starts at col 10, '(' is at col 23
        $sess2 = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspAppDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 10; method = 'initialize'; params = @{ processId = $PID; rootUri = $appRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $appMainUri; languageId = 'objectpascal'; version = 1; text = $appMainText } } },
            @{ jsonrpc = '2.0'; id = 11; method = 'textDocument/documentSymbol'; params = @{ textDocument = @{ uri = $appMainUri } } },
            @{ jsonrpc = '2.0'; id = 12; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $appMainUri }; position = @{ line = 13; character = 14 } } },
            @{ jsonrpc = '2.0'; id = 13; method = 'textDocument/hover'; params = @{ textDocument = @{ uri = $appMainUri }; position = @{ line = 13; character = 14 } } },
            @{ jsonrpc = '2.0'; id = 14; method = 'textDocument/signatureHelp'; params = @{ textDocument = @{ uri = $appMainUri }; position = @{ line = 13; character = 25 } } },
            @{ jsonrpc = '2.0'; id = 15; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $appMainUri }; position = @{ line = 13; character = 14 } } },
            @{ jsonrpc = '2.0'; id = 16; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $appMainUri }; position = @{ line = 3; character = 4 } } },
            @{ jsonrpc = '2.0'; id = 17; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )

        Assert-True ($sess2.Exited -and $sess2.ExitCode -eq 0) 'Multi-feature nik lsp session exits cleanly with code 0'

        $symResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 11 })[0]
        Assert-True ($null -ne $symResp -and $symResp.result[0].name -eq 'TRunner' -and $symResp.result[0].children[0].name -eq 'Execute') 'nik lsp returns hierarchical DocumentSymbol tree (TRunner -> Execute)'

        $defResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 12 })[0]
        Assert-True ($null -ne $defResp -and @($defResp.result).Count -ge 1 -and $defResp.result[0].uri -match 'GreeterUnit\.pas$') 'nik lsp resolves cross-package Go-to-Definition via nik.yaml dependencies'

        $hovResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 13 })[0]
        Assert-True ($null -ne $hovResp -and $hovResp.result.contents.value -match 'BuildGreeting' -and $hovResp.result.contents.value -match 'friendly greeting string') 'nik lsp Hover displays signature and preceding /// doc comment'

        $sigResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 14 })[0]
        Assert-True ($null -ne $sigResp -and @($sigResp.result.signatures).Count -ge 1 -and $sigResp.result.signatures[0].parameters[0].label -match 'AName') 'nik lsp SignatureHelp extracts routine parameter labels'

        $cmpResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 15 })[0]
        $cmpLabels = @($cmpResp.result.items | ForEach-Object { $_.label })
        Assert-True ($cmpLabels -contains 'BuildGreeting' -and $cmpLabels -contains 'TRunner') 'nik lsp Completion suggests local and imported package symbols'

        $rtlDefResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 16 })[0]
        Assert-True ($null -ne $rtlDefResp -and @($rtlDefResp.result).Count -ge 1 -and $rtlDefResp.result[0].uri -match 'sysutils\.(pp|pas)$') 'nik lsp resolves Go-to-Definition directly into bundled Nikrun SDK source/rtl (SysUtils)'

        # Session 3: Graceful degradation + diagnostic squiggle when nik.yaml is invalid (e.g. legacy 'project:' root)
        $LspBadYmlDir = Join-Path $WorkDir 'lsp-bad-yaml'
        $LspBadYmlSrc = Join-Path $LspBadYmlDir 'Source'
        New-Item -ItemType Directory -Force -Path $LspBadYmlSrc | Out-Null
        @"
project:
  name: legacy-manifest
  entry: Source/LegacyUnit.pas
"@ | Set-Content -Path (Join-Path $LspBadYmlDir 'nik.yaml') -Encoding UTF8
        $LegacyPas = Join-Path $LspBadYmlSrc 'LegacyUnit.pas'
        @"
unit LegacyUnit;
interface
function LegacyAnswer: Integer;
implementation
function LegacyAnswer: Integer;
begin
  Result := 42;
end;
end.
"@ | Set-Content -Path $LegacyPas -Encoding UTF8

        $badRootUri = ConvertTo-FileUri $LspBadYmlDir
        $legacyUri  = ConvertTo-FileUri $LegacyPas
        $legacyText = [System.IO.File]::ReadAllText($LegacyPas)

        $sess3 = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspBadYmlDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 30; method = 'initialize'; params = @{ processId = $PID; rootUri = $badRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $legacyUri; languageId = 'objectpascal'; version = 1; text = $legacyText } } },
            @{ jsonrpc = '2.0'; id = 31; method = 'textDocument/documentSymbol'; params = @{ textDocument = @{ uri = $legacyUri } } },
            @{ jsonrpc = '2.0'; id = 32; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )

        Assert-True ($sess3.Exited -and $sess3.ExitCode -eq 0) 'nik lsp stays alive and exits cleanly with 0 even when workspace nik.yaml is invalid'
        $ymlDiagNotif = @($sess3.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' -and $_.params.uri -match 'nik\.yaml$' })[0]
        Assert-True ($null -ne $ymlDiagNotif -and $ymlDiagNotif.params.diagnostics[0].source -eq 'nik.yaml' -and $ymlDiagNotif.params.diagnostics[0].message -match "use 'program'") 'nik lsp publishes helpful error diagnostic directly onto broken nik.yaml'
        $fallbackSymResp = @($sess3.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 31 })[0]
        Assert-True ($null -ne $fallbackSymResp -and $fallbackSymResp.result[0].name -eq 'LegacyAnswer') 'nik lsp still provides Pascal symbol intelligence via fallback SDK when nik.yaml is broken'

        # Session 4: Live debounced didChange overlay (unsaved buffers), exact %3A client URI preservation, and cross-unit didClose re-validation
        $GreeterPas = Join-Path $LspPkgSrc 'GreeterUnit.pas'
        $greeterRawUri = (ConvertTo-FileUri $GreeterPas) -replace '^file:///([a-z]):/', 'file:///$1%3A/'
        $appEncodedUri = (ConvertTo-FileUri $AppMainPas) -replace '^file:///([a-z]):/', 'file:///$1%3A/'
        $greeterDiskText = [System.IO.File]::ReadAllText($GreeterPas)
        $brokenInMemoryApp = $appMainText.Replace("WriteLn(BuildGreeting('Nikrun'));", "BrokenUnsavedIdent := 99;")
        $brokenInMemoryGreeter = $greeterDiskText.Replace('BuildGreeting', 'BuildGreetingRenamed')

        $sess4 = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspAppDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 40; method = 'initialize'; params = @{ processId = $PID; rootUri = $appRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $appEncodedUri; languageId = 'objectpascal'; version = 1; text = $appMainText } } },
            @{ __waitDiagCount = @{ uri = $appEncodedUri; count = 1 } },
            # Rapid unsaved typing burst (should coalesce via 250ms debounce and report BrokenUnsavedIdent on exact %3A URI)
            @{ jsonrpc = '2.0'; method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $appEncodedUri; version = 2 }; contentChanges = @( @{ text = $brokenInMemoryApp } ) } },
            @{ jsonrpc = '2.0'; method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $appEncodedUri; version = 3 }; contentChanges = @( @{ text = $brokenInMemoryApp } ) } },
            @{ __waitDiagCount = @{ uri = $appEncodedUri; count = 2 } },
            # Fix unsaved buffer in memory without saving to disk -> diagnostics must clear to []
            @{ jsonrpc = '2.0'; method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $appEncodedUri; version = 4 }; contentChanges = @( @{ text = $appMainText } ) } },
            @{ __waitDiagCount = @{ uri = $appEncodedUri; count = 3 } },
            # Open imported GreeterUnit.pas and rename BuildGreeting in memory (unsaved) -> AppMain.pas must detect broken call site
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $greeterRawUri; languageId = 'objectpascal'; version = 1; text = $brokenInMemoryGreeter } } },
            @{ __waitDiagCount = @{ uri = $appEncodedUri; count = 4 } },
            # Close GreeterUnit.pas without saving -> reverts overlay to disk file and clears AppMain.pas error automatically
            @{ jsonrpc = '2.0'; method = 'textDocument/didClose'; params = @{ textDocument = @{ uri = $greeterRawUri } } },
            @{ __waitDiagCount = @{ uri = $appEncodedUri; count = 5 } },
            @{ jsonrpc = '2.0'; id = 41; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )

        Assert-True ($sess4.Exited -and $sess4.ExitCode -eq 0) 'Debounced live-overlay nik lsp session exits cleanly with code 0'
        $appDiagFrames = @($sess4.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' -and $_.params.uri -eq $appEncodedUri })
        Assert-True ($appDiagFrames.Count -ge 4) "nik lsp preserves exact client URI ($appEncodedUri) across live didChange and cross-unit updates (got $($appDiagFrames.Count) notifications)"
        $sawUnsavedErr = @($appDiagFrames | Where-Object { @($_.params.diagnostics).Count -ge 1 -and $_.params.diagnostics[0].message -match 'BrokenUnsavedIdent' }).Count -ge 1
        Assert-True $sawUnsavedErr 'nik lsp detects compiler errors in unsaved didChange buffers via checkout-local overlay'
        $sawCrossUnitErr = @($appDiagFrames | Where-Object { @($_.params.diagnostics).Count -ge 1 -and $_.params.diagnostics[0].message -match 'BuildGreeting' }).Count -ge 1
        Assert-True $sawCrossUnitErr 'nik lsp re-validates open dependent units against unsaved edits in imported units'
        $finalAppDiags = @($appDiagFrames[$appDiagFrames.Count - 1].params.diagnostics)
        Assert-True ($finalAppDiags.Count -eq 0) 'nik lsp clears dependent unit diagnostics automatically when unsaved imported unit is closed'
    }

    Write-Host "`n [OK] All nik CLI tests PASSED!" -ForegroundColor Green
} finally {
    Remove-Job -Job $ServerJob -Force -ErrorAction SilentlyContinue | Out-Null
    if (Test-Path $WorkDir) {
        Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue
    }
}

$global:LASTEXITCODE = 0
exit 0
