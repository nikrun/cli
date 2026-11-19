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

function Invoke-NikSplitStreams {
    param(
        [string]$NikHome,
        [string[]]$Arguments,
        [hashtable]$EnvVars = @{},
        [switch]$AllowFailure
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NikExe
    $allArgs = @('--no-color', '--nikrun-home', $NikHome) + $Arguments
    $escapedArgs = $allArgs | ForEach-Object {
        if ($_ -match '[\s"]') {
            '"' + ($_.Replace('"', '\"')) + '"'
        } else {
            $_
        }
    }
    $psi.Arguments = ($escapedArgs -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    foreach ($kv in $EnvVars.GetEnumerator()) {
        $psi.EnvironmentVariables[$kv.Key] = [string]$kv.Value
    }

    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    $stdoutText = $stdoutTask.GetAwaiter().GetResult()
    $stderrText = $stderrTask.GetAwaiter().GetResult()
    $code = $proc.ExitCode

    if ((-not $AllowFailure) -and ($code -ne 0)) {
        throw "Command failed (exit $code): nik $($Arguments -join ' ')`nSTDOUT:`n$stdoutText`nSTDERR:`n$stderrText"
    }

    return [PSCustomObject]@{
        ExitCode = $code
        StdOut   = $stdoutText
        StdErr   = $stderrText
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
    Assert-True ($sdkHelp.Output -match 'install' -and $sdkHelp.Output -match 'update' -and $sdkHelp.Output -notmatch '\bdefault\b' -and $sdkHelp.Output -match 'uninstall' -and $sdkHelp.Output -match 'info') 'nik sdk --help lists subcommands including update without removed default command'

    # 2. Empty local list & verify nik sdk default is removed
    $emptyJson = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--json')).Output | ConvertFrom-Json
    Assert-True ($null -eq $emptyJson.PSObject.Properties['defaultSdkId'] -and $emptyJson.sdks.Count -eq 0 -and $emptyJson.totalSizeBytes -eq 0) 'nik sdk list --json reports empty state with totalSizeBytes = 0 and without defaultSdkId'

    $removedDef = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'default') -AllowFailure
    Assert-True ($removedDef.ExitCode -ne 0 -and $removedDef.Output -match "Unknown sdk subcommand 'default'") 'nik sdk default subcommand is removed cleanly'

    # 2b. nik init without installed SDK and without --fpc / template.yaml fails cleanly
    $EmptyInitDir = Join-Path $WorkDir 'init-no-sdk'
    $initNoSdkRes = Invoke-Nik -NikHome $TestHome -Arguments @('init', $EmptyInitDir) -AllowFailure
    Assert-True ($initNoSdkRes.ExitCode -ne 0 -and $initNoSdkRes.Output -match 'Cannot determine Free Pascal version') 'nik init fails cleanly when no SDK is installed and no --fpc or template.yaml is given'

    # 2c. nik init rejects an unsafe project name before it touches the SDK lookup or the file system
    $UnsafeInitDir = Join-Path $WorkDir 'init-unsafe-name'
    $initBadName = Invoke-Nik -NikHome $TestHome -Arguments @('init', $UnsafeInitDir, '--name', '../../escape') -AllowFailure
    Assert-True ($initBadName.ExitCode -ne 0 -and $initBadName.Output -match 'Invalid project name') 'nik init rejects a project name with path traversal (even without an installed SDK)'
    Assert-True (-not (Test-Path $UnsafeInitDir)) 'nik init leaves no directory behind when the project name is invalid'

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
    $listTwoRaw = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--json')).Output
    Assert-True ($listTwoRaw -notmatch "[\r\n\t]" -and $listTwoRaw -match '^\{"nikrunHome":"') 'Non-interactive --json output is emitted as compact single-line JSON without newlines or indentation'
    $listTwo = $listTwoRaw | ConvertFrom-Json
    Assert-True ($listTwo.sdks.Count -eq 2 -and $null -eq $listTwo.PSObject.Properties['defaultSdkId'] -and $null -eq $listTwo.sdks[0].PSObject.Properties['default']) 'nik sdk list --json lists both installed SDKs cleanly without default properties'
    Assert-True ($listTwo.sdks[0].sizeBytes -gt 0 -and $listTwo.sdks[1].sizeBytes -gt 0 -and $listTwo.totalSizeBytes -eq ($listTwo.sdks[0].sizeBytes + $listTwo.sdks[1].sizeBytes)) 'nik sdk list --json reports positive sizeBytes per SDK and accurate totalSizeBytes'

    # 7b. Human table layout checks (VERSION TARGET COMMIT SIZE PATH, total summary & INSTALLED commit column)
    $localHuman = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list')).Output
    Assert-True ($localHuman -match '(?m)^VERSION\s+TARGET\s+COMMIT\s+SIZE\s+PATH\r?$' -and $localHuman -match '0d122c49' -and $localHuman -match '(?m)^2 SDKs installed \(.+ total\)\r?$' -and $localHuman -cnotmatch 'DEFAULT' -and $localHuman -cnotmatch 'SDK ID') 'nik sdk list displays VERSION TARGET COMMIT SIZE PATH header and total size summary without DEFAULT or SDK ID'
    $localOneHuman = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--version', '3.2.2')).Output
    Assert-True ($localOneHuman -match '(?m)^1 SDK installed \(.+ total\)\r?$') 'nik sdk list uses singular SDK noun when 1 SDK matches'

    $remoteHuman = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'list', '--remote', '--index-url', $IndexUrl)).Output
    Assert-True ($remoteHuman -match '(?m)^VERSION\s+TARGET\s+COMMIT\s+SIZE\s+INSTALLED\r?$' -and $remoteHuman -notmatch 'SDK ID') 'nik sdk list --remote displays clean VERSION TARGET COMMIT SIZE INSTALLED header'
    Assert-True ($remoteHuman -match '(?m)^3\.2\.2\s+\S+\s+0d122c49\s+\S+\s+\S+\s+0d122c49\r?$' -and $remoteHuman -match '(?m)^9\.9\.9\s+\S+\s+deadbeef\s+\d+\.\d+\s+\S+\r?$') 'nik sdk list --remote shows installed commit in INSTALLED column and leaves uninstalled blank'

    # 7c. Outdated / legacy commit detection & nik sdk update lifecycle
    $UpdateHome = Join-Path $WorkDir 'nikrun-update-home'
    $UpdateSdksDir = Join-Path $UpdateHome 'sdks'
    New-Item -ItemType Directory -Force -Path $UpdateSdksDir | Out-Null

    # Seed a legacy 3.2.2 SDK directory without gitCommit (old sdkId format)
    $LegacySdkId = "nikrun-fpc-sdk-3.2.2-$HostOs-$Arch322"
    $LegacyDir = Join-Path $UpdateSdksDir $LegacySdkId
    Copy-Item -Recurse -Force (Join-Path $StageRoot $Mock322.SdkId) $LegacyDir
    $LegacyManifestPath = Join-Path $LegacyDir 'sdk-manifest.json'
    $LegacyManifest = Get-Content -Path $LegacyManifestPath -Raw | ConvertFrom-Json
    $LegacyManifest.sdkId = $LegacySdkId
    $LegacyManifest.PSObject.Properties.Remove('gitCommit')
    $LegacyManifest.PSObject.Properties.Remove('gitCommitShort')
    $LegacyManifest | ConvertTo-Json -Depth 5 | Set-Content -Path $LegacyManifestPath -Encoding UTF8

    # Also seed an older commit of 3.3.1
    $Mock331Old = New-MockSdkZip -Version '3.3.1' -GitRef 'main' -GitCommit '1111222233334444555566667777888899990000' -TargetOs $HostOs -TargetCpu $HostCpu
    $null = Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'install', $Mock331Old.ZipPath)

    $updLocalOut = (Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'list')).Output
    Assert-True ($updLocalOut -match '(?m)^3\.2\.2\s+\S+\s+unknown\s+' -and $updLocalOut -match '(?m)^3\.3\.1\s+\S+\s+11112222\s+') 'nik sdk list shows unknown for legacy manifest without gitCommit and short SHA for commit-tracked SDK'

    $updRemOut = (Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'list', '--remote', '--index-url', $IndexUrl)).Output
    Assert-True ($updRemOut -match '(?m)^3\.2\.2\s+.*\s+unknown \(update\)\r?$' -and $updRemOut -match '(?m)^3\.3\.1\s+.*\s+11112222 \(update\)\r?$') 'nik sdk list --remote flags both legacy unknown and older commit SDKs with (update)'

    $updRemJson = (Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'list', '--remote', '--index-url', $IndexUrl, '--json')).Output | ConvertFrom-Json
    $rem322Item = $updRemJson.sdks | Where-Object { $_.fpcVersion -eq '3.2.2' }
    $rem331Item = $updRemJson.sdks | Where-Object { $_.fpcVersion -eq '3.3.1' }
    Assert-True ($rem322Item.installed -eq $true -and $rem322Item.updateAvailable -eq $true -and $null -eq $rem322Item.installedCommit -and $rem331Item.installed -eq $true -and $rem331Item.updateAvailable -eq $true -and $rem331Item.installedCommit -eq $Mock331Old.GitCommit) 'nik sdk list --remote --json reports installed, updateAvailable, and installedCommit accurately'

    # Verify nik sdk install leaves existing older snapshot directory intact
    $null = Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'install', '3.3.1', '--index-url', $IndexUrl)
    Assert-True ((Test-Path (Join-Path $UpdateSdksDir $Mock331Old.SdkId)) -and (Test-Path (Join-Path $UpdateSdksDir $Mock331.SdkId))) 'nik sdk install leaves older snapshot directory untouched'

    # Run nik sdk update (updates 3.2.2 from remote and prunes superseded 3.2.2 + 3.3.1 directories)
    $updResJson = (Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'update', '--index-url', $IndexUrl, '--json')).Output | ConvertFrom-Json
    Assert-True ($updResJson.updatedCount -eq 2 -and $updResJson.upToDateCount -eq 0) 'nik sdk update --json updates outdated SDKs and prunes superseded snapshots'
    Assert-True ((-not (Test-Path $LegacyDir)) -and (Test-Path (Join-Path $UpdateSdksDir $Mock322.SdkId)) -and (-not (Test-Path (Join-Path $UpdateSdksDir $Mock331Old.SdkId))) -and (Test-Path (Join-Path $UpdateSdksDir $Mock331.SdkId))) 'nik sdk update removes superseded snapshot folders while keeping current SDKs'

    # Subsequent nik sdk update reports everything up to date
    $updNoopJson = (Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'update', '--index-url', $IndexUrl, '--json')).Output | ConvertFrom-Json
    Assert-True ($updNoopJson.updatedCount -eq 0 -and $updNoopJson.upToDateCount -eq 2) 'Second nik sdk update reports all installed SDKs up to date'

    $updMissing = Invoke-Nik -NikHome $UpdateHome -Arguments @('sdk', 'update', '3.2.4', '--index-url', $IndexUrl) -AllowFailure
    Assert-True ($updMissing.ExitCode -ne 0 -and $updMissing.Output -match 'not found') 'nik sdk update <uninstalled-version> fails cleanly'

    # 8. nik sdk info requires explicit <version> and rejects missing argument or SDK IDs
    $infoNoArg = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info') -AllowFailure
    Assert-True ($infoNoArg.ExitCode -ne 0 -and $infoNoArg.Output -match 'Missing Free Pascal SDK version') 'nik sdk info requires explicit version argument'

    $infoById = Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', $Mock322.SdkId) -AllowFailure
    Assert-True ($infoById.ExitCode -ne 0 -and $infoById.Output -match 'Invalid Free Pascal SDK version') 'nik sdk info rejects SDK IDs and only accepts exact versions'

    $info322 = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', '3.2.2', '--json')).Output | ConvertFrom-Json
    Assert-True ($info322.sdkId -eq $Mock322.SdkId -and $info322.gitCommit -eq $Mock322.GitCommit -and $info322.sizeBytes -gt 0 -and $null -eq $info322.PSObject.Properties['default'] -and $info322.healthy -eq $true) 'nik sdk info 3.2.2 inspects SDK, gitCommit, sizeBytes, and verifies health'
    $info322Human = (Invoke-Nik -NikHome $TestHome -Arguments @('sdk', 'info', '3.2.2')).Output
    Assert-True ($info322Human -match 'Install Size\s+:\s+\d+') 'nik sdk info human output displays Install Size'

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

    $InitEndDir = Join-Path $WorkDir 'init-reserved-name'
    $initEnd = (Invoke-Nik -NikHome $TestHome -Arguments @('init', $InitEndDir, '--pkg', '--name', 'types', '--json')).Output | ConvertFrom-Json
    $initEndSource = Get-Content -Raw -Path (Join-Path (Join-Path $InitEndDir 'src') 'TypesUnit.pas')
    Assert-True ($initEnd.success -eq $true -and $initEndSource -match '(?m)^unit TypesUnit;') 'nik init --pkg never generates a unit that hides a standard unit (types -> TypesUnit)'

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

    # 13g. nik build automatic missing-SDK provisioning via mock index, --offline guard & --json stdout purity
    $AutoMockHome = Join-Path $WorkDir 'nikrun-auto-mock-home'
    $AutoMockProj = Join-Path $WorkDir 'auto-mock-proj'
    $AutoCorruptProj = Join-Path $WorkDir 'auto-corrupt-proj'
    New-Item -ItemType Directory -Force -Path $AutoMockHome, $AutoMockProj, $AutoCorruptProj | Out-Null

    @"
