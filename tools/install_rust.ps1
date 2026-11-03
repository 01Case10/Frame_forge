#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Rust toolchain (rustup + stable) on Windows.
.DESCRIPTION
    Idempotent: if cargo is already on PATH it just verifies and exits.
    Otherwise installs via winget when available, falling back to the
    official rustup-init.exe download. Refreshes PATH for the current
    session, verifies cargo/rustc, and warns if no MSVC linker is found
    (needed to build the FrameForge GDExtension crate on Windows).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\install_rust.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$LASTEXITCODE = 0

function Write-Step([string]$Message) {
    Write-Host "[rust-setup] $Message"
}

function Get-CargoCommand {
    return Get-Command cargo -ErrorAction SilentlyContinue
}

function Update-SessionPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
    $cargoBin = Join-Path $HOME ".cargo\bin"
    if ($env:Path -notlike "*$cargoBin*") {
        $env:Path = "$cargoBin;$env:Path"
    }
}

function Install-WithWinget {
    Write-Step "Installing rustup via winget..."
    & winget install --exact --id Rustlang.Rustup --silent `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) { throw "winget install failed with exit code $LASTEXITCODE" }
}

function Install-WithRustupInit {
    Write-Step "winget not found; downloading rustup-init.exe..."
    $url = "https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe"
    $installer = Join-Path $env:TEMP "rustup-init.exe"
    Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing
    try {
        Write-Step "Running rustup-init (stable toolchain)..."
        & $installer -y --default-toolchain stable --profile default
        if ($LASTEXITCODE -ne 0) { throw "rustup-init failed with exit code $LASTEXITCODE" }
    }
    finally {
        Remove-Item $installer -Force -ErrorAction SilentlyContinue
    }
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

# 1. Already installed?
Update-SessionPath
$existing = Get-CargoCommand
if ($existing) {
    Write-Step "cargo already installed: $(& cargo --version)"
    Write-Step "rustc: $(& rustc --version)"
}
else {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Install-WithWinget
    }
    else {
        Install-WithRustupInit
    }
    Update-SessionPath
    if (-not (Get-CargoCommand)) {
        throw "cargo not found on PATH after install; restart your terminal and re-run."
    }
    Write-Step "Ensuring stable toolchain..."
    & rustup toolchain install stable
    if ($LASTEXITCODE -ne 0) { throw "rustup toolchain install failed" }
    # Best-effort only: rustup-init already sets the default toolchain, and
    # a known rustup-on-Windows self-update bug can make this exact call
    # fail with a bogus "+toolchain" error even though the toolchain is
    # fine (https://github.com/rust-lang/rustup/issues/3709). Never fail
    # the whole setup over it.
    & rustup default stable
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[rust-setup] WARNING: 'rustup default stable' hit a rustup bug; ignoring." -ForegroundColor Yellow
        $LASTEXITCODE = 0
    }
    Write-Step "cargo: $(& cargo --version)"
    if ($LASTEXITCODE -ne 0) { throw "cargo --version failed after install" }
    Write-Step "rustc: $(& rustc --version)"
    if ($LASTEXITCODE -ne 0) { throw "rustc --version failed after install" }
}

# 2. MSVC linker check (needed to build the GDExtension crate on Windows).
if (Test-MsvcLinker) {
    Write-Step "MSVC linker found (cl.exe) - native builds will work."
}
else {
    Write-Host "[rust-setup] WARNING: no MSVC linker (cl.exe) found." -ForegroundColor Yellow
    Write-Host "[rust-setup] Install 'Visual Studio Build Tools' with the 'Desktop development with C++' workload:" -ForegroundColor Yellow
    Write-Host "[rust-setup] https://visualstudio.microsoft.com/visual-cpp-build-tools/" -ForegroundColor Yellow
}

Write-Step "Done."
