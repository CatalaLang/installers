#Requires -Version 5.1
<#
.SYNOPSIS
  Assemble a self-contained Windows catala bundle and package it as an MSI.

.DESCRIPTION
  Stages the toolchain from the opam switch, then builds a per-user MSI with
  WiX. The `wix` dotnet tool must be on PATH, pinned to v5 (v6+/v7 need the
  Open Source Maintenance Fee EULA, error WIX7015):
    dotnet tool install --global wix --version 5.0.2
    wix extension add -g WixToolset.Util.wixext/5.0.2
    wix extension add -g WixToolset.UI.wixext/5.0.2

  Run from the root of the catala repository after installing all components:
    opam install ./catala.opam
    opam install catala-format catala-lsp

.PARAMETER OutputDir
  Directory for the output zip (default: _bundle)

.EXAMPLE
  cd C:\src\catala
  powershell -ExecutionPolicy Bypass -File ..\installers\build-bundle.ps1
#>
param(
    [string]$OutputDir  = "_bundle",
    [string]$MingwZip   = "",   # path to pre-downloaded winlibs zip (skips download)
    [string]$LspPath    = "",   # path to catala-language-server checkout (build VSIX from source)
    [string]$LspRef     = "fix/windows-vscode-spawn",  # TODO: reset to "master" once shell:true fix merges
    [ValidateSet("perUser","perMachine")]
    [string]$Scope      = "perMachine"  # perMachine -> C:\ProgramData\Catala (shipped: IT-deployable, space-free); perUser -> %LOCALAPPDATA% (no admin)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function info([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function ok([string]$msg)   { Write-Host "    ok: $msg" -ForegroundColor Green }
function warn([string]$msg) { Write-Host "  warn: $msg" -ForegroundColor Yellow }
function die([string]$msg)  { Write-Host " error: $msg" -ForegroundColor Red; exit 1 }

function Require-Cmd([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) { die "Required: $name" }
}

if (-not (Test-Path "catala.opam")) { die "Run from the catala repository root" }

Require-Cmd opam
Require-Cmd ocamlopt
Require-Cmd ocamlc
Require-Cmd ocamlfind

$opamPrefix  = (& opam var prefix 2>&1).Trim()
$ocamlStdlib = (& ocamlc -where 2>&1).Trim()
$zarithDir   = (& ocamlfind query zarith 2>&1).Trim()
if ($LASTEXITCODE -ne 0) { die "zarith not found - run: opam install zarith" }

$versionLine = (Get-Content "catala.opam" | Select-String '^version:' | Select-Object -First 1).ToString()
$version = [regex]::Match($versionLine, '"([^"]+)"').Groups[1].Value
if (-not $version) { die "Could not read version from catala.opam" }

# Prefer the real ninja binary over shim wrappers.
# On Windows, both Chocolatey and opam install a .NET shim in their bin\ directory
# that looks for the real binary at ..\lib\ninja\tools\ninja.exe relative to the shim.
# Copying the shim into a different location breaks that relative lookup.
# The real binary lives in the lib\ tree; probe those locations first.
$ninja = $null
foreach ($candidate in @(
    "$opamPrefix\lib\ninja\tools\ninja.exe",
    "C:\ProgramData\chocolatey\lib\ninja\tools\ninja.exe"
)) {
    if (Test-Path $candidate) { $ninja = $candidate; break }
}
if (-not $ninja) {
    $ninjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
    if ($ninjaCmd) {
        $ninja = $ninjaCmd.Source
        warn "ninja found at $ninja -- may be a shim wrapper; bundle may not work correctly"
    }
}
if (-not $ninja) { die "ninja not found (tried opam lib, chocolatey lib, PATH)" }

info "Version      : $version"
info "opam prefix  : $opamPrefix"
info "OCaml stdlib : $ocamlStdlib"
info "zarith       : $zarithDir"
ok "ninja: $ninja"

###############################################################################
# External component versions -- bump the URL here when upgrading MinGW-w64
###############################################################################

# Single canonical source: update only this URL when upgrading the toolchain.
# $mingwGccVer is parsed from it (used for lib/gcc/<arch>/<ver>/ paths inside the zip).
$mingwMsvcrtUrl = "https://github.com/brechtsanders/winlibs_mingw/releases/download/16.1.0posix-14.0.0-msvcrt-r3/winlibs-x86_64-posix-seh-gcc-16.1.0-mingw-w64msvcrt-14.0.0-r3.zip"
$mingwGccVer = [regex]::Match($mingwMsvcrtUrl, '-gcc-(\d+\.\d+\.\d+)-').Groups[1].Value
if (-not $mingwGccVer) { die "Could not parse GCC version from mingw URL: $mingwMsvcrtUrl" }

###############################################################################
# Pre-flight checks
###############################################################################

Require-Cmd git
Require-Cmd node
Require-Cmd npm

foreach ($b in @("catala", "clerk", "catala-lsp", "catala-dap")) {
    if (-not (Test-Path "$opamPrefix\bin\$b.exe")) {
        die "$b.exe not found at $opamPrefix\bin -- install the full catala opam package"
    }
    ok $b
}
# catala-format: may be installed without .exe extension on Cygwin opam
if (-not (Test-Path "$opamPrefix\bin\catala-format.exe") -and -not (Test-Path "$opamPrefix\bin\catala-format")) {
    die "catala-format not found at $opamPrefix\bin -- run: opam install catala-format"
}
ok "catala-format"

###############################################################################
# Inputs report -- make explicit what this build harvests. The bundle is
# assembled from one opam switch; this prints each source package's version and
# provenance (opam pin source, plus the git SHA when the pin is a local
# checkout), and the pinned winlibs gcc. Informational only -- never fatal.
###############################################################################
info "Build inputs (harvested from opam switch $opamPrefix):"
foreach ($pkg in @("catala", "catala-lsp", "catala-format")) {
    $ver = "?"; $prov = "(not pinned)"
    try {
        $v = (& opam show $pkg --field=version 2>$null | Out-String).Trim()
        if ($v) { $ver = $v }
    } catch {}
    try {
        $pinLine = (& opam pin list 2>$null |
                    Where-Object { $_ -match "^$([regex]::Escape($pkg))\.\S" } |
                    Select-Object -First 1)
        if ($pinLine -and ($pinLine -match '^\S+\s+(\S+)\s+(.+?)\s*$')) {
            $kind = $Matches[1]; $target = $Matches[2]
            $prov = "$kind $target"
            $srcDir = ($target -replace '^git\+', '') -replace '^file://', '' -replace '#.*$', ''
            if ($srcDir -and (Test-Path (Join-Path $srcDir '.git'))) {
                $sha = (& git -C $srcDir rev-parse --short HEAD 2>$null | Out-String).Trim()
                if ($sha) {
                    if (& git -C $srcDir status --porcelain 2>$null) { $sha = "$sha-dirty" }
                    $prov = "$prov @ $sha"
                }
            }
        }
    } catch {}
    ok ("  {0,-14} {1,-8} {2}" -f $pkg, $ver, $prov)
}
ok ("  {0,-14} {1,-8} {2}" -f "winlibs-gcc", $mingwGccVer, $mingwMsvcrtUrl)

###############################################################################
# VSIX: build from catala-language-server source
###############################################################################

$vsixSrc   = ""
$lspCloned = $false

# Resolve LSP repo: -LspPath > auto-discover > clone from -LspRef
if ($LspPath) {
    if (-not (Test-Path $LspPath))      { die "LspPath not found: $LspPath" }
    if (-not (Test-Path "$LspPath\.git")) { die "LspPath is not a git repository: $LspPath" }
    $lspRepo = Resolve-Path $LspPath
} elseif (Test-Path "..\catala-language-server\.git") {
    $lspRepo = Resolve-Path "..\catala-language-server"
} elseif ($LspRef) {
    info "Cloning catala-language-server @ $LspRef"
    $lspCloneDir = Join-Path $env:TEMP "catala-lsp-$(Get-Random)"
    # Try branch/tag clone first; fall back to two-step (clone + fetch) for SHAs
    & git clone --depth=1 --branch $LspRef `
        https://github.com/CatalaLang/catala-language-server.git $lspCloneDir
    if ($LASTEXITCODE -ne 0) {
        # Fallback for SHAs: clone default branch then fetch the exact commit
        & git clone --depth=1 `
            https://github.com/CatalaLang/catala-language-server.git $lspCloneDir
        if ($LASTEXITCODE -ne 0) { die "git clone catala-language-server failed" }
        Push-Location $lspCloneDir
        & git fetch --depth=1 origin $LspRef
        if ($LASTEXITCODE -ne 0) { Pop-Location; die "git fetch $LspRef failed" }
        & git checkout FETCH_HEAD
        if ($LASTEXITCODE -ne 0) { Pop-Location; die "git checkout FETCH_HEAD failed" }
        Pop-Location
    }
    if (-not (Test-Path "$lspCloneDir\.git")) { die "Clone produced no .git dir: $lspCloneDir" }
    $lspRepo   = $lspCloneDir
    $lspCloned = $true
} else {
    warn "No catala-language-server source found; VSIX will not be included in bundle"
    $lspRepo = $null
}