program:
  name: auto-mock-app
  entry: missing_entry.pas
  toolchain:
    fpc: 3.2.2
"@ | Set-Content -Path (Join-Path $AutoMockProj 'nik.yaml') -Encoding UTF8

    # --offline must NEVER touch the network (even with an unreachable index URL) and must report missing local SDK cleanly
    $offlineMissHuman = Invoke-NikSplitStreams -NikHome $AutoMockHome -Arguments @('build', '-m', $AutoMockProj, '--offline') -EnvVars @{ NIKRUN_SDK_INDEX_URL = 'http://127.0.0.1:1/unreachable-index.json' } -AllowFailure
    Assert-True ($offlineMissHuman.ExitCode -ne 0 -and $offlineMissHuman.StdErr -match "Installed Free Pascal SDK '3\.2\.2' not found" -and -not (Test-Path (Join-Path $AutoMockHome 'sdks'))) 'nik build --offline fails cleanly without network access when required SDK is missing locally'

    $offlineMissJsonRaw = Invoke-NikSplitStreams -NikHome $AutoMockHome -Arguments @('build', '-m', $AutoMockProj, '--offline', '--json') -EnvVars @{ NIKRUN_SDK_INDEX_URL = 'http://127.0.0.1:1/unreachable-index.json' } -AllowFailure
    Assert-True ($offlineMissJsonRaw.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($offlineMissJsonRaw.StdErr)) 'nik build --offline --json keeps stderr clean and emits structured error on stdout'
    $offlineMissJson = $offlineMissJsonRaw.StdOut.Trim() | ConvertFrom-Json
    Assert-True ($offlineMissJson.success -eq $false -and $offlineMissJson.sdkInstalled -eq $false -and $offlineMissJson.error -match "Installed Free Pascal SDK '3\.2\.2' not found") 'nik build --offline --json reports sdkInstalled=false and missing local SDK error'

    # Corrupted SHA-256 archive must be rejected during nik build auto-install with clean JSON stdout
    @"
program:
  name: auto-corrupt-app
  entry: main.pas
  toolchain:
    fpc: 9.9.9
