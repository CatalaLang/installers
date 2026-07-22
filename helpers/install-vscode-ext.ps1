param([string]$InstallDir)
$ErrorActionPreference = "SilentlyContinue"
# Derive from the script location: the MSI CA passes no -InstallDir, because
# "[INSTALLFOLDER]" ends in a backslash and "\"" escapes the closing quote.
if (-not $InstallDir) { $InstallDir = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path }
$vsix = Get-ChildItem (Join-Path $InstallDir "catala-*.vsix") | Select-Object -First 1
if (-not $vsix) { Write-Output "No Catala .vsix found; skipping."; exit 0 }
function Install-Into($codeExe, $extDir) {
  if ($extDir) { & $codeExe --install-extension "$($vsix.FullName)" --extensions-dir "$extDir" --force 2>&1 | Write-Output }
  else         { & $codeExe --install-extension "$($vsix.FullName)" --force 2>&1 | Write-Output }
}
# When the CA runs with the user environment (interactive install), code is on
# PATH or in the current user LOCALAPPDATA; a plain install lands in the right
# profile.
$g = (Get-Command code -ErrorAction SilentlyContinue).Source
if ($g) { Install-Into $g $null; exit 0 }
foreach ($p in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
                 "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
                 "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd")) {
  if (Test-Path $p) { Install-Into $p $null; exit 0 }
}
# Fallback: a SYSTEM-ish CA environment. Search real user profiles and install
# explicitly into that user's extensions dir.
$any = $false
Get-ChildItem C:\Users -Directory -ErrorAction SilentlyContinue | ForEach-Object {
  $c = Join-Path $_.FullName "AppData\Local\Programs\Microsoft VS Code\bin\code.cmd"
  if (Test-Path $c) { $any = $true; Install-Into $c (Join-Path $_.FullName ".vscode\extensions") }
}
if (-not $any) { Write-Output "VS Code not found; skipping extension install." }
exit 0