if ($lspRepo) {
    # Log exact SHA so the build is reproducible
    $lspSha    = (& git -C $lspRepo rev-parse HEAD 2>&1).Trim()
    $lspBranch = (& git -C $lspRepo rev-parse --abbrev-ref HEAD 2>&1).Trim()
    if ($LASTEXITCODE -ne 0) { die "git rev-parse failed in $lspRepo" }
    ok "catala-language-server: $lspBranch @ $lspSha"

    # Find the extension package.json (has "publisher" field, unlike OCaml project files)
    $pkgJson = Get-ChildItem $lspRepo -Filter "package.json" -Recurse -Depth 3 `
               -ErrorAction SilentlyContinue |
               Where-Object {
                   (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match '"publisher"'
               } | Select-Object -First 1
    if (-not $pkgJson) { die "Extension package.json not found in $lspRepo" }
    $extDir = $pkgJson.DirectoryName

    info "Building VSIX (npm ci + vsce package) in $extDir"
    Push-Location $extDir
    try {
        & npm ci --quiet
        if ($LASTEXITCODE -ne 0) { die "npm ci failed" }
        & npx --yes @vscode/vsce package --no-dependencies --out "catala-$version.vsix"
        if ($LASTEXITCODE -ne 0) { die "vsce package failed" }
    } finally {
        Pop-Location
    }

    $vsixSrc = Join-Path $extDir "catala-$version.vsix"
    if (-not (Test-Path $vsixSrc)) { die "VSIX not found after build: $vsixSrc" }
    ok "VSIX built: catala-$version.vsix"

}

###############################################################################
# Staging directory
###############################################################################

$bundleName = "catala-$version-windows-x86_64"
$staging    = "$OutputDir\stage\$bundleName"

info "Assembling $staging"
Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
@(
    "$staging\bin",
    "$staging\toolchain\bin",
    "$staging\toolchain\libexec",
    "$staging\toolchain\libexec\gcc\x86_64-w64-mingw32\$mingwGccVer",
    "$staging\toolchain\lib\catala\plugins",
    "$staging\toolchain\lib\catala\runtime",
    "$staging\toolchain\lib\gcc\x86_64-w64-mingw32\$mingwGccVer",
    "$staging\toolchain\lib\ocaml",
    "$staging\toolchain\lib\zarith",
    "$staging\toolchain\share\topiary\queries",
    "$staging\toolchain\share\topiary\configs",
    "$staging\toolchain\x86_64-w64-mingw32\lib"
) | ForEach-Object { New-Item -ItemType Directory -Force $_ | Out-Null }

$version | Set-Content "$staging\version" -NoNewline

###############################################################################
# Toolchain binaries
###############################################################################

info "Copying toolchain binaries"
foreach ($b in @("catala", "clerk", "ocamlopt", "ocamlc")) {
    $src = "$opamPrefix\bin\$b.exe"
    if (-not (Test-Path $src)) { die "$b.exe not found at $src" }
    Copy-Item $src "$staging\toolchain\bin\$b.exe"
    ok "$b.exe"
}
Copy-Item $ninja "$staging\toolchain\bin\ninja.exe"; ok "ninja.exe"
# flexlink: linker tool for ocamlopt -shared.
# With flexdll 0.43+ (OCaml 5.x), the runtime is .o files in lib/ocaml/flexdll/,
# not a separate DLL -- those are copied as part of the OCaml stdlib below.
$flexlink = "$opamPrefix\bin\flexlink.exe"
if (Test-Path $flexlink) {
    Copy-Item $flexlink "$staging\toolchain\bin\flexlink.exe"; ok "flexlink.exe"
} else { die "flexlink.exe not found at $opamPrefix\bin" }
$flexdllDir = "$ocamlStdlib\flexdll"
foreach ($obj in @("flexdll_initer_mingw64.o", "flexdll_mingw64.o")) {
    if (-not (Test-Path "$flexdllDir\$obj")) { die "$obj not found in $flexdllDir" }
}

foreach ($b in @("catala-lsp", "catala-dap")) {
    Copy-Item "$opamPrefix\bin\$b.exe" "$staging\toolchain\bin\$b.exe"; ok "$b.exe"
}
# catala-format: opam installs the OCaml binary as "catala-format" (no .exe on Cygwin);
# look for both catala-format.exe and catala-format (the latter is the actual OCaml PE).
$catalaFormatBin = if (Test-Path "$opamPrefix\bin\catala-format.exe") { "$opamPrefix\bin\catala-format.exe" }
                   elseif (Test-Path "$opamPrefix\bin\catala-format")  { "$opamPrefix\bin\catala-format" }
                   else { $null }
if ($catalaFormatBin) {
    Copy-Item $catalaFormatBin "$staging\toolchain\bin\catala-format.exe"; ok "catala-format.exe (from $catalaFormatBin)"
} else { die "catala-format not found at $opamPrefix\bin -- run: opam install catala-format" }

# topiary: opam installs the Rust binary at $bin/.topiary-wrapped/topiary and a Cygwin
# shell wrapper at $bin/topiary.  We need the actual native PE binary, not the shell wrapper.
$topyBin = if (Test-Path "$opamPrefix\bin\.topiary-wrapped\topiary.exe") { "$opamPrefix\bin\.topiary-wrapped\topiary.exe" }
           elseif (Test-Path "$opamPrefix\bin\.topiary-wrapped\topiary")  { "$opamPrefix\bin\.topiary-wrapped\topiary" }
           else { $null }
if ($topyBin) {
    New-Item -ItemType Directory -Force "$staging\toolchain\bin\.topiary-wrapped" | Out-Null
    Copy-Item $topyBin "$staging\toolchain\bin\.topiary-wrapped\topiary.exe"
    ok "topiary.exe (from $topyBin)"
} else { die "topiary native binary not found at $opamPrefix\bin\.topiary-wrapped -- run: opam install catala-format (needs Rust/cargo)" }
# catala.scm and catala.ncl: installed by catala-format opam package into topiary's share dir
$ts = "$opamPrefix\share\topiary"
if (Test-Path "$ts\queries\catala.scm") {
    Copy-Item "$ts\queries\catala.scm" "$staging\toolchain\share\topiary\queries\"
    ok "catala.scm"
} else { warn "catala.scm not found at $ts\queries -- catala-format may fail" }
if (Test-Path "$ts\configs\catala.ncl") {
    Copy-Item "$ts\configs\catala.ncl" "$staging\toolchain\share\topiary\configs\"
    ok "catala.ncl"
} else { warn "catala.ncl not found at $ts\configs -- catala-format may fail" }

###############################################################################
# MinGW runtime DLLs
# opam on Windows (via setup-ocaml) copies needed DLLs into the switch bin dir.
# We also probe known MSYS2/Cygwin paths as a fallback.
###############################################################################

info "Collecting MinGW runtime DLLs and import libs"
# opam on Windows installs GMP via its own Cygwin root, not in the opam switch bin
$opamRoot = (& opam var root 2>&1).Trim()
$dllSearchDirs = @(
    "$opamPrefix\bin",
    "$opamRoot\.cygwin\root\usr\x86_64-w64-mingw32\sys-root\mingw\bin",
    "C:\msys64\mingw64\bin",
    "C:\cygwin64\usr\x86_64-w64-mingw32\sys-root\mingw\bin"
)
# Parallel lib dirs for import libraries (.dll.a / .a) needed when linking executables
$libSearchDirs = $dllSearchDirs | ForEach-Object { $_ -replace '\\bin$', '\lib' }

# Only libgmp comes from opam/Cygwin: zarith links against it and needs the
# matching import lib (libgmp.dll.a), which winlibs does not ship.
# The GCC runtime DLLs (libgcc_s_seh-1, libwinpthread-1) MUST come from winlibs
# (extracted below), to match the winlibs gcc/as: the opam/Cygwin builds of
# libwinpthread-1.dll drag in a dependency absent on a clean Windows box, so a
# mixed set makes gcc.exe/as.exe fail to load (STATUS_DLL_NOT_FOUND) and breaks
# the OCaml native backend. Single-source the native toolchain from winlibs.
foreach ($dll in @("libgmp-10.dll")) {
    $found = $false
    foreach ($dir in $dllSearchDirs) {
        $src = Join-Path $dir $dll
        if (Test-Path $src) {
            Copy-Item $src "$staging\toolchain\bin\"; ok "DLL: $dll"; $found = $true; break
        }
    }
    if (-not $found) {
        die "$dll not found in any of: $($dllSearchDirs -join ', ')"
    }
}
# Import libraries (.dll.a) for the same DLLs -- needed by ld when compiling OCaml
# executables (e.g. clerk test --backend=ocaml), which link zarith -> -lgmp.
foreach ($lib in @("libgmp.dll.a", "libgmp.a")) {
    $found = $false
    foreach ($dir in $libSearchDirs) {
        $src = Join-Path $dir $lib
        if (Test-Path $src) {
            Copy-Item $src "$staging\toolchain\x86_64-w64-mingw32\lib\"; ok "import lib: $lib"; $found = $true; break
        }
    }
    if ($lib -eq "libgmp.dll.a" -and -not $found) {
        die "libgmp.dll.a not found in any of: $($libSearchDirs -join ', ') -- required for clerk test --backend=ocaml"
    }
}
# No opam-bin lib*.dll sweep: the native runtime is single-sourced from winlibs
# (above) plus the explicit libgmp exception. The import-closure check at the end
# of staging proves self-containment, so we don't silently bundle stray (likely
# Cygwin-built) DLLs -- the mixed-sourcing that caused STATUS_DLL_NOT_FOUND.

###############################################################################
# MinGW-w64 gcc (MSVCRT variant) -- minimal set needed for ocamlopt -shared
#
# The MSVCRT variant (not UCRT) is required: it links against msvcrt.dll which
# is always present on Windows, whereas UCRT DLLs may be absent on clean VMs.
# We extract only the files flexlink actually needs; the full 260 MB zip is NOT
# bundled -- only the selected entries are placed into staging (~16 MB).
###############################################################################

# Filename encodes the URL hash so a different release auto-invalidates the cache.
$mingwCacheKey = [System.BitConverter]::ToString(
    [System.Security.Cryptography.MD5]::Create().ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($mingwMsvcrtUrl))).Replace("-","").ToLower().Substring(0,8)
$mingwCache = Join-Path $env:TEMP "catala-mingw-$mingwCacheKey.zip"

$mingwTmpZip = $null
if ($MingwZip) {
    if (-not (Test-Path $MingwZip)) { die "MingwZip not found: $MingwZip" }
    $mingwTmpZip = $MingwZip
    ok "Using supplied MinGW zip: $MingwZip"
} elseif (Test-Path $mingwCache) {
    $mingwTmpZip = $mingwCache
    ok "Using cached MinGW zip ($([math]::Round((Get-Item $mingwCache).Length/1MB,0)) MB): $mingwCache"
} else {
    info "Downloading MinGW-w64 gcc (MSVCRT)"
    Invoke-WebRequest -Uri $mingwMsvcrtUrl -OutFile $mingwCache -UseBasicParsing
    ok "Downloaded ($([math]::Round((Get-Item $mingwCache).Length/1MB,0)) MB) -- cached at $mingwCache"
    $mingwTmpZip = $mingwCache
}
info "Extracting MinGW-w64 gcc (selective)"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($mingwTmpZip)
$tc  = "$staging\toolchain"
# Exact-path entries: source -> destination
# x86_64-w64-mingw32-gcc.exe is the name flexlink uses with -chain mingw64;
# without it, flexlink falls back to the system gcc (Cygwin on CI) which
# misinterprets LIBRARY_PATH and fails to locate dllcrt2.o.
$exact = @{
    "mingw64/bin/gcc.exe"                    = "$tc\bin\gcc.exe"
    "mingw64/bin/x86_64-w64-mingw32-gcc.exe" = "$tc\bin\x86_64-w64-mingw32-gcc.exe"
    "mingw64/bin/as.exe"                     = "$tc\bin\as.exe"
    "mingw64/bin/ld.exe"                     = "$tc\bin\ld.exe"
    # Runtime DLLs required by the winlibs binutils (as.exe, ld.exe, gcc.exe).
    # These are NOT statically linked and are not present on a clean Windows install.
    # libwinpthread-1 / libgcc_s_seh-1 MUST come from winlibs (not opam/Cygwin):
    # as.exe and gcc.exe import libwinpthread-1.dll, and the opam build pulls in a
    # dependency missing on a clean box -> STATUS_DLL_NOT_FOUND. Single-source the
    # whole native runtime from winlibs so the set is internally consistent.
    "mingw64/bin/libintl-8.dll"         = "$tc\bin\libintl-8.dll"
    "mingw64/bin/libz.dll"              = "$tc\bin\libz.dll"
    "mingw64/bin/libzstd.dll"           = "$tc\bin\libzstd.dll"
    "mingw64/bin/libiconv-2.dll"        = "$tc\bin\libiconv-2.dll"
    "mingw64/bin/libwinpthread-1.dll"   = "$tc\bin\libwinpthread-1.dll"
    "mingw64/bin/libgcc_s_seh-1.dll"    = "$tc\bin\libgcc_s_seh-1.dll"
    "mingw64/lib/libgcc_s.a" = "$tc\x86_64-w64-mingw32\lib\libgcc_s.a"
    "mingw64/lib/gcc/x86_64-w64-mingw32/$mingwGccVer/libgcc.a"    = "$tc\lib\gcc\x86_64-w64-mingw32\$mingwGccVer\libgcc.a"
    "mingw64/lib/gcc/x86_64-w64-mingw32/$mingwGccVer/libgcc_eh.a" = "$tc\lib\gcc\x86_64-w64-mingw32\$mingwGccVer\libgcc_eh.a"
    "mingw64/libexec/gcc/x86_64-w64-mingw32/$mingwGccVer/liblto_plugin.dll" = "$tc\libexec\gcc\x86_64-w64-mingw32\$mingwGccVer\liblto_plugin.dll"
}
$libPrefix = "mingw64/x86_64-w64-mingw32/lib/"
$libDest   = "$tc\x86_64-w64-mingw32\lib"
$n = 0
$extracted = @{}
foreach ($entry in $zip.Entries) {
    $fullName = $entry.FullName
    if ($fullName.EndsWith('/')) { continue }
    if ($exact.ContainsKey($fullName)) {
        $destDir = Split-Path $exact[$fullName] -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force $destDir | Out-Null }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $exact[$fullName], $true)
        $extracted[$fullName] = $true
        $n++
    } elseif ($fullName.StartsWith($libPrefix)) {
        $rel  = $fullName.Substring($libPrefix.Length) -replace '/', '\'
        $dest = Join-Path $libDest $rel
        $ddir = Split-Path $dest -Parent
        if (-not (Test-Path $ddir)) { New-Item -ItemType Directory -Force $ddir | Out-Null }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        $n++
    }
}
$zip.Dispose()
foreach ($key in $exact.Keys) {
    if (-not $extracted.ContainsKey($key)) { die "Expected entry not found in MinGW zip: $key" }
}
ok "Extracted $n files (gcc/ld/as + x86_64-w64-mingw32/lib)"

# cygpath.bat shim: flexlink calls cygpath for path normalisation; this stub
# strips option flags and echoes the path argument unchanged (native Windows
# paths work as-is with the bundled flexlink).
@"
@echo off
:parse
if "%~1"=="-w" ( shift & goto parse )
if "%~1"=="-m" ( shift & goto parse )
if "%~1"=="-u" ( shift & goto parse )
if "%~1"=="-a" ( shift & goto parse )
if "%~1"=="-p" ( shift & goto parse )
if not "%~1"=="" echo %~1
"@ | Set-Content "$staging\toolchain\bin\cygpath.bat" -Encoding ASCII
ok "cygpath.bat"

###############################################################################
# OCaml stdlib, zarith, catala runtime and plugins
###############################################################################

info "Copying OCaml stdlib"
Copy-Item -Recurse -Force "$ocamlStdlib\*" "$staging\toolchain\lib\ocaml\"
$n = @(Get-ChildItem "$staging\toolchain\lib\ocaml" -Recurse -File).Count
if ($n -eq 0) { die "OCaml stdlib copy produced no files" }
ok "ocaml stdlib: $n files"

info "Copying zarith"
Copy-Item -Recurse -Force "$zarithDir\*" "$staging\toolchain\lib\zarith\"
$n = @(Get-ChildItem "$staging\toolchain\lib\zarith" -Recurse -File).Count
if ($n -eq 0) { die "zarith copy produced no files" }
ok "zarith: $n files"

$catalaRuntime = "$opamPrefix\lib\catala\runtime"
if (-not (Test-Path $catalaRuntime)) { die "Catala runtime not found at $catalaRuntime" }
info "Copying catala runtime"
Copy-Item -Recurse -Force "$catalaRuntime\*" "$staging\toolchain\lib\catala\runtime\"
$n = @(Get-ChildItem "$staging\toolchain\lib\catala\runtime" -Recurse -File).Count
if ($n -eq 0) { die "Catala runtime copy produced no files" }
ok "catala runtime: $n files"

$catalaPlugins = "$opamPrefix\lib\catala\plugins"
if (-not (Test-Path $catalaPlugins)) { die "No plugins dir at $catalaPlugins -- is catala-lsp installed?" }
info "Copying catala plugins"
Get-ChildItem $catalaPlugins -Filter "*.cmxs" | ForEach-Object {
    Copy-Item $_.FullName "$staging\toolchain\lib\catala\plugins\"
}
foreach ($req in @("testcase.cmxs")) {
    if (-not (Test-Path "$staging\toolchain\lib\catala\plugins\$req")) {
        die "Required plugin $req missing from $catalaPlugins -- is catala-lsp installed?"
    }
}
$pluginNames = (Get-ChildItem "$staging\toolchain\lib\catala\plugins" | Select-Object -ExpandProperty Name) -join ', '
ok "plugins: $pluginNames"

"" | Set-Content "$staging\toolchain\lib\findlib.conf"   # relocated-switch marker

###############################################################################
# Wrapper scripts  (bin\*.cmd  ->  toolchain\bin\*.exe)
###############################################################################

info "Generating wrapper scripts"

function Write-OcamlWrapper([string]$name) {
    $script = @"
@echo off
:: catala bundle wrapper for $name
setlocal
for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "TC=%BASE%\toolchain"
set "CATALA_OCAML_LIBDIR=%TC%\lib"
set "OCAMLLIB=%TC%\lib\ocaml"
set "NINJA_BIN=%TC%\bin\ninja.exe"
if not defined CATALA_PLUGINS set "CATALA_PLUGINS=%TC%\lib\catala\plugins"
set "LIBRARY_PATH=%TC%\x86_64-w64-mingw32\lib"
set "FLEXLINKFLAGS=-L%TC%\lib\ocaml\flexdll"
set "PATH=%TC%\bin;%PATH%"
"%TC%\bin\$name.exe" %*
exit /b %ERRORLEVEL%
"@
    $script | Set-Content "$staging\bin\$name.cmd" -Encoding ASCII
    ok "$name.cmd"
}

Write-OcamlWrapper "catala"
Write-OcamlWrapper "clerk"
Write-OcamlWrapper "catala-lsp"
Write-OcamlWrapper "catala-dap"
@"
@echo off
:: catala bundle wrapper for catala-format
setlocal
for %%I in ("%~dp0..") do set "BASE=%%~fI"
set "TC=%BASE%\toolchain"
set "XDG_CACHE_HOME=%TC%\share"
set "PATH=%TC%\bin\.topiary-wrapped;%TC%\bin;%PATH%"
"%TC%\bin\catala-format.exe" %*
exit /b %ERRORLEVEL%
"@ | Set-Content "$staging\bin\catala-format.cmd" -Encoding ASCII
ok "catala-format.cmd"

###############################################################################
# Helper scripts (libexec)
###############################################################################

# defender.ps1: drives the opt-in Windows Defender-exclusion custom action of
# the MSI, and can also be run standalone later to (re)apply or remove the
# exclusions. Copied verbatim into libexec.
$defenderSrc = Join-Path $PSScriptRoot "defender.ps1"
if (-not (Test-Path $defenderSrc)) { die "defender.ps1 not found at $defenderSrc" }
New-Item -ItemType Directory -Force "$staging\toolchain\libexec" | Out-Null
Copy-Item $defenderSrc "$staging\toolchain\libexec\defender.ps1"
ok "defender.ps1"

# install-vscode-extension.cmd: installs the bundled .vsix into VS Code. Sits at
# the bundle root next to the .vsix; the MSI wires a Start Menu shortcut to it.
# (The MSI can't do this itself: a per-machine install runs as SYSTEM, but
# extensions install per-user, so the user runs this from the Start Menu.)
@'
@echo off
setlocal
set "VSIX="
for %%F in ("%~dp0catala-*.vsix") do set "VSIX=%%~fF"
if not defined VSIX (
  echo No Catala .vsix found next to this script.
  pause & exit /b 1
)
where code >nul 2>nul || (echo VS Code 'code' command not found on PATH -- install VS Code first. & pause & exit /b 1)
echo Installing the Catala VS Code extension from:
echo   %VSIX%
call code --install-extension "%VSIX%"
echo.
echo Done. Restart VS Code to activate the extension.
pause
'@ | Set-Content "$staging\install-vscode-extension.cmd" -Encoding ASCII
ok "install-vscode-extension.cmd"

###############################################################################
# VSIX
###############################################################################

if ($vsixSrc) {
    info "Including $(Split-Path -Leaf $vsixSrc)"
    Copy-Item $vsixSrc $staging
    if ($lspCloned) { Remove-Item -Recurse -Force $lspRepo -ErrorAction SilentlyContinue }
}

###############################################################################
# Smoke-test as.exe from the bundle directory
# (validates DLL deps are present -- if any are missing, as.exe exits with
#  STATUS_DLL_NOT_FOUND and ocamlopt -backend=ocaml would silently fail for users)
###############################################################################

info "Smoke-testing as.exe (DLL self-containment check)"
$asExe = "$staging\toolchain\bin\as.exe"
if (-not (Test-Path $asExe)) { die "as.exe not found in bundle at $asExe" }
$asOut = & $asExe --version 2>&1
if ($LASTEXITCODE -ne 0) {
    die "as.exe --version failed (exit $LASTEXITCODE) -- likely missing DLL. Output: $asOut"
}
ok "as.exe: $($asOut | Select-Object -First 1)"

###############################################################################
# Manifest check: verify all critical staged contents are present
###############################################################################

info "Verifying staged manifest"
$stagedNames = @(Get-ChildItem $staging -Recurse -File | Select-Object -ExpandProperty Name)

$required = @{
    "Core binaries"   = @("catala.exe","clerk.exe","catala-lsp.exe","catala-dap.exe",
                          "catala-format.exe","topiary.exe","ocamlopt.exe","flexlink.exe",
                          "gcc.exe","ld.exe","as.exe","ninja.exe")
    "Runtime DLLs"    = @("libgmp-10.dll","libgcc_s_seh-1.dll","libwinpthread-1.dll",
                          "libiconv-2.dll","libintl-8.dll","libz.dll","libzstd.dll")
    "Wrappers"        = @("catala.cmd","clerk.cmd","catala-lsp.cmd","catala-dap.cmd",
                          "catala-format.cmd")
    "Helper scripts"  = @("defender.ps1")
    "Catala plugins"  = @("explain.cmxs","lazy_interpreter.cmxs","python.cmxs","testcase.cmxs")
    "Flexdll objects" = @("flexdll_initer_mingw64.o","flexdll_mingw64.o")
    "VSIX"            = @("catala-$version.vsix")
}

$allOk = $true
foreach ($section in $required.Keys) {
    foreach ($f in $required[$section]) {
        if ($stagedNames -notcontains $f) {
            warn "MISSING from bundle [$section]: $f"
            $allOk = $false
        }
    }
}
if (-not $allOk) { die "Bundle is incomplete -- see warnings above" }
ok "Manifest check passed"

###############################################################################
# Import-closure check: parse every staged .exe/.dll and require each imported
# DLL to be bundled or a known system DLL. Host-independent (the as.exe smoke
# test can pass on a dirty build box) -- the real clean-machine self-containment
# gate. Skips .cmxs (flexdll resolves those against the loader, not by import).
###############################################################################

# Pure-PowerShell PE import-table parser (no dumpbin/objdump dependency).
function Get-PeImports([string]$path) {
    try { $b = [IO.File]::ReadAllBytes($path) } catch { return @() }
    if ($b.Length -lt 64 -or $b[0] -ne 0x4D -or $b[1] -ne 0x5A) { return @() }   # 'MZ'
    $pe = [BitConverter]::ToInt32($b, 0x3C)
    if ($pe -lt 0 -or ($pe + 24) -ge $b.Length) { return @() }
    if ($b[$pe] -ne 0x50 -or $b[$pe + 1] -ne 0x45) { return @() }                # 'PE'
    $coff = $pe + 4
    $numSec  = [BitConverter]::ToUInt16($b, $coff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coff + 16)
    $opt = $coff + 20
    $magic = [BitConverter]::ToUInt16($b, $opt)
    $ddOff = if ($magic -eq 0x20B) { $opt + 112 } else { $opt + 96 }   # PE32+ vs PE32
    $impRva = [BitConverter]::ToUInt32($b, $ddOff + 8)                 # data dir index 1
    if ($impRva -eq 0) { return @() }
    $secOff = $opt + $optSize
    $rva2off = {
        param($rva)
        for ($i = 0; $i -lt $numSec; $i++) {
            $s  = $secOff + $i * 40
            $vs = [BitConverter]::ToUInt32($b, $s + 8)
            $va = [BitConverter]::ToUInt32($b, $s + 12)
            $rs = [BitConverter]::ToUInt32($b, $s + 16)
            $pr = [BitConverter]::ToUInt32($b, $s + 20)
            $sz = [Math]::Max($vs, $rs)
            if ($rva -ge $va -and $rva -lt ($va + $sz)) { return ($pr + ($rva - $va)) }
        }
        return 0
    }
    $impOff = & $rva2off $impRva
    if ($impOff -le 0) { return @() }
    $names = New-Object System.Collections.Generic.List[string]
    $e = $impOff
    while (($e + 20) -le $b.Length) {
        $nameRva = [BitConverter]::ToUInt32($b, $e + 12)
        $oft = [BitConverter]::ToUInt32($b, $e + 0)
        $ft  = [BitConverter]::ToUInt32($b, $e + 16)
        if ($nameRva -eq 0 -and $oft -eq 0 -and $ft -eq 0) { break }
        if ($nameRva -ne 0) {
            $no = & $rva2off $nameRva
            if ($no -gt 0 -and $no -lt $b.Length) {
                $sb = New-Object System.Text.StringBuilder
                $p = $no
                while ($p -lt $b.Length -and $b[$p] -ne 0) { [void]$sb.Append([char]$b[$p]); $p++ }
                if ($sb.Length -gt 0) { $names.Add($sb.ToString()) }
            }
        }
        $e += 20
    }
    return $names
}

info "Verifying DLL import closure (self-containment)"
# The OS DLLs the bundle actually imports (empirical: union of non-bundled imports
# across the staged tree), all core System32 components on every supported Windows.
# Not an authoritative MS manifest -- expand only when a *reviewed* build adds one.
$systemDlls = @(
    'kernel32.dll','ntdll.dll','advapi32.dll','msvcrt.dll','bcryptprimitives.dll',
    'ole32.dll','oleaut32.dll','shell32.dll','shlwapi.dll','version.dll','ws2_32.dll'
)
$peFiles = Get-ChildItem $staging -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' }
$bundledDll = @{}
foreach ($f in $peFiles) { $bundledDll[$f.Name.ToLower()] = $true }
$closureViol = New-Object System.Collections.Generic.List[string]
foreach ($f in $peFiles) {
    foreach ($imp in (Get-PeImports $f.FullName)) {
        $low = $imp.ToLower()
        if ($bundledDll.ContainsKey($low)) { continue }
        if ($systemDlls -contains $low) { continue }
        if ($low -like 'api-ms-win-*' -or $low -like 'ext-ms-*') { continue }   # OS API sets
        $closureViol.Add(("{0} -> {1}" -f $f.Name, $imp))
    }
}
if ($closureViol.Count -gt 0) {
    $closureViol | Sort-Object -Unique | ForEach-Object { warn "  unresolved import: $_" }
    die ("Import-closure check failed: $($closureViol.Count) import(s) resolve to neither a " +
         "bundled nor a system DLL -- the bundle is not self-contained. Add the missing DLL(s) " +
         "(from winlibs where possible), or extend `$systemDlls if the import is genuinely OS-provided.")
}
ok "import closure: $($peFiles.Count) PE files, all imports resolved"