"@ | Set-Content -Path (Join-Path $AutoCorruptProj 'nik.yaml') -Encoding UTF8
    $corruptBuildRaw = Invoke-NikSplitStreams -NikHome $AutoMockHome -Arguments @('build', '-m', $AutoCorruptProj, '--json') -EnvVars @{ NIKRUN_SDK_INDEX_URL = $IndexUrl } -AllowFailure
    Assert-True ($corruptBuildRaw.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($corruptBuildRaw.StdErr)) 'nik build --json keeps stdout/stderr clean when auto-installed SDK fails SHA-256 verification'
    $corruptBuildJson = $corruptBuildRaw.StdOut.Trim() | ConvertFrom-Json
    Assert-True ($corruptBuildJson.success -eq $false -and $corruptBuildJson.sdkInstalled -eq $false -and $corruptBuildJson.error -match 'SHA-256 checksum mismatch' -and -not (Test-Path (Join-Path (Join-Path $AutoMockHome 'sdks') $MockBad.SdkId))) 'nik build rejects auto-downloaded SDK archive with invalid SHA-256 checksum'

    # Online nik build --json downloads, SHA-256-verifies & installs missing 3.2.2 SDK without polluting stdout, and reports sdkInstalled=true even when entry file fails afterwards
    $autoMockJsonRaw = Invoke-NikSplitStreams -NikHome $AutoMockHome -Arguments @('build', '-m', $AutoMockProj, '--json') -EnvVars @{ NIKRUN_SDK_INDEX_URL = $IndexUrl } -AllowFailure
    Assert-True ($autoMockJsonRaw.ExitCode -ne 0 -and [string]::IsNullOrWhiteSpace($autoMockJsonRaw.StdErr) -and $autoMockJsonRaw.StdOut.Trim() -notmatch "[\r\n]") 'nik build --json auto-installing missing SDK emits single-line valid JSON on stdout with zero progress noise'
    $autoMockJson = $autoMockJsonRaw.StdOut.Trim() | ConvertFrom-Json
    Assert-True ($autoMockJson.sdkInstalled -eq $true -and $autoMockJson.error -match 'Entry source file not found') 'nik build --json reports sdkInstalled=true when SDK was provisioned before subsequent preflight error'
    Assert-True (Test-Path ([System.IO.Path]::Combine($AutoMockHome, 'sdks', $Mock322.SdkId, 'bin', $Mock322.TargetTriplet, 'fpc.cfg'))) 'Auto-installed mock SDK contains generated isolated fpc.cfg in ~/.nikrun/sdks'

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
            Assert-True ($quickBuild.success -eq $true -and $quickBuild.toolchain.sdkInstalled -eq $false -and (Test-Path $quickBuild.output.binaryPath)) 'nik build compiles freshly initialized nik init project out of the box (sdkInstalled=false when already present)'
            $quickOut = (& $quickBuild.output.binaryPath).Trim()
            Assert-True ($quickOut -eq 'Hello from quick-init-app!') "Compiled nik init starter binary runs cleanly ($quickOut)"

            # End-to-end nik build auto-install of a real missing FPC SDK via local HTTP index (--offline vs --json vs cached second run)
            $RealServerZipPath = Join-Path $ServerDir $RealZip.Name
            if (-not (Test-Path $RealServerZipPath)) {
                Copy-Item -Force $RealZip.FullName $RealServerZipPath
            }
            $RealZipSha = (Get-FileHash -Path $RealServerZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $RealZipLen = (Get-Item $RealServerZipPath).Length
            $RealIndexObj = [ordered]@{
                schemaVersion = 1
                releaseTag    = 'fpc-sdk-real-e2e'
                updatedAtUtc  = '2026-11-19T12:00:00Z'
                sdks          = @(
                    [ordered]@{
                        sdkId         = [string]$realInfo.sdkId
                        fpcVersion    = [string]$realInfo.fpcVersion
                        gitRef        = [string]$realInfo.gitRef
                        gitCommit     = [string]$realInfo.gitCommit
                        targetOs      = [string]$realInfo.targetOs
                        targetCpu     = [string]$realInfo.targetCpu
                        targetTriplet = [string]$realInfo.targetTriplet
                        builtAtUtc    = '2026-11-19T12:00:00Z'
                        fileName      = $RealZip.Name
                        sizeBytes     = $RealZipLen
                        sha256        = $RealZipSha
                        downloadUrl   = "$BaseUrl/$($RealZip.Name)"
                    }
                )
            }
            $RealIndexObj | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $ServerDir 'real-sdk-index.json') -Encoding UTF8
            $RealIndexUrl = "$BaseUrl/real-sdk-index.json"

            $AutoRealHome = Join-Path $WorkDir 'nikrun-auto-real-home'
            New-Item -ItemType Directory -Force -Path $AutoRealHome | Out-Null

            $autoRealOffline = Invoke-NikSplitStreams -NikHome $AutoRealHome -Arguments @('build', '-m', $QuickInitDir, '--offline') -EnvVars @{ NIKRUN_SDK_INDEX_URL = $RealIndexUrl } -AllowFailure
            Assert-True ($autoRealOffline.ExitCode -ne 0 -and $autoRealOffline.StdErr -match "Installed Free Pascal SDK '$([regex]::Escape($realFpcVersion))' not found" -and -not (Test-Path (Join-Path $AutoRealHome 'sdks'))) 'nik build --offline refuses to download real SDK into empty NIKRUN_HOME'

            $autoRealFirst = Invoke-NikSplitStreams -NikHome $AutoRealHome -Arguments @('build', '-m', $QuickInitDir, '--clean', '--json') -EnvVars @{ NIKRUN_SDK_INDEX_URL = $RealIndexUrl }
            Assert-True ([string]::IsNullOrWhiteSpace($autoRealFirst.StdErr) -and $autoRealFirst.StdOut.Trim() -notmatch "[\r\n]" -and $autoRealFirst.StdOut.Trim() -match '^\{') 'nik build --json auto-installing real SDK emits pure single-line JSON on stdout with empty stderr'
            $autoRealFirstJson = $autoRealFirst.StdOut.Trim() | ConvertFrom-Json
            Assert-True ($autoRealFirstJson.success -eq $true -and $autoRealFirstJson.toolchain.sdkInstalled -eq $true -and $autoRealFirstJson.toolchain.fpcVersion -eq $realFpcVersion -and (Test-Path $autoRealFirstJson.toolchain.installPath) -and (Test-Path $autoRealFirstJson.toolchain.fpcCfg) -and (Test-Path $autoRealFirstJson.output.binaryPath)) 'nik build --json automatically downloads, SHA-256-verifies, configures fpc.cfg, compiles project, and sets toolchain.sdkInstalled=true'
            $autoRealOut = (& $autoRealFirstJson.output.binaryPath).Trim()
            Assert-True ($autoRealOut -eq 'Hello from quick-init-app!') "Binary compiled with auto-installed real SDK executes cleanly ($autoRealOut)"

            $autoRealSecond = Invoke-NikSplitStreams -NikHome $AutoRealHome -Arguments @('build', '-m', $QuickInitDir, '--json') -EnvVars @{ NIKRUN_SDK_INDEX_URL = 'http://127.0.0.1:1/unreachable-index.json' }
            $autoRealSecondJson = $autoRealSecond.StdOut.Trim() | ConvertFrom-Json
            Assert-True ($autoRealSecondJson.success -eq $true -and $autoRealSecondJson.toolchain.sdkInstalled -eq $false) 'Subsequent nik build --json uses newly installed local SDK without network and sets toolchain.sdkInstalled=false'

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
      mock-assert: https://github.com/example/mock-assert@^0.1.0
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
      test-only-helper: https://github.com/example/test-only-helper@^1.0.0

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

            # 14d. Profile overriding toolchain.fpc triggers target SDK lookup (--offline local check & online remote index lookup)
            $missSdkOffline = Invoke-Nik -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '--profile', 'missing-sdk', '--offline') -AllowFailure
            Assert-True ($missSdkOffline.ExitCode -ne 0 -and $missSdkOffline.Output -match "Installed Free Pascal SDK '9\.8\.7' not found") 'Profile toolchain.fpc override selects profile-specific SDK version (--offline)'
            $missSdkOnline = Invoke-NikSplitStreams -NikHome $TestHome -Arguments @('build', '-m', $AppDir, '--profile', 'missing-sdk') -EnvVars @{ NIKRUN_SDK_INDEX_URL = $RealIndexUrl } -AllowFailure
            Assert-True ($missSdkOnline.ExitCode -ne 0 -and $missSdkOnline.StdErr -match "No prebuilt SDK version '9\.8\.7' found") 'Profile toolchain.fpc override attempts remote lookup when online and fails cleanly if absent from index'

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
                } elseif ($m -is [hashtable] -and $m.ContainsKey('__waitPath')) {
                    $proc.StandardInput.BaseStream.Flush()
                    $targetPath = [string]$m['__waitPath']
                    $sw = [System.Diagnostics.Stopwatch]::StartNew()
                    while ((-not (Test-Path $targetPath)) -and ($sw.ElapsedMilliseconds -lt 10000)) {
                        if ($proc.HasExited -and $null -eq $state.PendingRead) {
                            break
                        }
                        & $pumpOutput 25
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

            $cpuSeconds = -1.0
            try { $cpuSeconds = $proc.TotalProcessorTime.TotalSeconds } catch { }

            return [PSCustomObject]@{
                Exited     = $exited
                ExitCode   = $proc.ExitCode
                Frames     = $parsedFrames.ToArray()
                Stderr     = $stderrText
                CpuSeconds = $cpuSeconds
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
        Assert-True ($null -ne $hovResp -and $hovResp.result.contents.value -match 'function BuildGreeting\(const AName: string\): string;' -and $hovResp.result.contents.value -match 'friendly greeting string') 'nik lsp Hover displays formatted signature and preceding /// doc comment'

        $sigResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 14 })[0]
        Assert-True ($null -ne $sigResp -and @($sigResp.result.signatures).Count -ge 1 -and $sigResp.result.signatures[0].parameters[0].label -match 'const AName: string') 'nik lsp SignatureHelp extracts formatted routine parameter labels'

        $cmpResp = @($sess2.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 15 })[0]
        $cmpLabels = @($cmpResp.result.items | ForEach-Object { $_.label })
        $bgItem = @($cmpResp.result.items | Where-Object { $_.label -eq 'BuildGreeting' })[0]
        Assert-True ($cmpLabels -contains 'BuildGreeting' -and $cmpLabels -contains 'TRunner' -and $bgItem.detail -eq 'function BuildGreeting(const AName: string): string;') 'nik lsp Completion suggests local and imported package symbols with formatted detail'

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

        # Session 3a: queued re-checks must not spin the server loop while the workspace is not ready.
        # Changing an .inc file queues every open Pascal document; without a usable nik.yaml none of them can start.
        $LspIncFile = Join-Path $LspBadYmlSrc 'Shared.inc'
        'const SharedValue = 1;' | Set-Content -Path $LspIncFile -Encoding UTF8
        $incUri  = ConvertTo-FileUri $LspIncFile
        $incText = [System.IO.File]::ReadAllText($LspIncFile)
        $sess3a = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspBadYmlDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 35; method = 'initialize'; params = @{ processId = $PID; rootUri = $badRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $incUri; languageId = 'objectpascal'; version = 1; text = $incText } } },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $legacyUri; languageId = 'objectpascal'; version = 1; text = $legacyText } } },
            @{ jsonrpc = '2.0'; method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $incUri; version = 2 }; contentChanges = @(@{ text = 'const SharedValue = 2;' }) } },
            @{ __sleepMs = 3000 },
            @{ jsonrpc = '2.0'; id = 36; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )
        Assert-True ($sess3a.Exited -and $sess3a.ExitCode -eq 0) 'nik lsp exits cleanly after queued re-checks with an unusable workspace'
        Assert-True (($sess3a.CpuSeconds -ge 0) -and ($sess3a.CpuSeconds -lt 1.5)) "nik lsp idles instead of spinning while queued checks cannot start (CPU $([math]::Round($sess3a.CpuSeconds, 2)) s over a 3 s idle window)"

        # Session 3b: nik lsp must NEVER auto-download a missing SDK silently in the background (even when NIKRUN_SDK_INDEX_URL is valid)
        $LspNoAutoHome = Join-Path $WorkDir 'nikrun-lsp-no-auto-home'
        $LspMissingSdkProj = Join-Path $WorkDir 'lsp-missing-sdk-proj'
        New-Item -ItemType Directory -Force -Path $LspNoAutoHome, $LspMissingSdkProj | Out-Null
        @"
program:
  name: lsp-no-auto
  entry: main.pas
  toolchain:
    fpc: 3.2.2
"@ | Set-Content -Path (Join-Path $LspMissingSdkProj 'nik.yaml') -Encoding UTF8
        @"
program LspNoAuto;
function LocalHelperValue: Integer;
begin
  Result := 7;
end;
begin
end.
"@ | Set-Content -Path (Join-Path $LspMissingSdkProj 'main.pas') -Encoding UTF8

        $prevIdxEnv = $env:NIKRUN_SDK_INDEX_URL
        $env:NIKRUN_SDK_INDEX_URL = $IndexUrl
        try {
            $noAutoRootUri = ConvertTo-FileUri $LspMissingSdkProj
            $noAutoMainPas = Join-Path $LspMissingSdkProj 'main.pas'
            $noAutoMainUri = ConvertTo-FileUri $noAutoMainPas
            $noAutoMainText = [System.IO.File]::ReadAllText($noAutoMainPas)
            $sessNoAuto = Invoke-LspSession -NikHomeDir $LspNoAutoHome -ProjectPath $LspMissingSdkProj -LogPath '' -Messages @(
                @{ jsonrpc = '2.0'; id = 35; method = 'initialize'; params = @{ processId = $PID; rootUri = $noAutoRootUri } },
                @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
                @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $noAutoMainUri; languageId = 'objectpascal'; version = 1; text = $noAutoMainText } } },
                @{ jsonrpc = '2.0'; id = 36; method = 'textDocument/documentSymbol'; params = @{ textDocument = @{ uri = $noAutoMainUri } } },
                @{ jsonrpc = '2.0'; id = 37; method = 'shutdown' },
                @{ jsonrpc = '2.0'; method = 'exit' }
            )
            Assert-True ($sessNoAuto.Exited -and $sessNoAuto.ExitCode -eq 0) 'nik lsp starts and shuts down cleanly when required SDK is missing locally'
            Assert-True (-not (Test-Path (Join-Path $LspNoAutoHome 'sdks'))) 'nik lsp never downloads missing SDKs silently in the background'
            $noAutoYmlDiag = @($sessNoAuto.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' -and $_.params.uri -match 'nik\.yaml$' })[0]
            Assert-True ($null -ne $noAutoYmlDiag -and $noAutoYmlDiag.params.diagnostics[0].message -match "Installed Free Pascal SDK '3\.2\.2' not found") 'nik lsp reports missing SDK diagnostic on nik.yaml instead of blocking on network download'
            $noAutoSymResp = @($sessNoAuto.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 36 })[0]
            Assert-True ($null -ne $noAutoSymResp -and @($noAutoSymResp.result | Where-Object { $_.name -eq 'LocalHelperValue' }).Count -eq 1) 'nik lsp still provides local AST document symbols via CodeTools even without an installed SDK'
        } finally {
            $env:NIKRUN_SDK_INDEX_URL = $prevIdxEnv
        }

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

        # Session 5: CodeTools semantic resolution — {$IFDEF} + {$I *.inc}, incomplete-line dot completion (Worker.), declaration vs definition toggle, and checkout-local cache
        $LspCtDir = Join-Path $WorkDir 'lsp-codetools'
        $LspCtSrc = Join-Path $LspCtDir 'src'
        $LspCtInc = Join-Path $LspCtDir 'inc'
        New-Item -ItemType Directory -Force -Path $LspCtSrc, $LspCtInc | Out-Null

        @"
program:
  name: lsp-codetools
  entry: src/CtApp.pas
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
    includePaths: [inc]
    defines: [FEATURE_ALPHA]
"@ | Set-Content -Path (Join-Path $LspCtDir 'nik.yaml') -Encoding UTF8

        @"
{`$IFDEF FEATURE_ALPHA}
/// Returned only when FEATURE_ALPHA is active in nik.yaml.
function ActiveFeatureValue: Integer;
{`$ELSE}
function InactiveFeatureOnly: Integer;
{`$ENDIF}
"@ | Set-Content -Path (Join-Path $LspCtInc 'feature_header.inc') -Encoding UTF8

        @"
unit FeatureUnit;
{`$mode objfpc}{`$H+}
interface

{`$I feature_header.inc}

