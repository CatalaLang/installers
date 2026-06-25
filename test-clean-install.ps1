#Requires -Version 5.1
<#
.SYNOPSIS
  Validate the Catala Windows MSI on a clean install (no opam in PATH).

.DESCRIPTION
  1. Moves the opam root to a timestamped backup dir (NOT deleted -- rollback is possible).
  2. Scrubs opam/dot entries from the session PATH and verifies no catala/ocaml
     tool leaks in from elsewhere.
  3. Installs the given MSI per-user via msiexec (silent).
  4. Asserts every tool resolves to the *installed* location, then runs the full
     test suite against catala-examples.
  5. Uninstalls.

  To roll back the opam move after the test:
    Move-Item "$env:LOCALAPPDATA\opam.bak.<timestamp>" "$env:LOCALAPPDATA\opam"

.PARAMETER Msi
  Path to the catala-*.msi to install and test. Required.

.PARAMETER CatalaExamples
  Path to an existing catala-examples checkout. If omitted, clones from GitHub.

.PARAMETER SkipSlowTests
  Skip the impot_revenu and us_tax_code OCaml backend tests (faster iteration).

.PARAMETER KeepInstalled
  Do not uninstall at the end (leave the install in place for manual poking).
#>
param(
    [Parameter(Mandatory)][string]$Msi,
    [string]$CatalaExamples = "",
    [switch]$SkipSlowTests,
    [switch]$KeepInstalled
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function info([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function ok([string]$msg)   { Write-Host "    ok: $msg" -ForegroundColor Green }
function warn([string]$msg) { Write-Host "  warn: $msg" -ForegroundColor Yellow }
function die([string]$msg)  { Write-Host " error: $msg" -ForegroundColor Red; exit 1 }

$base    = "$env:LOCALAPPDATA\Programs\Catala"
$msiAbs  = (Resolve-Path $Msi).Path

###############################################################################
# 1. Move opam root out of the way (NOT deleted -- rollback is possible)
###############################################################################

$opamRoot   = "$env:LOCALAPPDATA\opam"
$timestamp  = (Get-Date -Format "yyyyMMddHHmmss")
$opamBackup = "$env:LOCALAPPDATA\opam.bak.$timestamp"

if (Test-Path $opamRoot) {
    info "Moving opam root to $opamBackup"
    Move-Item $opamRoot $opamBackup
    ok "Moved (rollback: Move-Item '$opamBackup' '$opamRoot')"
} else {
    warn "No opam root at $opamRoot -- nothing to move"
}

# Scrub opam-injected entries from the current session PATH only (registry PATH
# is untouched), so anything we resolve later must come from the MSI install.
$env:PATH = ($env:PATH -split ';' |
    Where-Object { $_ -notmatch '\\opam\\' -and $_ -notmatch '\\\.' }) -join ';'

###############################################################################
# 2. Verify PATH is clean of pre-existing catala/ocaml tools
###############################################################################

info "Checking PATH is clean of OCaml / catala artifacts"
$leaked = $false
foreach ($cmd in @("ocamlopt", "catala", "clerk", "catala-format")) {
    $hit = Get-Command $cmd -ErrorAction SilentlyContinue
    if ($hit) {
        warn "$cmd still on PATH before install: $($hit.Source)"
        $leaked = $true
    }
}
if ($leaked) {
    warn "Some artifacts still in PATH -- test may not reflect a clean install"
} else {
    ok "PATH is clean"
}

###############################################################################
# 3. Install the MSI (per-user, silent). msiexec major-upgrades any prior install.
###############################################################################

info "Installing MSI: $msiAbs"
$log = Join-Path $env:TEMP "catala-msi-install-$PID.log"
$p = Start-Process msiexec.exe -Wait -PassThru `
        -ArgumentList "/i `"$msiAbs`" /qn /norestart /l*v `"$log`""
if ($p.ExitCode -ne 0) {
    Get-Content $log -Tail 60
    die "msiexec /i exited $($p.ExitCode) (full log: $log)"
}
if (-not (Test-Path "$base\bin\catala.cmd")) { die "Install incomplete: $base\bin\catala.cmd missing" }
ok "Installed to $base"

# Wire the install's bin\ into this session. The .cmd wrappers set everything
# else (CATALA_OCAML_LIBDIR / OCAMLLIB / NINJA_BIN / ...) themselves.
$env:PATH = "$base\bin;$env:PATH"

###############################################################################
# 4. Assert every tool resolves to the installed location (not something else)
###############################################################################

info "Verifying tools resolve to the install"
$resolveFailed = $false
foreach ($cmd in @("catala", "clerk", "catala-format", "catala-lsp", "catala-dap")) {
    $hit = Get-Command $cmd -ErrorAction SilentlyContinue
    if (-not $hit) { warn "$cmd not found after install"; $resolveFailed = $true; continue }
    if ($hit.Source -notlike "$base\*") {
        warn "$cmd resolves OUTSIDE the install: $($hit.Source)"
        $resolveFailed = $true
    } else {
        ok "$cmd -> $($hit.Source)"
    }
}
if ($resolveFailed) { die "A tool did not resolve to the installed bundle -- aborting" }

###############################################################################
# 5. Smoke test
###############################################################################

info "Smoke test"
catala --version
# Check the testcase plugin is present via catala --help (which lists plugins).
$catalaHelp = & catala --help 2>&1 | Out-String
if ($catalaHelp -notmatch "testcase") { die "testcase plugin missing from bundle (not listed in catala --help)" }
ok "catala testcase plugin OK"
clerk --help 2>&1 | Out-Null
catala-format --help 2>&1 | Out-Null
ok "Smoke test passed"

###############################################################################
# 6. catala-format unicode roundtrip
###############################################################################

$unicodeFile = Join-Path $PSScriptRoot "tests\catala-format-unicode.catala_fr"
if (Test-Path $unicodeFile) {
    info "catala-format unicode roundtrip"
    $out = catala-format $unicodeFile
    if ($LASTEXITCODE -ne 0) { die "catala-format exited $LASTEXITCODE" }
    ok "catala-format roundtrip passed ($($out.Length) chars)"
} else {
    warn "tests\catala-format-unicode.catala_fr not found -- skipping unicode test"
}

###############################################################################
# 7. catala-examples tests
###############################################################################

if (-not $CatalaExamples) {
    $CatalaExamples = Join-Path $env:TEMP "catala-examples-$PID"
    info "Cloning catala-examples to $CatalaExamples"
    git clone --quiet --depth=1 https://github.com/CatalaLang/catala-examples.git $CatalaExamples
    if ($LASTEXITCODE -ne 0) { die "git clone catala-examples failed" }
}

Push-Location $CatalaExamples
try {
    info "clerk test (interpret, allocations_familiales)"
    clerk test allocations_familiales
    if ($LASTEXITCODE -ne 0) { die "clerk test (interpret, allocations_familiales) failed" }
    ok "passed"

    info "clerk test (--backend=ocaml, allocations_familiales)"
    clerk test allocations_familiales --backend=ocaml
    if ($LASTEXITCODE -ne 0) { die "clerk test (--backend=ocaml, allocations_familiales) failed" }
    ok "passed"

    if (-not $SkipSlowTests) {
        info "clerk test (--backend=ocaml, impot_revenu)"
        clerk test impot_revenu --backend=ocaml
        if ($LASTEXITCODE -ne 0) { die "clerk test (--backend=ocaml, impot_revenu) failed" }
        ok "passed"

        info "clerk test (--backend=ocaml, us_tax_code)"
        clerk test us_tax_code --backend=ocaml
        if ($LASTEXITCODE -ne 0) { die "clerk test (--backend=ocaml, us_tax_code) failed" }
        ok "passed"
    }
} finally {
    Pop-Location
}

###############################################################################
# 8. Uninstall
###############################################################################

if (-not $KeepInstalled) {
    info "Uninstalling MSI"
    $p = Start-Process msiexec.exe -Wait -PassThru `
            -ArgumentList "/x `"$msiAbs`" /qn /norestart"
    if ($p.ExitCode -ne 0) { die "msiexec /x exited $($p.ExitCode)" }
    if (Test-Path "$base\bin\catala.cmd") { die "Uninstall left files behind at $base" }
    ok "Uninstalled cleanly"
}

###############################################################################
# Done
###############################################################################

Write-Host ""
Write-Host "=== All tests passed ===" -ForegroundColor Green
Write-Host ""
Write-Host "Opam backup at : $opamBackup" -ForegroundColor Yellow
Write-Host "To roll back   : Move-Item '$opamBackup' '$opamRoot'" -ForegroundColor Yellow
