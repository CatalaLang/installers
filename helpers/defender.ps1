#Requires -Version 5.1
<#
.SYNOPSIS
  Add or remove Windows Defender exclusions for the Catala toolchain.

.DESCRIPTION
  Defender real-time scanning of the compiler storm (ocamlopt/flexlink/gcc/ld/as
  + heavy .o/.cmx I/O) roughly doubles `clerk test` wall time. Adds scoped
  exclusions (path + full-path process; NOT a global disable, which Tamper
  Protection blocks anyway). Non-fatal by design: a policy-locked machine still
  works (just slower), so failure here must never fail the install.

.PARAMETER InstallDir
  Catala install directory (contains bin\ and toolchain\).

.PARAMETER Add
  Add the exclusions.

.PARAMETER Remove
  Remove the exclusions (uninstall / --remove).

.PARAMETER SelfElevate
  Relaunch once through UAC if not elevated. Used by the installer.

.PARAMETER Quiet
  Suppress the banner (silent installs).
#>
param(
    [Parameter(Mandatory = $true)][string]$InstallDir,
    [switch]$Add,
    [switch]$Remove,
    [switch]$SelfElevate,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
# Non-fatal by contract: never let an exclusion problem fail the caller.
$ErrorActionPreference = 'Continue'

function info([string]$m) { if (-not $Quiet) { Write-Host $m } }
function warn([string]$m) { Write-Host $m -ForegroundColor Yellow }

if (-not ($Add -or $Remove)) { $Add = $true }   # default action is -Add

# Strip trailing slash so paths compare/print cleanly.
$InstallDir = $InstallDir.TrimEnd('\', '/')
$tcBin = Join-Path $InstallDir 'toolchain\bin'

# Full paths only. collect2/cc1 live under the gcc libexec tree; added below when present.
$procNames = @(
    'ocamlopt.exe', 'ocamlc.exe', 'flexlink.exe', 'ninja.exe',
    'gcc.exe', 'x86_64-w64-mingw32-gcc.exe', 'ld.exe', 'as.exe',
    'catala.exe', 'clerk.exe'
)
$procPaths = @()
foreach ($p in $procNames) {
    $full = Join-Path $tcBin $p
    if (Test-Path $full) { $procPaths += $full }
}
$libexecGcc = Join-Path $InstallDir 'toolchain\libexec\gcc'
if (Test-Path $libexecGcc) {
    Get-ChildItem -Path $libexecGcc -Recurse -Include 'collect2.exe', 'cc1.exe', 'cc1plus.exe' `
        -ErrorAction SilentlyContinue | ForEach-Object { $procPaths += $_.FullName }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Print-GpoList {
    warn "Administrator rights are required to set Windows Defender exclusions."
    warn "On a managed machine, ask IT to push these via GPO/Intune:"
    Write-Host ""
    Write-Host "  Exclusion path:"
    Write-Host "    $InstallDir"
    Write-Host "  Exclusion processes:"
    foreach ($p in $procPaths) { Write-Host "    $p" }
    Write-Host ""
}

# Defender cmdlets may be absent (Server Core, third-party AV): non-fatal, nothing to do.
if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    info "Windows Defender cmdlets not available; skipping exclusions."
    exit 0
}

if (-not (Test-Admin)) {
    if ($SelfElevate) {
        # WITHOUT -SelfElevate to avoid an elevation loop.
        $action = if ($Remove) { '-Remove' } else { '-Add' }
        $argList = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass',
            '-File', "`"$PSCommandPath`"",
            '-InstallDir', "`"$InstallDir`"", $action
        )
        if ($Quiet) { $argList += '-Quiet' }
        try {
            $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                    -Verb RunAs -PassThru -Wait -ErrorAction Stop
            exit $p.ExitCode
        } catch {
            # UAC declined, or no interactive desktop (silent install).
            warn "Could not elevate to set Defender exclusions ($($_.Exception.Message))."
            Print-GpoList
            exit 0
        }
    } else {
        Print-GpoList
        exit 0
    }
}

# --- Elevated from here on -------------------------------------------------

if ($Remove) {
    info "Removing Catala Windows Defender exclusions..."
    Remove-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue
    foreach ($p in $procPaths) {
        Remove-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue
    }
    info "Done."
    exit 0
}

info "Adding Catala Windows Defender exclusions..."
Add-MpPreference -ExclusionPath $InstallDir -ErrorAction SilentlyContinue
foreach ($p in $procPaths) {
    Add-MpPreference -ExclusionProcess $p -ErrorAction SilentlyContinue
}
info "Added 1 path + $($procPaths.Count) process exclusions for $InstallDir."
exit 0