implementation

{`$IFDEF FEATURE_ALPHA}
function ActiveFeatureValue: Integer;
begin
  Result := 7;
end;
{`$ELSE}
function InactiveFeatureOnly: Integer;
begin
  Result := 0;
end;
{`$ENDIF}

end.
"@ | Set-Content -Path (Join-Path $LspCtSrc 'FeatureUnit.pas') -Encoding UTF8

        $CtAppPas = Join-Path $LspCtSrc 'CtApp.pas'
        @"
program CtApp;
{`$mode objfpc}{`$H+}
uses
  SysUtils, FeatureUnit;

type
  TWorker = class
  public
    procedure RunTask;
  end;

procedure TWorker.RunTask;
begin
  WriteLn(ActiveFeatureValue);
end;

var
  Worker: TWorker;
begin
  Worker.RunTask;
end.
"@ | Set-Content -Path $CtAppPas -Encoding UTF8

        $FeaturePas = Join-Path $LspCtSrc 'FeatureUnit.pas'
        $ctRootUri = ConvertTo-FileUri $LspCtDir
        $ctAppUri  = ConvertTo-FileUri $CtAppPas
        $featureUri = ConvertTo-FileUri $FeaturePas
        $ctAppText = [System.IO.File]::ReadAllText($CtAppPas)
        $featureText = [System.IO.File]::ReadAllText($FeaturePas)
        $ctIncompleteDotText = $ctAppText.Replace('  Worker.RunTask;', '  Worker.')

        $sess5 = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspCtDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 50; method = 'initialize'; params = @{ processId = $PID; rootUri = $ctRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            # Open FeatureUnit.pas (UTF-8 BOM on disk, stripped by ReadAllText/VS Code) which includes UTF-8 BOM feature_header.inc -> must NOT emit FPC Error 2089
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $featureUri; languageId = 'objectpascal'; version = 1; text = $featureText } } },
            @{ __waitDiagCount = @{ uri = $featureUri; count = 1 } },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $ctAppUri; languageId = 'objectpascal'; version = 1; text = $ctAppText } } },
            # 51: Go to Definition on ActiveFeatureValue (line 13, char 14) -> resolves into inc/feature_header.inc
            @{ jsonrpc = '2.0'; id = 51; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $ctAppUri }; position = @{ line = 13; character = 14 } } },
            # 52: Completion inside RunTask body -> contains ActiveFeatureValue, excludes InactiveFeatureOnly from inactive {$ELSE}
            @{ jsonrpc = '2.0'; id = 52; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $ctAppUri }; position = @{ line = 13; character = 14 } } },
            # 53: Definition on interface/class header 'procedure RunTask;' (line 8, char 16) -> jumps to implementation body (line 11)
            @{ jsonrpc = '2.0'; id = 53; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $ctAppUri }; position = @{ line = 8; character = 16 } } },
            # 54: Declaration on implementation body 'procedure TWorker.RunTask;' (line 11, char 20) -> jumps to class header (line 8)
            @{ jsonrpc = '2.0'; id = 54; method = 'textDocument/declaration'; params = @{ textDocument = @{ uri = $ctAppUri }; position = @{ line = 11; character = 20 } } },
            # Unsaved incomplete typing edit: '  Worker.' (broken syntax without semicolon/member) -> dot completion at line 19, char 9
            @{ jsonrpc = '2.0'; method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $ctAppUri; version = 2 }; contentChanges = @( @{ text = $ctIncompleteDotText } ) } },
            @{ jsonrpc = '2.0'; id = 55; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $ctAppUri }; position = @{ line = 19; character = 9 } } },
            @{ jsonrpc = '2.0'; id = 56; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )

        Assert-True ($sess5.Exited -and $sess5.ExitCode -eq 0) 'CodeTools semantic nik lsp session exits cleanly with code 0'

        $featureDiagFrame = @($sess5.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' -and $_.params.uri -eq $featureUri })[0]
        Assert-True ($null -ne $featureDiagFrame -and @($featureDiagFrame.params.diagnostics).Count -eq 0) 'nik lsp preserves UTF-8 BOM on overlay files so open units including UTF-8 BOM .inc files do not trigger FPC Error 2089'

        $incDefResp = @($sess5.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 51 })[0]
        Assert-True ($null -ne $incDefResp -and @($incDefResp.result).Count -ge 1 -and $incDefResp.result[0].uri -match 'feature_header\.inc$') 'CodeTools resolves Go-to-Definition into {$I feature_header.inc} via nik.yaml includePaths and defines'

        $condCmpResp = @($sess5.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 52 })[0]
        $condLabels = @($condCmpResp.result.items | ForEach-Object { $_.label })
        Assert-True (($condLabels -contains 'ActiveFeatureValue') -and ($condLabels -notcontains 'InactiveFeatureOnly')) 'CodeTools evaluates nik.yaml defines ({$IFDEF FEATURE_ALPHA}) accurately in Completion'

        $jumpImplResp = @($sess5.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 53 })[0]
        Assert-True ($null -ne $jumpImplResp -and @($jumpImplResp.result).Count -ge 1 -and $jumpImplResp.result[0].range.start.line -ge 11 -and $jumpImplResp.result[0].range.start.line -le 13) 'Go-to-Definition on class method header jumps to implementation body'

        $jumpDeclResp = @($sess5.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 54 })[0]
        Assert-True ($null -ne $jumpDeclResp -and @($jumpDeclResp.result).Count -ge 1 -and $jumpDeclResp.result[0].range.start.line -eq 8) 'Go-to-Declaration on method implementation jumps back to class declaration'

        $dotCmpResp = @($sess5.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 55 })[0]
        $dotLabels = @($dotCmpResp.result.items | ForEach-Object { $_.label })
        Assert-True (($dotLabels -contains 'RunTask') -and ($dotLabels -contains 'Free') -and ($dotLabels -notcontains 'ActiveFeatureValue')) 'CodeTools resolves instance variable type on incomplete line (Worker.) for dot completion'

        $ctCacheXml = Get-ChildItem -Path (Join-Path $LspCtDir '.nik') -Recurse -Filter 'codetools-config.xml' -ErrorAction SilentlyContinue
        Assert-True ($null -ne $ctCacheXml -and @($ctCacheXml).Count -ge 1) 'CodeTools persists compiler defines cache strictly inside checkout-local .nik/cache/'

        # Session 6: Automatic .ppu cache invalidation when nik.yaml changes (both nik build and nik lsp)
        $ctManifestPath = Join-Path $LspCtDir 'nik.yaml'
        $buildAlpha = Invoke-Nik -NikHome $CandidateLspHome -Arguments @('build', '--manifest', $ctManifestPath)
        Assert-True ($buildAlpha.ExitCode -eq 0) 'nik build compiles CtApp cleanly when FEATURE_ALPHA is defined in nik.yaml'

        $ctManifestRaw = [System.IO.File]::ReadAllText($ctManifestPath)
        $ctManifestRaw.Replace('FEATURE_ALPHA', 'FEATURE_TYPO') | Set-Content -Path $ctManifestPath -Encoding UTF8

        $buildTypo = Invoke-Nik -NikHome $CandidateLspHome -Arguments @('build', '--manifest', $ctManifestPath) -AllowFailure
        Assert-True (($buildTypo.ExitCode -ne 0) -and ($buildTypo.Output -match 'ActiveFeatureValue')) 'nik build invalidates cached .ppu files automatically when nik.yaml defines change without requiring --clean'

        $sess6 = Invoke-LspSession -NikHomeDir $CandidateLspHome -ProjectPath $LspCtDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 60; method = 'initialize'; params = @{ processId = $PID; rootUri = $ctRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $ctAppUri; languageId = 'objectpascal'; version = 1; text = $ctAppText } } },
            @{ __waitDiagCount = @{ uri = $ctAppUri; count = 1 } },
            @{ jsonrpc = '2.0'; id = 61; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )

        Assert-True ($sess6.Exited -and $sess6.ExitCode -eq 0) 'Cache-invalidation nik lsp session exits cleanly with code 0'
        $ctAppDiagFrame = @($sess6.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' -and $_.params.uri -eq $ctAppUri })[0]
        Assert-True ($null -ne $ctAppDiagFrame -and @($ctAppDiagFrame.params.diagnostics).Count -ge 1 -and $ctAppDiagFrame.params.diagnostics[0].message -match 'ActiveFeatureValue') 'nik lsp purges stale cached .ppu files when nik.yaml defines change so dependent main program reports missing identifier immediately'

        # Session 7: nik.yaml Manifest Code Intelligence (DocumentSymbol, Hover with FPC flags & SDK status, Key/Enum/SDK/Path Completions, background sdk-index.json refresh, and Go-to-Definition)
        $HostTriplet = "$HostCpu-$HostOs"
        $LspYamlHome = Join-Path $WorkDir 'nikrun-lsp-yaml-home'
        $LspYamlSdkDir = Join-Path $LspYamlHome "sdks\nikrun-fpc-sdk-3.2.2-test-$HostTriplet"
        New-Item -ItemType Directory -Force -Path (Join-Path $LspYamlSdkDir 'bin') | Out-Null
        $exeSuffix = if ($HostOs -eq 'win64') { '.exe' } else { '' }
        $ppcDummyRel = if ($HostCpu -eq 'aarch64') { "bin/ppca64$exeSuffix" } else { "bin/ppcx64$exeSuffix" }
        Set-Content -Path (Join-Path $LspYamlSdkDir ($ppcDummyRel -replace '/', [System.IO.Path]::DirectorySeparatorChar)) -Value 'stub' -Encoding ASCII
        Set-Content -Path (Join-Path $LspYamlSdkDir "bin\fpc$exeSuffix") -Value 'stub' -Encoding ASCII
        Set-Content -Path (Join-Path $LspYamlSdkDir 'bin\fpc.cfg') -Value '# stub' -Encoding ASCII
        ([ordered]@{
            schemaVersion = 1
            sdkId         = "nikrun-fpc-sdk-3.2.2-test-$HostTriplet"
            fpcVersion    = '3.2.2'
            gitCommit     = 'abcdef1234567890'
            targetOs      = $HostOs
            targetCpu     = $HostCpu
            targetTriplet = $HostTriplet
            builtAtUtc    = '2026-11-19T12:00:00Z'
            paths         = [ordered]@{
                binDir    = 'bin'
                fpcBinary = "bin/fpc$exeSuffix"
                ppcBinary = $ppcDummyRel
            }
        } | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $LspYamlSdkDir 'sdk-manifest.json') -Encoding UTF8

        # Serve a dedicated remote index.json advertising both installed 3.2.2 and online-only 3.99.0
        $LspYamlRemoteIndexFile = Join-Path $ServerDir 'lsp-yaml-index.json'
        ([ordered]@{
            schemaVersion = 1
            releaseTag    = 'fpc-sdk-lsp-test'
            updatedAtUtc  = '2026-11-19T12:00:00Z'
            sdks          = @(
                [ordered]@{
                    sdkId         = "nikrun-fpc-sdk-3.2.2-test-$HostTriplet"
                    fpcVersion    = '3.2.2'
                    gitCommit     = 'abcdef1234567890'
                    targetOs      = $HostOs
                    targetCpu     = $HostCpu
                    targetTriplet = $HostTriplet
                    builtAtUtc    = '2026-11-19T12:00:00Z'
                    fileName      = "nikrun-fpc-sdk-3.2.2-$HostTriplet.zip"
                    sizeBytes     = 41943040
                    sha256        = ('a' * 64)
                    downloadUrl   = "$BaseUrl/nikrun-fpc-sdk-3.2.2-$HostTriplet.zip"
                },
                [ordered]@{
                    sdkId         = "nikrun-fpc-sdk-3.99.0-online-$HostTriplet"
                    fpcVersion    = '3.99.0'
                    gitCommit     = '9999999911111111'
                    targetOs      = $HostOs
                    targetCpu     = $HostCpu
                    targetTriplet = $HostTriplet
                    builtAtUtc    = '2026-11-19T12:00:00Z'
                    fileName      = "nikrun-fpc-sdk-3.99.0-$HostTriplet.zip"
                    sizeBytes     = 52428800
                    sha256        = ('b' * 64)
                    downloadUrl   = "$BaseUrl/nikrun-fpc-sdk-3.99.0-$HostTriplet.zip"
                }
            )
        } | ConvertTo-Json -Depth 6) | Set-Content -Path $LspYamlRemoteIndexFile -Encoding UTF8

        $appManifestPath = Join-Path $LspAppDir 'nik.yaml'
        $appManifestUri  = ConvertTo-FileUri $appManifestPath
        $yamlDocText = @"
program:
  name: lsp-app
  entry: src/AppMain.pas
  toolchain:
    fpc: 3.2.2
  build:
    mode: objfpc
    cOperators: true
    unitPaths: [src]
  dependencies:
    lsp-dep-pkg:
      path: ../lsp-dep-pkg
"@
        $yamlEditingText = @"
program:
  name: lsp-app
  entry: 
  toolchain:
    fpc: 
  build:
    mode: 
    cOperators: true
    
  dependencies:
    lsp-dep-pkg:
      path: ../lsp-dep-pkg
"@

        $prevYamlIdxEnv = $env:NIKRUN_SDK_INDEX_URL
        $env:NIKRUN_SDK_INDEX_URL = "$BaseUrl/lsp-yaml-index.json"
        try {
            $sess7 = Invoke-LspSession -NikHomeDir $LspYamlHome -ProjectPath $LspAppDir -LogPath '' -Messages @(
                @{ jsonrpc = '2.0'; id = 70; method = 'initialize'; params = @{ processId = $PID; rootUri = $appRootUri } },
                @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
                # Opening nik.yaml triggers non-blocking background sdk-index.json cache refresh from $BaseUrl/lsp-yaml-index.json
                @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $appManifestUri; languageId = 'yaml'; version = 1; text = $yamlDocText } } },
                @{ __waitPath = (Join-Path $LspYamlHome 'cache\sdk-index.json') },
                # 71: DocumentSymbol outline on nik.yaml
                @{ jsonrpc = '2.0'; id = 71; method = 'textDocument/documentSymbol'; params = @{ textDocument = @{ uri = $appManifestUri } } },
                # 72: Hover on 'cOperators' key (line 7, char 6) -> explains -Sc compiler flag
                @{ jsonrpc = '2.0'; id = 72; method = 'textDocument/hover'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 7; character = 6 } } },
                # 73: Hover on '3.2.2' SDK version value (line 4, char 10) -> reports Installed locally + SDK ID
                @{ jsonrpc = '2.0'; id = 73; method = 'textDocument/hover'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 4; character = 10 } } },
                # 74: Go-to-Definition on 'entry: src/AppMain.pas' (line 2, char 12) -> jumps to AppMain.pas
                @{ jsonrpc = '2.0'; id = 74; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 2; character = 12 } } },
                # 75: Go-to-Definition on 'path: ../lsp-dep-pkg' (line 11, char 15) -> jumps to lsp-dep-pkg/nik.yaml
                @{ jsonrpc = '2.0'; id = 75; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 11; character = 15 } } },
                # Switch to incomplete editing buffer to test context-aware completions
                @{ jsonrpc = '2.0'; method = 'textDocument/didChange'; params = @{ textDocument = @{ uri = $appManifestUri; version = 2 }; contentChanges = @( @{ text = $yamlEditingText } ) } },
                # 76: Completion on 'fpc: ' (line 4, char 9, triggered by ' ') -> installed 3.2.2 + online 3.99.0
                @{ jsonrpc = '2.0'; id = 76; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 4; character = 9 }; context = @{ triggerKind = 2; triggerCharacter = ' ' } } },
                # 77: Completion on 'mode: ' (line 6, char 10, triggered by ' ') -> objfpc, delphi, delphiunicode
                @{ jsonrpc = '2.0'; id = 77; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 6; character = 10 }; context = @{ triggerKind = 2; triggerCharacter = ' ' } } },
                # 78: Key completion inside 'build:' (line 8, char 4) -> suggests heaptrc/smartLink, excludes already-present cOperators
                @{ jsonrpc = '2.0'; id = 78; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 8; character = 4 } } },
                # 79: Path completion on 'entry: ' (line 2, char 9, triggered by ' ') -> suggests src/AppMain.pas
                @{ jsonrpc = '2.0'; id = 79; method = 'textDocument/completion'; params = @{ textDocument = @{ uri = $appManifestUri }; position = @{ line = 2; character = 9 }; context = @{ triggerKind = 2; triggerCharacter = ' ' } } },
                @{ jsonrpc = '2.0'; id = 80; method = 'shutdown' },
                @{ jsonrpc = '2.0'; method = 'exit' }
            )

            Assert-True ($sess7.Exited -and $sess7.ExitCode -eq 0) 'nik.yaml manifest intelligence nik lsp session exits cleanly with code 0'
            Assert-True (Test-Path (Join-Path $LspYamlHome 'cache\sdk-index.json')) 'nik lsp caches remote SDK index asynchronously into ~/.nikrun/cache/sdk-index.json on nik.yaml didOpen'

            $ymlSymResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 71 })[0]
            $ymlRootSym = $ymlSymResp.result[0]
            $ymlChildNames = @($ymlRootSym.children | ForEach-Object { $_.name })
            Assert-True ($ymlRootSym.name -eq 'program' -and ($ymlChildNames -contains 'toolchain') -and ($ymlChildNames -contains 'build') -and ($ymlChildNames -contains 'dependencies')) 'nik lsp returns hierarchical DocumentSymbol outline for nik.yaml'

            $cOpHovResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 72 })[0]
            Assert-True ($null -ne $cOpHovResp -and $cOpHovResp.result.contents.value -match '-Sc' -and $cOpHovResp.result.contents.value -match 'cOperators') 'nik lsp Hover on nik.yaml attribute explains attribute purpose and exact ppc* compiler flag (-Sc)'

            $fpcHovResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 73 })[0]
            Assert-True ($null -ne $fpcHovResp -and $fpcHovResp.result.contents.value -match 'Installed locally' -and $fpcHovResp.result.contents.value -match 'nikrun-fpc-sdk-3\.2\.2-test') 'nik lsp Hover on toolchain.fpc value reports live local SDK installation status'

            $entryDefResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 74 })[0]
            Assert-True ($null -ne $entryDefResp -and @($entryDefResp.result).Count -eq 1 -and $entryDefResp.result[0].uri -match 'AppMain\.pas$') 'nik lsp Go-to-Definition on nik.yaml entry jumps to target .pas file'

            $depDefResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 75 })[0]
            Assert-True ($null -ne $depDefResp -and @($depDefResp.result).Count -eq 1 -and $depDefResp.result[0].uri -match 'lsp-dep-pkg/nik\.yaml$') 'nik lsp Go-to-Definition on nik.yaml local dependency jumps to package nik.yaml'

            $sdkCmpResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 76 })[0]
            $sdk322Item = @($sdkCmpResp.result.items | Where-Object { $_.label -eq '3.2.2' })[0]
            $sdk399Item = @($sdkCmpResp.result.items | Where-Object { $_.label -eq '3.99.0' })[0]
            Assert-True ($null -ne $sdk322Item -and $sdk322Item.detail -match 'installed' -and $null -ne $sdk399Item -and $sdk399Item.detail -match 'available online') 'nik lsp Completion on toolchain.fpc combines locally installed SDKs and online index.json SDK versions with status detail'

            $modeCmpResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 77 })[0]
            $modeLabels = @($modeCmpResp.result.items | ForEach-Object { $_.label })
            Assert-True (($modeLabels -contains 'objfpc') -and ($modeLabels -contains 'delphi') -and ($modeLabels -contains 'delphiunicode')) 'nik lsp Completion on build.mode suggests valid Object Pascal dialect modes'

            $buildKeyCmpResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 78 })[0]
            $buildKeyLabels = @($buildKeyCmpResp.result.items | ForEach-Object { $_.label })
            $heapItem = @($buildKeyCmpResp.result.items | Where-Object { $_.label -eq 'heaptrc' })[0]
            Assert-True (($buildKeyLabels -contains 'heaptrc') -and ($buildKeyLabels -contains 'smartLink') -and ($buildKeyLabels -notcontains 'cOperators') -and $heapItem.textEdit.newText -eq 'heaptrc: ') 'nik lsp Key Completion suggests missing build attributes with trailing ": " and omits duplicate sibling keys'

            $entryCmpResp = @($sess7.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 79 })[0]
            $entryCmpLabels = @($entryCmpResp.result.items | ForEach-Object { $_.label })
            Assert-True ($entryCmpLabels -contains 'src/AppMain.pas') 'nik lsp Completion on entry suggests discovered relative .pas entry files'
        } finally {
            $env:NIKRUN_SDK_INDEX_URL = $prevYamlIdxEnv
        }
    }

    # -------------------------------------------------------------------------
    # Decentralized URL & Path Package Management (nik pkg, nik.lock, MVS, Archives & LSP)
    # -------------------------------------------------------------------------
    Write-Host "`n==> Testing decentralized URL & path package manager (nik pkg, nik.lock, MVS, archives & overrides)..." -ForegroundColor Cyan

    $PkgTestHome = Join-Path $WorkDir 'pkg-nik-home'
    New-Item -ItemType Directory -Force -Path $PkgTestHome | Out-Null

    # 1. Pure-Pascal Git Smart HTTP pkt-line parser test via local HTTP server (zero git invocation)
    function Format-GitPktLine([string]$Payload) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($Payload)
        $total = $bytes.Length + 4
        $hex = $total.ToString('x4')
        return ($hex + $Payload)
    }

    $SmartGitDir = Join-Path $ServerDir 'smart-demo.git\info'
    New-Item -ItemType Directory -Force -Path $SmartGitDir | Out-Null
    $shaHead = '1111111111111111111111111111111111111111'
    $shaTagObj = '2222222222222222222222222222222222222222'
    $shaV100 = '3333333333333333333333333333333333333333'
    $shaV120 = '4444444444444444444444444444444444444444'
    $pktBody = (Format-GitPktLine "# service=git-upload-pack`n") +
               '0000' +
               (Format-GitPktLine "$shaHead HEAD`0multi_ack symref=HEAD:refs/heads/main agent=git/2.45`n") +
               (Format-GitPktLine "$shaHead refs/heads/main`n") +
               (Format-GitPktLine "$shaTagObj refs/tags/v1.0.0`n") +
               (Format-GitPktLine "$shaV100 refs/tags/v1.0.0^{}`n") +
               (Format-GitPktLine "$shaV120 refs/tags/v1.2.0`n") +
               '0000'
    [System.IO.File]::WriteAllBytes((Join-Path $SmartGitDir 'refs'), [System.Text.Encoding]::ASCII.GetBytes($pktBody))

    $smartInfoJson = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'info', "http://127.0.0.1:$Port/smart-demo", '--json')).Output | ConvertFrom-Json
    Assert-True ($smartInfoJson.success -eq $true -and $smartInfoJson.defaultBranch -eq 'main' -and $smartInfoJson.headCommit -eq $shaHead) 'nik pkg info parses Git Smart HTTP pkt-line symref and HEAD without git CLI'
    Assert-True ($smartInfoJson.latestVersion -eq '1.2.0' -and @($smartInfoJson.tags).Count -eq 2) 'nik pkg info extracts sorted SemVer tags from Smart HTTP'
    $v100Entry = @($smartInfoJson.tags | Where-Object { $_.version -eq '1.0.0' })[0]
    Assert-True ($v100Entry.rev -eq $shaV100) 'nik pkg info peels annotated tag ^{} to underlying commit SHA'

    # 2. Manifest prefix & validation error checks (ambiguous bare strings, relative file://, moving @main branch)
    $BadDepDir = Join-Path $WorkDir 'bad-dep-manifests'
    New-Item -ItemType Directory -Force -Path $BadDepDir | Out-Null

    @"
