<#
.SYNOPSIS
  Write catala.ncl so topiary loads the bundled prebuilt grammars by absolute path.

.DESCRIPTION
  Topiary's `grammar.source.path` (>= 0.6, PR #747) needs an absolute path, known
  only at install time and scope-dependent. Runs as a WiX deferred custom action to
  point catala.ncl at the shipped grammar .dlls. Without it, catala-format falls back
  to fetching+compiling the grammar from git on first run (needs git + a C compiler),
  which a clean end-user machine lacks.

.PARAMETER InstallDir
  Install root ([INSTALLFOLDER]). Trailing backslash and (from MSI quoting) a stray
  trailing quote are both stripped.
#>
param([Parameter(Mandatory = $true)][string]$InstallDir)

$ErrorActionPreference = 'Stop'

# [INSTALLFOLDER] ends with '\', and CA command-line quoting can append a stray '"'.
$InstallDir = $InstallDir.TrimEnd('"').TrimEnd('\')

$grammarsDir = (Join-Path $InstallDir 'toolchain\share\topiary\grammars')
$nclPath     = (Join-Path $InstallDir 'toolchain\share\topiary\configs\catala.ncl')

# Forward slashes: backslashes aren't valid Nickel escapes (Windows accepts '/').
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
