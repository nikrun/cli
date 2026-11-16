<#
.SYNOPSIS
    Compiles and runs the standalone nikrun-lsp-protocol unit test suite (with heaptrc leak checking).
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$SdkPath = '',

    [Parameter()]
    [string]$NikrunHome = '',

    [Parameter()]
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PkgRoot  = $PSScriptRoot
$SrcDir   = [System.IO.Path]::Combine($PkgRoot, 'src')
$TestPas  = [System.IO.Path]::Combine($PkgRoot, 'tests', 'lsp_protocol_tests.pas')
$OutDir   = [System.IO.Path]::Combine($PkgRoot, 'bin')
$CacheDir = [System.IO.Path]::Combine($PkgRoot, '.cache', 'tests')

# Verify strict zero-dependency boundary: no nik.* CLI imports allowed in src/
foreach ($pasFile in (Get-ChildItem -Path $SrcDir -Filter '*.pas' -File)) {
    $raw = Get-Content -Path $pasFile.FullName -Raw
    if ($raw -match '(?im)\bnick?\.[a-z0-9_.]+\b' -and $raw -notmatch 'nikrun\.lsp\.') {
        # Detailed check for forbidden 'nik.<unit>' references
    }
    if ([regex]::IsMatch($raw, '(?i)(?<![a-z0-9_])nik\.[a-z0-9_]+')) {
        throw "Forbidden nik.* CLI dependency detected in standalone library unit: $($pasFile.Name)"
    }
}

$IsWinHost = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
    [bool]$IsWindows
} else {
    ($env:OS -match 'Windows')
}

$HomeDir = if ($IsWinHost -and $env:USERPROFILE) { $env:USERPROFILE } elseif ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
$EffectiveNikHome = if ($NikrunHome) {
    [System.IO.Path]::GetFullPath($NikrunHome)
} elseif ($env:NIKRUN_HOME) {
    [System.IO.Path]::GetFullPath($env:NIKRUN_HOME)
} else {
    [System.IO.Path]::Combine($HomeDir, '.nikrun')
}

function Resolve-TestCompiler {
    $candidates = @()
    if ($SdkPath) {
        $candidates += [System.IO.Path]::GetFullPath($SdkPath)
    } else {
        $sdksDir = [System.IO.Path]::Combine($EffectiveNikHome, 'sdks')
        if (Test-Path $sdksDir) {
            foreach ($d in (Get-ChildItem -Path $sdksDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
                $candidates += $d.FullName
            }
        }
    }

    foreach ($cand in $candidates) {
        $manifestFile = [System.IO.Path]::Combine($cand, 'sdk-manifest.json')
        if (Test-Path $manifestFile) {
            $m = Get-Content $manifestFile -Raw | ConvertFrom-Json
            $binDir = [System.IO.Path]::Combine($cand, ($m.paths.binDir -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar))
            $ppcBin = [System.IO.Path]::Combine($cand, ($m.paths.ppcBinary -replace '[/\\]', [System.IO.Path]::DirectorySeparatorChar))
            $fpcCfg = [System.IO.Path]::Combine($binDir, 'fpc.cfg')
            if ((Test-Path $ppcBin) -and (Test-Path $fpcCfg)) {
                return [PSCustomObject]@{
                    Compiler = $ppcBin
                    BinDir   = $binDir
                    BaseArgs = @('-n', "@$fpcCfg")
                    Label    = [string]$m.sdkId
                }
            }
        }
    }

    $sysFpc = Get-Command fpc -ErrorAction SilentlyContinue
    if ($sysFpc) {
        return [PSCustomObject]@{
            Compiler = $sysFpc.Source
            BinDir   = ''
            BaseArgs = @()
            Label    = 'system fpc'
        }
    }

    throw "No Nikrun FPC SDK or system 'fpc' found to run nikrun-lsp-protocol tests."
}

$tc = Resolve-TestCompiler
if ($Clean -and (Test-Path $CacheDir)) {
    Remove-Item -Recurse -Force $CacheDir
}
New-Item -ItemType Directory -Force -Path $OutDir, $CacheDir | Out-Null

$ExeExt  = if ($IsWinHost) { '.exe' } else { '' }
$ExeName = "lsp_protocol_tests$ExeExt"
$ExePath = [System.IO.Path]::Combine($OutDir, $ExeName)

Write-Host "`n==> Building nikrun-lsp-protocol tests ($($tc.Label))..." -ForegroundColor Cyan

$compileArgs = @()
$compileArgs += $tc.BaseArgs
$compileArgs += @(
    '-Mobjfpc',
    '-Sh',
    '-Sa',
    '-Cr',
    '-Co',
    '-Ci',
    '-gh',
    '-gl',
    "-Fu$SrcDir",
    "-FE$OutDir",
    "-FU$CacheDir",
    "-o$ExeName",
    $TestPas
)

$prevPath = $env:PATH
try {
    if ($tc.BinDir) {
        $env:PATH = "$($tc.BinDir)$([System.IO.Path]::PathSeparator)$prevPath"
    }
    & $tc.Compiler @compileArgs | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "Compilation of lsp_protocol_tests failed with exit code $LASTEXITCODE"
    }
} finally {
    $env:PATH = $prevPath
}

Write-Host "==> Running nikrun-lsp-protocol test suite (with heaptrc leak check)..." -ForegroundColor Cyan
$prevErr = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$testOutput = & $ExePath 2>&1
$testExit   = $LASTEXITCODE
$ErrorActionPreference = $prevErr

$rendered = ($testOutput | ForEach-Object { "$_" }) -join "`n"
Write-Host $rendered

if ($testExit -ne 0) {
    throw "nikrun-lsp-protocol tests failed with exit code $testExit"
}
if ($rendered -match '([1-9]\d*)\s+unfreed memory blocks') {
    throw "Memory leak detected by heaptrc!"
}

Write-Host " [OK] All nikrun-lsp-protocol tests passed with zero memory leaks!" -ForegroundColor Green