package:
  name: bad-ambiguous
  toolchain:
    fpc: 3.2.2
  dependencies:
    ambiguous-pkg: github.com/owner/repo@^1.0.0
"@ | Set-Content -Path (Join-Path $BadDepDir 'ambiguous.yaml') -Encoding UTF8
    $ambigRes = Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', (Join-Path $BadDepDir 'ambiguous.yaml')) -AllowFailure
    Assert-True ($ambigRes.ExitCode -ne 0 -and $ambigRes.Output -match 'Ambiguous dependency') 'Manifest parser rejects unprefixed dependency value without https:// or ./ / ../'

    @"
package:
  name: bad-branch
  toolchain:
    fpc: 3.2.2
  dependencies:
    moving-branch: https://github.com/owner/repo@main
"@ | Set-Content -Path (Join-Path $BadDepDir 'branch.yaml') -Encoding UTF8
    $branchRes = Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', (Join-Path $BadDepDir 'branch.yaml')) -AllowFailure
    Assert-True ($branchRes.ExitCode -ne 0 -and $branchRes.Output -match 'Moving branch names are disallowed') 'Manifest parser rejects moving branch name (@main) in nik.yaml'

    @"
package:
  name: bad-relfile
  toolchain:
    fpc: 3.2.2
  dependencies:
    rel-file: file://../some-lib
