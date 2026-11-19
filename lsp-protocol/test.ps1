<#
.SYNOPSIS
    Runs the standalone nikrun-lsp-protocol fpcunit suite (with heaptrc leak checking) via `nik test`.

.DESCRIPTION
    The tests are the *.test.pas fpcunit units next to the library units in src/ (discovered
    automatically by `nik test`). This script additionally enforces the strict zero-dependency
    boundary: no `nik.*` CLI unit may be referenced from the library sources.

.EXAMPLE
    .\test.ps1
    .\test.ps1 -NikBinaryPath ..\bin\nik.exe -Clean
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$NikBinaryPath = '',

    [Parameter()]
    [string]$NikrunHome = '',

    [Parameter()]
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$PkgRoot = $PSScriptRoot
$SrcDir  = [System.IO.Path]::Combine($PkgRoot, 'src')

# Verify strict zero-dependency boundary: no nik.* CLI imports allowed in the library sources
foreach ($pasFile in (Get-ChildItem -Path $SrcDir -Filter '*.pas' -File | Where-Object { $_.Name -notmatch '\.test\.pas$' })) {
    $raw = Get-Content -Path $pasFile.FullName -Raw
    if ([regex]::IsMatch($raw, '(?i)(?<![a-z0-9_])nik\.[a-z0-9_]+')) {
        throw "Forbidden nik.* CLI dependency detected in standalone library unit: $($pasFile.Name)"
    }
}

$IsWinHost = if (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue) {
    [bool]$IsWindows
} else {
    ($env:OS -match 'Windows')
}
$ExeExt = if ($IsWinHost) { '.exe' } else { '' }

$NikExe = if (-not [string]::IsNullOrWhiteSpace($NikBinaryPath)) {
    [System.IO.Path]::GetFullPath($NikBinaryPath)
} else {
    [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PkgRoot, '..', 'bin', "nik$ExeExt"))
}
if (-not (Test-Path $NikExe)) {
    $onPath = Get-Command nik -ErrorAction SilentlyContinue
    if ($null -eq $onPath) {
        throw "nik CLI binary not found at $NikExe (build it first or pass -NikBinaryPath)."
    }
    $NikExe = $onPath.Source
}

$nikArgs = @('--no-color')
if (-not [string]::IsNullOrWhiteSpace($NikrunHome)) {
    $nikArgs += @('--nikrun-home', [System.IO.Path]::GetFullPath($NikrunHome))
}
$nikArgs += @('test', '-m', $PkgRoot)
if ($Clean) {
    $nikArgs += '--clean'
}

Write-Host "`n==> Running nikrun-lsp-protocol fpcunit suite via nik test (with heaptrc leak check)..." -ForegroundColor Cyan
$prevErr = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $NikExe @nikArgs 2>&1 | ForEach-Object { Write-Host "$_" }
$testExit = $LASTEXITCODE
$ErrorActionPreference = $prevErr

if ($testExit -ne 0) {
    throw "nikrun-lsp-protocol tests failed with exit code $testExit"
}

Write-Host " [OK] All nikrun-lsp-protocol tests passed with zero memory leaks!" -ForegroundColor Green