###############################################################################
# Build the MSI with WiX
###############################################################################

Require-Cmd wix

# MSI ProductVersion must be numeric (up to 4 dot-separated fields); strip any
# pre-release suffix from the catala version (e.g. "0.11.0~beta" -> "0.11.0").
$msiVersion = [regex]::Match($version, '^\d+(\.\d+){0,3}').Value
if (-not $msiVersion) { die "Could not derive a numeric MSI version from '$version'" }

info "Building MSI (WiX) version $msiVersion"
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$msiPath = Join-Path (Resolve-Path $OutputDir) "$bundleName.msi"
Remove-Item $msiPath -ErrorAction SilentlyContinue

$wxs = Join-Path $PSScriptRoot "wix\Catala.wxs"
if (-not (Test-Path $wxs)) { die "WiX source not found at $wxs" }
$stagingFull = (Resolve-Path $staging).Path

& wix build $wxs `
    -ext WixToolset.Util.wixext `
    -ext WixToolset.UI.wixext `
    -arch x64 `
    -d "Version=$msiVersion" `
    -d "Scope=$Scope" `
    -d "StageDir=$stagingFull" `
    -o $msiPath
if ($LASTEXITCODE -ne 0) { die "wix build failed (exit $LASTEXITCODE)" }
if (-not (Test-Path $msiPath)) { die "wix build reported success but $msiPath is missing" }

$hash = (Get-FileHash $msiPath -Algorithm SHA256).Hash.ToLower()
"$hash  $bundleName.msi" | Set-Content "$msiPath.sha256"

$sizeMB = [math]::Round((Get-Item $msiPath).Length / 1MB, 1)
info "MSI ready: $msiPath ($sizeMB MB)"
Write-Host "SHA256: $hash"

Remove-Item -Recurse -Force (Split-Path -Parent $staging) -ErrorAction SilentlyContinue
