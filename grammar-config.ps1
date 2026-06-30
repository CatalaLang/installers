<#
.SYNOPSIS
  Write catala.ncl so topiary loads the bundled prebuilt grammars by absolute path.

.DESCRIPTION
  The MSI ships prebuilt tree-sitter grammar .dlls (catala_{en,fr,pl}.dll) plus a
  git-source catala.ncl. Topiary's `grammar.source.path` (a >= 0.6 feature, PR #747)
  needs an absolute path, which is only known at install time and differs per scope
  (C:\ProgramData\Catala vs %LOCALAPPDATA%\Programs\Catala). So this runs as a WiX
  deferred custom action after the files are laid down, and rewrites catala.ncl in
  place to point at <InstallDir>\toolchain\share\topiary\grammars\<lang>.dll.

  Without this, catala-format would fall back to fetching+compiling the grammar from
  git on first run (needs git + a C compiler), which a clean end-user machine lacks.

.PARAMETER InstallDir
  The install root ([INSTALLFOLDER]). May arrive with a trailing backslash (and, due
  to MSI command-line quoting, a stray trailing quote) -- both are stripped.
#>
param([Parameter(Mandatory = $true)][string]$InstallDir)

$ErrorActionPreference = 'Stop'

# [INSTALLFOLDER] ends with '\'; inside "..." on the CA command line that can leave a
# trailing '"' too. Strip both so Join-Path is clean.
$InstallDir = $InstallDir.TrimEnd('"').TrimEnd('\')

$grammarsDir = (Join-Path $InstallDir 'toolchain\share\topiary\grammars')
$nclPath     = (Join-Path $InstallDir 'toolchain\share\topiary\configs\catala.ncl')

# Nickel embeds these in `import "..."`; backslashes aren't valid Nickel escapes, and
# forward slashes are accepted by Windows APIs.
$gdir = $grammarsDir -replace '\\', '/'

$langs = @('catala_en', 'catala_fr', 'catala_pl')
$lines = @('{', '  languages = {')
foreach ($lang in $langs) {
    $lines += "    $lang = { extensions = [`"$lang`", `"$lang.md`"], grammar.source.path = `"$gdir/$lang.dll`" },"
}
$lines[-1] = $lines[-1].TrimEnd(',')   # no trailing comma on the last entry
$lines += @('  }', '}')

# -Force: catala.ncl is shipped read-only (copied from the opam switch).
Set-Content -Path $nclPath -Value $lines -Encoding ascii -Force
Write-Host "grammar-config: wrote $nclPath -> $gdir"
