#Requires -Version 5.1
<#
.SYNOPSIS
  Add or remove Windows Defender exclusions for the Catala toolchain.

.DESCRIPTION
  Catala's build/test loop spawns a storm of short-lived native compilers
  (ocamlopt -> flexlink -> gcc -> ld -> as) plus catala/clerk themselves, with
  heavy temp/.o/.cmx/.cmxs I/O. Defender real-time scanning of all that pegs
  MsMpEng.exe and roughly doubles `clerk test` wall time on a 2-core machine.

  This script adds *scoped* exclusions (NOT a global disable -- Tamper
  Protection blocks that and it is worse posture):
    - a path exclusion for the install directory (covers the toolchain tree
      and any temp files written under it), and
    - full-path process exclusions for the bundled compilers (full path, not
      bare name, so the exclusion is not trivially spoofable and also covers
      the temp I/O those processes do regardless of the working directory).

  Defender exclusions are machine-wide (HKLM) and always require an elevated
  token. This script:
    - if already elevated, applies the exclusions directly;
    - if not elevated and -SelfElevate is given, relaunches itself once via
      UAC (Start-Process -Verb RunAs);
    - if not elevated and cannot/should not elevate, prints the exact
      exclusion list so it can be pushed via GPO/Intune, and exits 0.

  It is intentionally non-fatal: on a managed machine where exclusions are
  policy-locked, the toolchain still works (just slower), so a failure here
  must never fail the install.

.PARAMETER InstallDir
  The Catala install directory (the folder containing bin\ and toolchain\).

.PARAMETER Add
  Add the exclusions.

.PARAMETER Remove
  Remove the exclusions (used on uninstall and by `--remove`).

.PARAMETER SelfElevate
  If not running elevated, relaunch once through UAC. Used by the installer.

.PARAMETER Quiet
  Suppress the informational banner (used for silent installs).
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

# Normalise: strip a trailing slash so paths compare/print cleanly.
$InstallDir = $InstallDir.TrimEnd('\', '/')
$tcBin = Join-Path $InstallDir 'toolchain\bin'

# The processes whose scanning dominates the build/test loop. Full paths only.
# collect2.exe / cc1.exe live under the gcc libexec tree; include them when present.
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
# gcc's internal helpers (collect2, cc1) under libexec\gcc\<triple>\<ver>\
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

# Defender may be absent (Server Core), replaced by a third-party AV, or the
# cmdlets may be unavailable. Treat all of that as "nothing to do", non-fatal.
if (-not (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
    info "Windows Defender cmdlets not available; skipping exclusions."
    exit 0
}

if (-not (Test-Admin)) {
    if ($SelfElevate) {
        # Relaunch once, elevated, WITHOUT -SelfElevate to avoid a loop.
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
            # User declined UAC, or no interactive desktop (silent install).
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
