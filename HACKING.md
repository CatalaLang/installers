# Developer notes

This repo packages the Catala toolchain as a Windows MSI (Windows-only).

## Layout

```
build-bundle.ps1        stage the toolchain + build the MSI (run on Windows)
defender.ps1            opt-in Defender-exclusion script (shipped + driven by the MSI)
test-clean-install.ps1  manual clean-machine MSI validation (hides opam, asserts no leakage)
wix/Catala.wxs          WiX v5 MSI authoring
wix/license.rtf         license shown by the installer UI
DESIGN.md               architecture
.github/workflows/ci.yml   build + clean-install test on windows-latest
tests/                  fixtures for the clean-install test
```

## Building the MSI

Needs a Windows machine with an opam switch holding the full Catala toolchain
(see DESIGN.md → Build inputs), `ninja` on PATH, and the WiX dotnet tool **pinned
to v5** (v6+/v7 require accepting the OSMF EULA — WIX7015 — which blocks
unattended builds):

```powershell
dotnet tool install --global wix --version 5.0.2
wix extension add -g WixToolset.Util.wixext/5.0.2
wix extension add -g WixToolset.UI.wixext/5.0.2
```

Then, from the **catala repository root** (the script reads `catala.opam` and the
opam switch there):

```powershell
$env:PATH = "$(opam var bin);$env:PATH"
powershell -ExecutionPolicy Bypass -File ..\installers\build-bundle.ps1 -LspPath ..\catala-language-server
```

It stages the binaries + OCaml runtime + a selective MinGW-w64 gcc, generates the
`bin\*.cmd` wrappers, copies `defender.ps1`, verifies a file manifest and a static
import-closure self-containment check, then runs `wix build` to produce
`_bundle\catala-<version>-windows-x86_64.msi` (+ `.sha256`).

Useful parameters: `-Scope perMachine|perUser` (default perMachine), `-MingwZip <path>` (skip the
winlibs download), `-LspPath <checkout>` / `-LspRef <ref>` (VS Code extension
source), `-OutputDir`.

## Testing an install

```powershell
msiexec /i _bundle\catala-*.msi /qn /l*v install.log     # per-machine (run elevated)
$base = "C:\ProgramData\Catala"
& "$base\bin\catala.cmd" --version
(Get-Command catala).Source     # should resolve to $base\bin
```

`test-clean-install.ps1` does a fuller clean-machine check: it moves the opam root
aside and scrubs PATH first, so it catches tools leaking in from a dev's own opam.

Uninstall: `msiexec /x _bundle\catala-*.msi /qn` (also removes the PATH entry and
any Defender exclusions the installer added).

## CI

`.github/workflows/ci.yml` (windows-latest): **build** (set up opam, build catala
+ catala-format + catala-lsp, install WiX, run `build-bundle.ps1`, upload the MSI),
then **test** (silent install, smoke checks + catala-format unicode roundtrip,
`clerk test` against catala-examples, uninstall + assert clean). `workflow_dispatch`
inputs pin `catala_rev` / `catala_format_rev` / `catala_lsp_rev`.

## Relation to the catala repo

Depends on the catala branch `clerk-ocaml-libdir` — a few Windows fixes for clerk
(notably `CATALA_OCAML_LIBDIR`, so clerk finds the bundled libs at a non-standard
path; plus path-quoting and CRLF test-output fixes), being upstreamed. Once merged,
this repo builds against catala `master`.
