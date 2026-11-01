#Requires -Version 5.1
<#
.SYNOPSIS
    Builds, validates, and packages dual-architecture releases of AvsAffinity.

.DESCRIPTION
    Compiles Release|x64 and Release|ARM64 targets using MSBuild, validates PE headers
    and version resource strings, executes the automated regression test suite, packages
    zip archives for distribution, and generates per-archive SHA-256 checksum files.

.PARAMETER Version
    Semantic version tag (e.g. "1.0.0" or "v1.0.0"). Defaults to "1.0.0".

.PARAMETER SkipBuild
    Skip MSBuild compilation step and use existing build artifacts.

.PARAMETER SkipTests
    Skip executing tests/Test-AvsAffinity.ps1.

.PARAMETER OutputDir
    Output directory for release archives and checksums. Defaults to <RepoRoot>\dist.
#>
[CmdletBinding()]
param(
    [string]$Version = "1.0.0",
    [switch]$SkipBuild,
    [switch]$SkipTests,
    [string]$OutputDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$cleanVersion = $Version.TrimStart('v')
$repoRoot = (Resolve-Path "$PSScriptRoot\..").Path

if (-not $OutputDir) {
    $OutputDir = Join-Path $repoRoot "dist"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " AvsAffinity Release Packaging Tool - v$cleanVersion" -ForegroundColor Cyan
Write-Host " Repository Root: $repoRoot" -ForegroundColor Gray
Write-Host " Output Directory: $OutputDir" -ForegroundColor Gray
Write-Host "==========================================================`n" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. MSBuild Discovery and Clean Rebuild
# -----------------------------------------------------------------------------
if (-not $SkipBuild) {
    Write-Host "[1/5] Discovering MSBuild..." -ForegroundColor Yellow
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw "vswhere.exe not found at '$vswhere'."
    }

    $msBuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find MSBuild\**\Bin\MSBuild.exe | Select-Object -First 1
    if (-not $msBuild -or -not (Test-Path $msBuild)) {
        throw "MSBuild.exe was not found by vswhere."
    }
    Write-Host "  Using: $msBuild" -ForegroundColor Green

    $vcxproj = Join-Path $repoRoot "AvsAffinity.vcxproj"
    if (-not (Test-Path $vcxproj)) {
        throw "AvsAffinity.vcxproj not found at '$vcxproj'."
    }

    foreach ($platform in @("x64", "ARM64")) {
        Write-Host "`n  Building Release|$platform..." -ForegroundColor Cyan
        & $msBuild $vcxproj /t:Rebuild /p:Configuration=Release "/p:Platform=$platform" /v:m /nologo
        if ($LASTEXITCODE -ne 0) {
            throw "MSBuild failed for Release|$platform with exit code $LASTEXITCODE."
        }
        Write-Host "  [OK] Release|$platform compiled successfully." -ForegroundColor Green
    }
} else {
    Write-Host "[1/5] Skipping build step (-SkipBuild specified)." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 2. Artifact Discovery & PE Header Verification
# -----------------------------------------------------------------------------
Write-Host "`n[2/5] Inspecting Binary Headers and Resources..." -ForegroundColor Yellow

$x64Dll   = Join-Path $repoRoot "x64\Release\AvsAffinity.dll"
$x64Pdb   = Join-Path $repoRoot "x64\Release\AvsAffinity.pdb"
$arm64Dll = Join-Path $repoRoot "ARM64\Release\AvsAffinity.dll"
$arm64Pdb = Join-Path $repoRoot "ARM64\Release\AvsAffinity.pdb"

function Test-PeMachine {
    param([string]$FilePath, [uint16]$ExpectedMachine, [string]$ArchLabel)
    if (-not (Test-Path $FilePath)) {
        throw "Artifact not found: $FilePath"
    }

    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $dosMagic = $reader.ReadUInt16()
        if ($dosMagic -ne 0x5A4D) {
            throw "Invalid DOS header signature in $FilePath"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        $peMagic = $reader.ReadUInt32()
        if ($peMagic -ne 0x00004550) {
            throw "Invalid PE signature in $FilePath"
        }
        $machine = $reader.ReadUInt16()
        if ($machine -ne $ExpectedMachine) {
            throw "Architecture mismatch for $ArchLabel in $FilePath`: expected 0x$($ExpectedMachine.ToString('X4')), got 0x$($machine.ToString('X4'))"
        }
        Write-Host "  [OK] $ArchLabel Machine Header: 0x$($machine.ToString('X4')) ($FilePath)" -ForegroundColor Green
    } finally {
        $stream.Dispose()
    }
}

Test-PeMachine -FilePath $x64Dll -ExpectedMachine 0x8664 -ArchLabel "x64"
Test-PeMachine -FilePath $arm64Dll -ExpectedMachine 0xAA64 -ArchLabel "ARM64"

# Validate Version Resources
$x64Info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($x64Dll)
$arm64Info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($arm64Dll)

Write-Host "  [OK] x64 FileVersion: $($x64Info.FileVersion), ProductVersion: $($x64Info.ProductVersion)" -ForegroundColor Green
Write-Host "  [OK] ARM64 FileVersion: $($arm64Info.FileVersion), ProductVersion: $($arm64Info.ProductVersion)" -ForegroundColor Green

if ($x64Info.ProductVersion -notmatch "x64") {
    throw "x64 ProductVersion '$($x64Info.ProductVersion)' does not contain '-x64' suffix."
}
if ($arm64Info.ProductVersion -notmatch "arm64") {
    throw "ARM64 ProductVersion '$($arm64Info.ProductVersion)' does not contain '-arm64' suffix."
}

# -----------------------------------------------------------------------------
# 3. Regression Testing
# -----------------------------------------------------------------------------
if (-not $SkipTests) {
    Write-Host "`n[3/5] Executing Regression Test Suite..." -ForegroundColor Yellow
    $testScript = Join-Path $repoRoot "tests\Test-AvsAffinity.ps1"
    if (Test-Path $testScript) {
        Write-Host "  Testing x64 binary..." -ForegroundColor Cyan
        & $testScript -DllPath $x64Dll
        if ($LASTEXITCODE -ne 0) {
            throw "Regression tests failed for x64 binary with exit code $LASTEXITCODE."
        }

        Write-Host "  Testing ARM64 binary..." -ForegroundColor Cyan
        & $testScript -DllPath $arm64Dll
        if ($LASTEXITCODE -ne 0) {
            throw "Regression tests failed for ARM64 binary with exit code $LASTEXITCODE."
        }
        Write-Host "  [OK] All test suites passed." -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Test script not found at $testScript; skipping." -ForegroundColor Yellow
    }
} else {
    Write-Host "`n[3/5] Skipping test step (-SkipTests specified)." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------------
# 4. Packaging Archives & Individual Checksums
# -----------------------------------------------------------------------------
Write-Host "`n[4/5] Packaging Release Archives..." -ForegroundColor Yellow

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$readmeFile  = Join-Path $repoRoot "README.md"
$licenseFile = Join-Path $repoRoot "LICENSE"
$tempStage   = Join-Path $OutputDir "stage_temp"

if (Test-Path $tempStage) {
    Remove-Item -Recurse -Force $tempStage
}

$createdArchives = @()

# 4.1. x64 Standalone Archive
$x64Stage = Join-Path $tempStage "x64"
New-Item -ItemType Directory -Path $x64Stage -Force | Out-Null
Copy-Item $x64Dll $x64Stage
if (Test-Path $x64Pdb) { Copy-Item $x64Pdb $x64Stage }
Copy-Item $readmeFile $x64Stage
Copy-Item $licenseFile $x64Stage

$x64ZipName = "AvsAffinity-v${cleanVersion}-win-x64.zip"
$x64ZipPath = Join-Path $OutputDir $x64ZipName
if (Test-Path $x64ZipPath) { Remove-Item -Force $x64ZipPath }
Compress-Archive -Path "$x64Stage\*" -DestinationPath $x64ZipPath -CompressionLevel Optimal
$createdArchives += @{ Path = $x64ZipPath; Name = $x64ZipName }
Write-Host "  Created: $x64ZipName" -ForegroundColor Green

# 4.2. ARM64 Standalone Archive
$arm64Stage = Join-Path $tempStage "arm64"
New-Item -ItemType Directory -Path $arm64Stage -Force | Out-Null
Copy-Item $arm64Dll $arm64Stage
if (Test-Path $arm64Pdb) { Copy-Item $arm64Pdb $arm64Stage }
Copy-Item $readmeFile $arm64Stage
Copy-Item $licenseFile $arm64Stage

$arm64ZipName = "AvsAffinity-v${cleanVersion}-win-arm64.zip"
$arm64ZipPath = Join-Path $OutputDir $arm64ZipName
if (Test-Path $arm64ZipPath) { Remove-Item -Force $arm64ZipPath }
Compress-Archive -Path "$arm64Stage\*" -DestinationPath $arm64ZipPath -CompressionLevel Optimal
$createdArchives += @{ Path = $arm64ZipPath; Name = $arm64ZipName }
Write-Host "  Created: $arm64ZipName" -ForegroundColor Green

# 4.3. Universal Windows Archive
$allStage = Join-Path $tempStage "all"
$allStageX64 = Join-Path $allStage "x64"
$allStageArm64 = Join-Path $allStage "ARM64"
New-Item -ItemType Directory -Path $allStageX64 -Force | Out-Null
New-Item -ItemType Directory -Path $allStageArm64 -Force | Out-Null

Copy-Item $x64Dll $allStageX64
if (Test-Path $x64Pdb) { Copy-Item $x64Pdb $allStageX64 }
Copy-Item $arm64Dll $allStageArm64
if (Test-Path $arm64Pdb) { Copy-Item $arm64Pdb $allStageArm64 }
Copy-Item $readmeFile $allStage
Copy-Item $licenseFile $allStage

$allZipName = "AvsAffinity-v${cleanVersion}-windows.zip"
$allZipPath = Join-Path $OutputDir $allZipName
if (Test-Path $allZipPath) { Remove-Item -Force $allZipPath }
Compress-Archive -Path "$allStage\*" -DestinationPath $allZipPath -CompressionLevel Optimal
$createdArchives += @{ Path = $allZipPath; Name = $allZipName }
Write-Host "  Created: $allZipName" -ForegroundColor Green

# Clean up temp staging directory
Remove-Item -Recurse -Force $tempStage

# -----------------------------------------------------------------------------
# 5. Checksum Generation (.sha256 per archive)
# -----------------------------------------------------------------------------
Write-Host "`n[5/5] Generating Dedicated SHA-256 Checksums..." -ForegroundColor Yellow

foreach ($archive in $createdArchives) {
    $zipPath = $archive.Path
    $zipName = $archive.Name
    $shaName = [System.IO.Path]::ChangeExtension($zipName, ".sha256")
    $shaPath = Join-Path $OutputDir $shaName

    $hashObj = Get-FileHash -Path $zipPath -Algorithm SHA256
    $hashStr = $hashObj.Hash.ToLowerInvariant()
    $line = "$hashStr *$zipName"
    
    [System.IO.File]::WriteAllText($shaPath, "$line`n", [System.Text.Encoding]::ASCII)
    Write-Host "  Generated: $shaName ($hashStr)" -ForegroundColor Green
}

Write-Host "`n==========================================================" -ForegroundColor Cyan
Write-Host " Release Packaging Complete for v$cleanVersion" -ForegroundColor Green
Write-Host " Output Directory: $OutputDir" -ForegroundColor Green
Get-ChildItem -Path $OutputDir -File | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host "==========================================================" -ForegroundColor Cyan