"@ | Set-Content -Path (Join-Path $BadDepDir 'relfile.yaml') -Encoding UTF8
    $relFileRes = Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', (Join-Path $BadDepDir 'relfile.yaml')) -AllowFailure
    Assert-True ($relFileRes.ExitCode -ne 0 -and $relFileRes.Output -match 'Relative file:// URLs') 'Manifest parser rejects malformed relative file://../ URLs'

    # 3. Full Git + Local/Remote Archive + MVS + Lockfile + Build + LSP E2E Suite
    $GitExeCheck = Get-Command git -ErrorAction SilentlyContinue
    if ($CandidateLspHome -and $GitExeCheck) {
        # Share installed FPC SDK directory into isolated $PkgTestHome without touching user ~/.nikrun/cache/pkg
        $srcSdks = Join-Path $CandidateLspHome 'sdks'
        $dstSdks = Join-Path $PkgTestHome 'sdks'
        if ($IsWin) {
            New-Item -ItemType Junction -Path $dstSdks -Target $srcSdks | Out-Null
        } else {
            New-Item -ItemType SymbolicLink -Path $dstSdks -Target $srcSdks | Out-Null
        }

        function Invoke-GitRepo([string]$Dir, [string[]]$GitArgs) {
            $prev = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            & git -C $Dir -c user.name="NikTest" -c user.email="test@nikrun.dev" -c commit.gpgsign=false -c tag.gpgSign=false @GitArgs 2>&1 | Out-Null
            $ec = $LASTEXITCODE
            $ErrorActionPreference = $prev
            if ($ec -ne 0) {
                throw "git $($GitArgs -join ' ') failed in $Dir with exit code $ec"
            }
        }

        function ConvertTo-RepoFileUrl([string]$Dir) {
            $norm = ([System.IO.Path]::GetFullPath($Dir)).Replace('\', '/')
            if ($norm -match '^([A-Za-z]):(.*)$') {
                return "file:///$($Matches[1].ToLowerInvariant()):$($Matches[2])"
            }
            return "file://$norm"
        }

        $ReposRoot = Join-Path $WorkDir 'git-fixtures'
        New-Item -ItemType Directory -Force -Path $ReposRoot | Out-Null

        # Fixture Repo A: shared-core with SemVer tags v1.1.0, v1.2.0, v1.2.1, v2.0.0 (tests MVS + nik pkg update + conflict)
        $SharedRepo = Join-Path $ReposRoot 'shared-core'
        New-Item -ItemType Directory -Force -Path (Join-Path $SharedRepo 'src') | Out-Null
        Invoke-GitRepo $SharedRepo @('init', '-b', 'main')

        foreach ($ver in @('1.1.0', '1.2.0', '1.2.1', '2.0.0')) {
            @"
package:
  name: shared-core
  version: $ver
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $SharedRepo 'nik.yaml') -Encoding UTF8

            @"
unit SharedCoreUnit;
{`$mode objfpc}{`$H+}
interface
/// Returns active shared-core version tag.
function GetSharedVer: string;
implementation
function GetSharedVer: string;
begin
  Result := '$ver';
end;
end.
"@ | Set-Content -Path (Join-Path $SharedRepo 'src\SharedCoreUnit.pas') -Encoding UTF8

            Invoke-GitRepo $SharedRepo @('add', '.')
            Invoke-GitRepo $SharedRepo @('commit', '-m', "Release $ver")
            if ($ver -eq '1.2.0') {
                # Annotated tag test
                Invoke-GitRepo $SharedRepo @('tag', '-a', "v$ver", '-m', "Annotated v$ver")
            } else {
                Invoke-GitRepo $SharedRepo @('tag', "v$ver")
            }
        }
        $SharedUrl = ConvertTo-RepoFileUrl $SharedRepo

        # Fixture Repo B: mid-kit v1.0.0 (transitively requires shared-core@^1.2.0 + monorepo subpath 'sub-pkg')
        $MonoRepo = Join-Path $ReposRoot 'mono-suite'
        New-Item -ItemType Directory -Force -Path (Join-Path $MonoRepo 'packages\sub-pkg\src') | Out-Null
        Invoke-GitRepo $MonoRepo @('init', '-b', 'main')
        @"
package:
  name: sub-pkg
  version: 0.3.0
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $MonoRepo 'packages\sub-pkg\nik.yaml') -Encoding UTF8
        @"
unit MonoSubUnit;
{`$mode objfpc}{`$H+}
interface
function GetMonoTag: string;
implementation
function GetMonoTag: string;
begin
  Result := 'MONO_SUB';
end;
end.
"@ | Set-Content -Path (Join-Path $MonoRepo 'packages\sub-pkg\src\MonoSubUnit.pas') -Encoding UTF8
        Invoke-GitRepo $MonoRepo @('add', '.')
        Invoke-GitRepo $MonoRepo @('commit', '-m', 'Initial monorepo')
        Invoke-GitRepo $MonoRepo @('tag', 'v0.3.0')
        $MonoUrl = ConvertTo-RepoFileUrl $MonoRepo

        $MidRepo = Join-Path $ReposRoot 'mid-kit'
        New-Item -ItemType Directory -Force -Path (Join-Path $MidRepo 'src') | Out-Null
        Invoke-GitRepo $MidRepo @('init', '-b', 'main')
        @"
package:
  name: mid-kit
  version: 1.0.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
  dependencies:
    shared-core: $SharedUrl@^1.2.0
    mono-sub:
      url: $MonoUrl
      version: ^0.3.0
      subpath: packages/sub-pkg
"@ | Set-Content -Path (Join-Path $MidRepo 'nik.yaml') -Encoding UTF8
        @"
unit MidKitUnit;
{`$mode objfpc}{`$H+}
interface
uses SharedCoreUnit, MonoSubUnit;
function GetMidSummary: string;
implementation
function GetMidSummary: string;
begin
  Result := 'MID(' + GetSharedVer + ',' + GetMonoTag + ')';
end;
end.
"@ | Set-Content -Path (Join-Path $MidRepo 'src\MidKitUnit.pas') -Encoding UTF8
        Invoke-GitRepo $MidRepo @('add', '.')
        Invoke-GitRepo $MidRepo @('commit', '-m', 'Release 1.0.0')
        Invoke-GitRepo $MidRepo @('tag', 'v1.0.0')
        $MidUrl = ConvertTo-RepoFileUrl $MidRepo

        # Fixture Repo C: tagless legacy Pascal repo without nik.yaml (pinned via short commit SHA + unitPaths: [Source])
        $LegacyRepo = Join-Path $ReposRoot 'legacy-pas'
        New-Item -ItemType Directory -Force -Path (Join-Path $LegacyRepo 'Source') | Out-Null
        Invoke-GitRepo $LegacyRepo @('init', '-b', 'main')
        @"
unit LegacyUnit;
{`$mode objfpc}{`$H+}
interface
function GetLegacyTag: string;
implementation
function GetLegacyTag: string;
begin
  Result := 'LEGACY_PIN';
