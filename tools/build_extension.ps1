#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the FrameForge GDExtension (frameforge_godot.dll) on Windows.
.DESCRIPTION
    1. cargo build -p frameforge-godot (debug by default; -Release for release)
    2. Copies the DLL to addons/frameforge/bin/
    3. Registers windows.x86_64 entries in addons/frameforge/frameforge.gdextension
    Idempotent: re-running rebuilds and re-copies; the .gdextension edit is
    skipped when the entries already exist.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build_extension.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\build_extension.ps1 -Release
#>
param(
    [switch]$Release
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$LASTEXITCODE = 0

function Write-Step([string]$Message) {
    Write-Host "[ff-build] $Message"
}

function Get-RepoRoot {
    $dir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($dir) -and $PSCommandPath) {
        $dir = Split-Path $PSCommandPath -Parent
    }
    if ([string]::IsNullOrEmpty($dir)) {
        $dir = (Get-Location).Path
    }
    # This script lives in <root>/tools.
    $root = Split-Path $dir -Parent
    if (-not (Test-Path (Join-Path $root "project.godot"))) {
        $cwd = (Get-Location).Path
        if (Test-Path (Join-Path $cwd "project.godot")) {
            return $cwd
        }
        throw "Cannot locate the Frame_forge repo root (project.godot not found)."
    }
    return $root
}

function Test-MsvcLinker {
    if (Get-Command cl.exe -ErrorAction SilentlyContinue) { return $true }
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $found = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath 2>$null
        if ($found) { return $true }
    }
    return $false
}

function Add-WindowsGdextensionEntries([string]$GdextPath) {
    $dllDebug = 'windows.x86_64.debug = "res://addons/frameforge/bin/frameforge_godot.dll"'
    $dllRelease = 'windows.x86_64.release = "res://addons/frameforge/bin/frameforge_godot.dll"'
    $text = [IO.File]::ReadAllText($GdextPath)
    if ($text -match "windows\.x86_64\.debug") {
        Write-Step "frameforge.gdextension already has windows entries."
        return
    }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = @($text -split "`r?`n")
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -eq "[libraries]") { $idx = $i; break }
    }
    $newLines = @($dllDebug, $dllRelease)
    if ($idx -ge 0) {
        $before = @($lines[0..$idx])
        if ($idx + 1 -lt $lines.Count) {
            $after = @($lines[($idx + 1)..($lines.Count - 1)])
        } else {
            $after = @()
        }
        $lines = $before + $newLines + $after
    } else {
        $lines = $lines + $newLines
    }
    [IO.File]::WriteAllText($GdextPath, ($lines -join $nl))
    Write-Step "Registered windows.x86_64 entries in frameforge.gdextension."
}

# --- main ---
$repoRoot = Get-RepoRoot
$profile = if ($Release) { "release" } else { "debug" }
Write-Step "Repo root: $repoRoot"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo not found on PATH. Run tools\install_rust.ps1 first."
}
if (-not (Test-MsvcLinker)) {
    Write-Host "[ff-build] WARNING: no MSVC linker found; the build will likely fail." -ForegroundColor Yellow
    Write-Host "[ff-build] Install 'Visual Studio Build Tools' with the 'Desktop development with C++' workload." -ForegroundColor Yellow
}

Write-Step "Building frameforge-godot ($profile) - first build takes a few minutes..."
$manifest = Join-Path (Join-Path $repoRoot "rust") "Cargo.toml"
$cargoArgs = @("build", "--manifest-path", $manifest, "-p", "frameforge-godot")
if ($Release) { $cargoArgs += "--release" }
& cargo @cargoArgs
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

$dllName = "frameforge_godot.dll"
$srcDll = Join-Path (Join-Path (Join-Path $repoRoot "rust") "target") "$profile/$dllName"
if (-not (Test-Path $srcDll)) { throw "Build succeeded but DLL not found: $srcDll" }
$binDir = Join-Path (Join-Path (Join-Path $repoRoot "addons") "frameforge") "bin"
New-Item -ItemType Directory -Force -Path $binDir | Out-Null
Copy-Item $srcDll (Join-Path $binDir $dllName) -Force
Write-Step "Copied to addons\frameforge\bin\$dllName"

Add-WindowsGdextensionEntries (Join-Path (Join-Path (Join-Path $repoRoot "addons") "frameforge") "frameforge.gdextension")

$LASTEXITCODE = 0
Write-Step "Done. Open the project in Godot 4.6+ and press F5 for the demo menu."