end;
end.
"@ | Set-Content -Path (Join-Path $LegacyRepo 'Source\LegacyUnit.pas') -Encoding UTF8
        Invoke-GitRepo $LegacyRepo @('add', '.')
        Invoke-GitRepo $LegacyRepo @('commit', '-m', 'Untagged commit')
        $LegacyFullSha = (& git -C $LegacyRepo rev-parse HEAD).Trim().ToLowerInvariant()
        $LegacyShortSha = $LegacyFullSha.Substring(0, 8)
        $LegacyUrl = ConvertTo-RepoFileUrl $LegacyRepo

        # Verify nik pkg info on tagless repo suggests commit pin
        $legInfo = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'info', $LegacyUrl, '--json')).Output | ConvertFrom-Json
        Assert-True ($legInfo.latestVersion -eq $null -and $legInfo.headCommit -eq $LegacyFullSha -and $legInfo.suggestedYaml -match "@$LegacyShortSha$") 'nik pkg info on tagless repo reports HEAD commit and commit-pinned YAML snippet'

        # Fixture D: Local .zip archive (./vendor/local-arch.zip) AND Remote HTTP .tar.gz archive (with outer wrapper folder!)
        $LocalArchStage = Join-Path $WorkDir 'stage-local-arch\local-arch-1.0.0'
        New-Item -ItemType Directory -Force -Path (Join-Path $LocalArchStage 'src') | Out-Null
        @"
package:
  name: local-arch
  version: 1.0.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $LocalArchStage 'nik.yaml') -Encoding UTF8
        @"
unit LocalArchUnit;
{`$mode objfpc}{`$H+}
interface
function GetLocalArchTag: string;
implementation
function GetLocalArchTag: string;
begin
  Result := 'LOCAL_ZIP';
end;
end.
"@ | Set-Content -Path (Join-Path $LocalArchStage 'src\LocalArchUnit.pas') -Encoding UTF8

        $RemoteArchStage = Join-Path $WorkDir 'stage-remote-arch\remote-arch-2.0.0'
        New-Item -ItemType Directory -Force -Path (Join-Path $RemoteArchStage 'src') | Out-Null
        @"
package:
  name: remote-arch
  version: 2.0.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $RemoteArchStage 'nik.yaml') -Encoding UTF8
        @"
unit RemoteArchUnit;
{`$mode objfpc}{`$H+}
interface
function GetRemoteArchTag: string;
implementation
function GetRemoteArchTag: string;
begin
  Result := 'HTTP_TARGZ';
end;
end.
"@ | Set-Content -Path (Join-Path $RemoteArchStage 'src\RemoteArchUnit.pas') -Encoding UTF8

        $RemoteTarGzPath = Join-Path $ServerDir 'remote-arch-2.0.0.tar.gz'
        $TarCmd = if ($IsWin -and (Test-Path 'C:\Windows\System32\tar.exe')) { 'C:\Windows\System32\tar.exe' } else { 'tar' }
        & $TarCmd -czf $RemoteTarGzPath -C (Join-Path $WorkDir 'stage-remote-arch') 'remote-arch-2.0.0'
        Assert-True (Test-Path $RemoteTarGzPath) 'Created .tar.gz package fixture with single wrapper root directory'

        # Local workspace directory sibling (compact ../local-sibling without fake URL!)
        $SiblingDir = Join-Path $WorkDir 'pkg-e2e\local-sibling'
        New-Item -ItemType Directory -Force -Path (Join-Path $SiblingDir 'src') | Out-Null
        @"
package:
  name: local-sibling
  version: 0.1.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $SiblingDir 'nik.yaml') -Encoding UTF8
        @"
unit LocalSiblingUnit;
{`$mode objfpc}{`$H+}
interface
function GetSiblingTag: string;
implementation
function GetSiblingTag: string;
begin
  Result := 'SIBLING_DIR';
end;
end.
"@ | Set-Content -Path (Join-Path $SiblingDir 'src\LocalSiblingUnit.pas') -Encoding UTF8

        # Create main E2E consumer app combining ALL dependency types + Diamond MVS (^1.1.0 + transitive ^1.2.0)
        $ConsumerDir = Join-Path $WorkDir 'pkg-e2e\consumer-app'
        New-Item -ItemType Directory -Force -Path (Join-Path $ConsumerDir 'src'), (Join-Path $ConsumerDir 'vendor') | Out-Null
        $LocalZipPath = Join-Path $ConsumerDir 'vendor\local-arch-1.0.0.zip'
        if ($IsWin -and (Test-Path 'C:\Windows\System32\tar.exe')) {
            & 'C:\Windows\System32\tar.exe' -a -cf $LocalZipPath -C (Join-Path $WorkDir 'stage-local-arch') 'local-arch-1.0.0'
        } else {
            Compress-Archive -Path $LocalArchStage -DestinationPath $LocalZipPath -Force
        }

        $ConsumerYamlPath = Join-Path $ConsumerDir 'nik.yaml'
        $BaseConsumerYaml = @"
program:
  name: consumer-app
  version: 0.1.0
  entry: src/main.pas
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
  dependencies:
    local-sibling: ../local-sibling
    local-arch: ./vendor/local-arch-1.0.0.zip
    remote-arch: http://127.0.0.1:$Port/remote-arch-2.0.0.tar.gz
    shared-core: $SharedUrl@^1.1.0
    mid-kit: $MidUrl@^1.0.0
    legacy-pas:
      url: $LegacyUrl
      rev: $LegacyShortSha
      unitPaths: [Source]
"@
        $BaseConsumerYaml | Set-Content -Path $ConsumerYamlPath -Encoding UTF8

        $ConsumerMainPas = Join-Path $ConsumerDir 'src\main.pas'
        @"
program ConsumerMain;
{`$mode objfpc}{`$H+}
uses
  LocalSiblingUnit, LocalArchUnit, RemoteArchUnit, SharedCoreUnit, MidKitUnit, LegacyUnit;
begin
  WriteLn(GetSiblingTag + '|' + GetLocalArchTag + '|' + GetRemoteArchTag + '|' + GetSharedVer + '|' + GetMidSummary + '|' + GetLegacyTag);
end.
"@ | Set-Content -Path $ConsumerMainPas -Encoding UTF8

        # 3a. --locked before nik.lock exists must fail cleanly
        $failLocked = Invoke-Nik -NikHome $PkgTestHome -Arguments @('build', '-m', $ConsumerDir, '--locked') -AllowFailure
        Assert-True ($failLocked.ExitCode -ne 0 -and $failLocked.Output -match 'nik\.lock') 'nik build --locked fails cleanly before nik.lock is generated'

        # 3b. Automatic hydration on 'nik build': MVS must pick shared-core 1.2.0 (minimum satisfying ^1.1.0 AND mid-kit ^1.2.0, NOT 1.2.1!)
        $e2eBuild = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('build', '-m', $ConsumerDir, '--json')).Output | ConvertFrom-Json
        Assert-True ($e2eBuild.success -eq $true -and (Test-Path (Join-Path $ConsumerDir 'nik.lock'))) 'nik build automatically fetches all Git/archive dependencies and writes nik.lock'
        $e2eRunOut = (& $e2eBuild.output.binaryPath).Trim()
        Assert-True ($e2eRunOut -eq 'SIBLING_DIR|LOCAL_ZIP|HTTP_TARGZ|1.2.0|MID(1.2.0,MONO_SUB)|LEGACY_PIN') "Compiled binary links local dir, local .zip, HTTP .tar.gz, MVS diamond Git (1.2.0), monorepo subpath & short-SHA legacy repo ($e2eRunOut)"

        # Verify immutable global package cache contains zero compiled .ppu/.o artifacts
        $pkgCacheFiles = @(Get-ChildItem -Path (Join-Path $PkgTestHome 'cache\pkg') -Recurse -File | Where-Object { $_.Extension -in @('.ppu', '.o') })
        Assert-True ($pkgCacheFiles.Count -eq 0) 'Global ~/.nikrun/cache/pkg stays strictly immutable with zero .ppu/.o artifacts'

        # 3c. nik build --locked & --offline succeed once cached and locked
        $lockedBuild = Invoke-Nik -NikHome $PkgTestHome -Arguments @('build', '-m', $ConsumerDir, '--locked', '--offline')
        Assert-True ($lockedBuild.ExitCode -eq 0) 'nik build --locked --offline succeeds with zero network/git calls'

        # 3d. nik pkg list --json inspects direct and transitive graph
        $pkgList = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'list', '-m', $ConsumerDir, '--offline', '--json')).Output | ConvertFrom-Json
        $sharedResolved = @($pkgList.packages | Where-Object { $_.name -eq 'shared-core' })[0]
        $monoResolved = @($pkgList.packages | Where-Object { $_.subpath -eq 'packages/sub-pkg' })[0]
        Assert-True ($sharedResolved.version -eq '1.2.0' -and $sharedResolved.integrity -match '^sha256-[0-9a-f]{64}$') 'nik pkg list --json reports MVS version 1.2.0 and sha256 tree integrity'
        Assert-True ($null -ne $monoResolved -and $monoResolved.direct -eq $false) 'nik pkg list --json includes transitive monorepo subpath dependency'

        # 3e. nik lsp resolves Go-to-Definition and Hover into cached Git package in ~/.nikrun/cache/pkg/
        $consumerRootUri = ConvertTo-FileUri $ConsumerDir
        $consumerMainUri = ConvertTo-FileUri $ConsumerMainPas
        $consumerMainText = [System.IO.File]::ReadAllText($ConsumerMainPas)
        $consumerLines = $consumerMainText -split "`r?`n"
        $callLineIdx = 0
        for ($li = 0; $li -lt $consumerLines.Count; $li++) {
            if ($consumerLines[$li] -match 'GetSharedVer') { $callLineIdx = $li; break }
        }
        $callColIdx = $consumerLines[$callLineIdx].IndexOf('GetSharedVer') + 3

        $lspPkgSess = Invoke-LspSession -NikHomeDir $PkgTestHome -ProjectPath $ConsumerDir -LogPath '' -Messages @(
            @{ jsonrpc = '2.0'; id = 60; method = 'initialize'; params = @{ processId = $PID; rootUri = $consumerRootUri } },
            @{ jsonrpc = '2.0'; method = 'initialized'; params = @{} },
            @{ jsonrpc = '2.0'; method = 'textDocument/didOpen'; params = @{ textDocument = @{ uri = $consumerMainUri; languageId = 'objectpascal'; version = 1; text = $consumerMainText } } },
            @{ __waitDiagCount = @{ uri = $consumerMainUri; count = 1 } },
            @{ jsonrpc = '2.0'; id = 61; method = 'textDocument/definition'; params = @{ textDocument = @{ uri = $consumerMainUri }; position = @{ line = $callLineIdx; character = $callColIdx } } },
            @{ jsonrpc = '2.0'; id = 62; method = 'shutdown' },
            @{ jsonrpc = '2.0'; method = 'exit' }
        )
        $lspPkgDef = @($lspPkgSess.Frames | Where-Object { $_.PSObject.Properties['id'] -and $_.id -eq 61 })[0]
        Assert-True ($null -ne $lspPkgDef -and @($lspPkgDef.result).Count -ge 1 -and $lspPkgDef.result[0].uri -match 'SharedCoreUnit\.pas$') 'nik lsp resolves Go-to-Definition directly into cached package inside ~/.nikrun/cache/pkg'
        $lspPkgDiags = @($lspPkgSess.Frames | Where-Object { $_.PSObject.Properties['method'] -and $_.method -eq 'textDocument/publishDiagnostics' -and $_.params.uri -eq $consumerMainUri })
        Assert-True ($lspPkgDiags.Count -ge 1 -and @($lspPkgDiags[$lspPkgDiags.Count - 1].params.diagnostics).Count -eq 0) 'nik lsp live ppc* check passes with 0 errors across all cached Git and archive dependencies'

        # 3f. nik pkg update upgrades shared-core in nik.lock from 1.2.0 -> 1.2.1 WITHOUT mutating nik.yaml!
        $yamlBeforeUpdate = [System.IO.File]::ReadAllText($ConsumerYamlPath)
        $updRes = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'update', 'shared-core', '-m', $ConsumerDir, '--json')).Output | ConvertFrom-Json
        $yamlAfterUpdate = [System.IO.File]::ReadAllText($ConsumerYamlPath)
        Assert-True ($updRes.success -eq $true -and $updRes.lockUpdated -eq $true) 'nik pkg update shared-core updates nik.lock to newest compatible SemVer tag'
        Assert-True ($yamlBeforeUpdate -eq $yamlAfterUpdate) 'nik pkg update never mutates human-authored nik.yaml'
        $rebuiltAfterUpd = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('build', '-m', $ConsumerDir, '--json')).Output | ConvertFrom-Json
        $updRunOut = (& $rebuiltAfterUpd.output.binaryPath).Trim()
        Assert-True ($updRunOut -match '\|1\.2\.1\|MID\(1\.2\.1,MONO_SUB\)\|') "Rebuilt binary after nik pkg update links upgraded shared-core 1.2.1 ($updRunOut)"

        # 3g. Local URL override ({ url: ..., path: ... }) replaces shared-core across both root AND transitive mid-kit!
        $OverrideSharedDir = Join-Path $WorkDir 'pkg-e2e\shared-override'
        New-Item -ItemType Directory -Force -Path (Join-Path $OverrideSharedDir 'src') | Out-Null
        @"
package:
  name: shared-core
  version: 1.9.9-local
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
"@ | Set-Content -Path (Join-Path $OverrideSharedDir 'nik.yaml') -Encoding UTF8
        @"
unit SharedCoreUnit;
{`$mode objfpc}{`$H+}
interface
function GetSharedVer: string;
implementation
function GetSharedVer: string;
begin
  Result := 'LOCAL_OVERRIDE';
end;
end.
"@ | Set-Content -Path (Join-Path $OverrideSharedDir 'src\SharedCoreUnit.pas') -Encoding UTF8

        ($BaseConsumerYaml -replace "shared-core: $([regex]::Escape($SharedUrl))@\^1\.1\.0", "shared-core:`n      url: $SharedUrl`n      path: ../shared-override") | Set-Content -Path $ConsumerYamlPath -Encoding UTF8
        $ovrBuild = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('build', '-m', $ConsumerDir, '--clean', '--json')).Output | ConvertFrom-Json
        $ovrOut = (& $ovrBuild.output.binaryPath).Trim()
        Assert-True ($ovrOut -match '\|LOCAL_OVERRIDE\|MID\(LOCAL_OVERRIDE,MONO_SUB\)\|') "Local url+path override substitutes remote dependency across transitive packages ($ovrOut)"

        # 3h. Removing a dependency from nik.yaml prunes it cleanly from nik.lock; nik pkg fetch works on package: manifests
        $PurePkgDir = Join-Path $WorkDir 'pkg-e2e\pure-pkg'
        New-Item -ItemType Directory -Force -Path (Join-Path $PurePkgDir 'src') | Out-Null
        @"
package:
  name: pure-pkg
  version: 0.1.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
  dependencies:
    shared-core: $SharedUrl@^1.1.0
    mono-sub:
      url: $MonoUrl
      version: ^0.3.0
      subpath: packages/sub-pkg
"@ | Set-Content -Path (Join-Path $PurePkgDir 'nik.yaml') -Encoding UTF8
        $fetchPkgRes = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', $PurePkgDir, '--json')).Output | ConvertFrom-Json
        Assert-True ($fetchPkgRes.success -eq $true -and @($fetchPkgRes.packages).Count -eq 2 -and (Test-Path (Join-Path $PurePkgDir 'nik.lock'))) 'nik pkg fetch resolves and locks dependencies for a package: manifest without entry'

        # Remove mono-sub from pure-pkg/nik.yaml -> nik pkg fetch prunes mono-sub from nik.lock
        @"
package:
  name: pure-pkg
  version: 0.1.0
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
  dependencies:
    shared-core: $SharedUrl@^1.1.0
"@ | Set-Content -Path (Join-Path $PurePkgDir 'nik.yaml') -Encoding UTF8
        $pruneRes = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', $PurePkgDir, '--json')).Output | ConvertFrom-Json
        $lockAfterPrune = [System.IO.File]::ReadAllText((Join-Path $PurePkgDir 'nik.lock'))
        Assert-True ($pruneRes.lockUpdated -eq $true -and $lockAfterPrune -notmatch 'mono-suite') 'Deleting a dependency from nik.yaml prunes its entry from nik.lock'

        # 3h2. A target-specific build must keep the lock entries (also the transitive ones) of the other targets,
        #      otherwise CI on another OS fails with --locked after a developer built locally.
        $OtherOsTarget = if ($HostOs -eq 'win64') { 'unix' } else { 'windows' }
        $KeepLockDir = Join-Path $WorkDir 'pkg-e2e\keep-other-target-lock'
        New-Item -ItemType Directory -Force -Path (Join-Path $KeepLockDir 'src') | Out-Null
        @"
program:
  name: keep-lock
  version: 0.1.0
  entry: src/main.pas
  toolchain:
    fpc: $CandidateLspFpcVersion
  build:
    unitPaths: [src]
  dependencies:
    shared-core: $SharedUrl@^1.1.0
  targets:
    ${OtherOsTarget}:
      dependencies:
        mid-kit: $MidUrl@^1.0.0
"@ | Set-Content -Path (Join-Path $KeepLockDir 'nik.yaml') -Encoding UTF8
        @"
program KeepLock;
{`$mode objfpc}{`$H+}
uses SharedCoreUnit;
begin
  WriteLn(GetSharedVer);
end.
"@ | Set-Content -Path (Join-Path $KeepLockDir 'src\main.pas') -Encoding UTF8
        $keepFetch = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', $KeepLockDir, '--json')).Output | ConvertFrom-Json
        $keepLockFull = [System.IO.File]::ReadAllText((Join-Path $KeepLockDir 'nik.lock'))
        Assert-True ($keepFetch.success -eq $true -and $keepLockFull -match 'mid-kit' -and $keepLockFull -match 'mono-suite') 'nik pkg fetch locks the dependencies and the transitive packages of every target'
        $keepBuild = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('build', '-m', $KeepLockDir, '--json')).Output | ConvertFrom-Json
        $keepLockAfterBuild = [System.IO.File]::ReadAllText((Join-Path $KeepLockDir 'nik.lock'))
        Assert-True ($keepBuild.success -eq $true -and $keepLockAfterBuild -match 'mid-kit' -and $keepLockAfterBuild -match 'mono-suite') 'nik build keeps the lock entries of other targets, including their transitive packages'

        # 3h3. A commit pin must stay tied to the integrity recorded in nik.lock: a changed tree is an error, not a silent lock rewrite.
        $PinLockDir = Join-Path $WorkDir 'pkg-e2e\pin-lock'
        New-Item -ItemType Directory -Force -Path (Join-Path $PinLockDir 'src') | Out-Null
        @"
package:
  name: pin-lock
  toolchain:
    fpc: $CandidateLspFpcVersion
  dependencies:
    legacy-pas:
      url: $LegacyUrl
      rev: $LegacyShortSha
"@ | Set-Content -Path (Join-Path $PinLockDir 'nik.yaml') -Encoding UTF8
        $pinFetch = (Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', $PinLockDir, '--json')).Output | ConvertFrom-Json
        Assert-True ($pinFetch.success -eq $true) 'nik pkg fetch locks a commit-pinned dependency'
        $pinLockPath = Join-Path $PinLockDir 'nik.lock'
        $pinLockText = [System.IO.File]::ReadAllText($pinLockPath)
        $pinIntegrity = [regex]::Match($pinLockText, 'integrity:\s*"?sha256-([0-9a-f]{64})').Groups[1].Value
        Assert-True ($pinIntegrity.Length -eq 64) 'nik.lock records the tree integrity of the pinned dependency'
        $tamperedIntegrity = ('0' * 64)
        $tamperedLock = $pinLockText.Replace($pinIntegrity, $tamperedIntegrity)
        [System.IO.File]::WriteAllText($pinLockPath, $tamperedLock)
        $pinUpdate = Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'update', 'legacy-pas', '-m', $PinLockDir, '--json') -AllowFailure
        $lockAfterPinUpdate = [System.IO.File]::ReadAllText($pinLockPath)
        Assert-True ($pinUpdate.ExitCode -ne 0 -and $pinUpdate.Output -match 'integrity mismatch') 'nik pkg update refuses a commit-pinned dependency whose tree differs from the integrity in nik.lock'
        Assert-True ($lockAfterPinUpdate -eq $tamperedLock) 'A failed nik pkg update leaves nik.lock untouched'

        # 3i. Incompatible SemVer major conflict (^2.0.0 vs mid-kit ^1.2.0) reports clear dependency chains
        @"
package:
  name: conflict-pkg
  toolchain:
    fpc: $CandidateLspFpcVersion
  dependencies:
    shared-core: $SharedUrl@^2.0.0
    mid-kit: $MidUrl@^1.0.0
"@ | Set-Content -Path (Join-Path $PurePkgDir 'nik.yaml') -Encoding UTF8
        $conflictRes = Invoke-Nik -NikHome $PkgTestHome -Arguments @('pkg', 'fetch', '-m', $PurePkgDir) -AllowFailure
        Assert-True ($conflictRes.ExitCode -ne 0 -and $conflictRes.Output -match 'No SemVer tag' -and $conflictRes.Output -match 'mid-kit -> shared-core') 'Resolver reports incompatible SemVer conflict with full transitive dependency chain'
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
