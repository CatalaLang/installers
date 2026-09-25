# Developer notes

This repo packages the Catala toolchain as a Windows MSI (Windows-only).

## Layout

```
build-bundle.ps1        stage the toolchain + build the MSI (run on Windows)
test-clean-install.ps1  manual clean-machine MSI validation (hides opam, asserts no leakage)
wix/Catala.wxs          WiX v5 MSI authoring
wix/license.rtf         license shown by the installer UI
helpers/                scripts shipped inside the bundle
.github/workflows/ci.yml             resolve the bundle in the opam repo, build, test, stage a draft
.github/workflows/publish.yml        stage a CI artifact as a private draft (called by ci.yml)
.github/workflows/verify.yml            verify the signed candidate (still private)
.github/workflows/promote.yml           draft → public candidate → release
tests/                  fixtures for the CI tests
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
then **test** the same bytes on two installs, default (`C:\ProgramData\Catala`) and
spaced+accented (`C:\Program Files\Catala accentué`): smoke checks, catala-format
unicode roundtrip, `clerk test` on catala-examples (interpreter; ocaml, java, python
backends; an accented project dir), an external OCaml module with a test-count
assertion, uninstall + assert clean. The C backend step is **expected to fail** (no C
toolchain in the bundle yet) and turns red the day it passes. `workflow_dispatch`
inputs pin `catala_rev` / `catala_format_rev` / `catala_lsp_rev` (full SHAs, tags or
branches). The `bundle-windows` artifact (MSI + `.sha256`) is kept 30 days.

## Releasing

The recipe is the Catala opam repository (https://catala.gitlabpages.inria.fr/opam-repository).
A release bundles `catala-full.<version>` as resolved there; a testing build bundles the
`testing` channel (the three components at the commits the team pinned). CI records every
resolved SHA in `manifest.json` inside the MSI. Nothing is rebuilt after CI, and no unsigned
MSI is ever public. Flow: `docs/release-flow.dot` (`dot -Tsvg` to view).

| | Testing build | Release |
|---|---|---|
| CI input `catala_full` | blank | `1.2.1` |
| Name (tag and MSI) | `1.3.0-testing.20260925` (next version + day) | `1.2.1` |
| Manual pass, on the public candidate | short | full (~2 h, metal box) |
| Promoted to | candidate | candidate, then release (Latest) |

1. **CI** → *Run workflow* → `catala_full` (or blank). Builds, tests the MSI on a default
   and a spaced+accented install, stages a **private draft** named as above.
2. **Sign**: GitLab `catala-signature` → *Run pipeline* on `main`, start the manual `sign`
   job (`TAG` = the draft; default: the newest pending). Signs, swaps the signed MSI in,
   dispatches *Verify candidate* here, which checks checksum, signature chain, install +
   version, uninstall, and records provenance in the notes. Still a draft.
3. **Promote candidate** → `tag`, `to` = candidate: public pre-release. Test it by hand
   (the table below), let others test it. Bad: `gh release delete <tag> --yes --cleanup-tag`.
4. **Release only**: **Promote candidate** → `to` = release. Same bytes, flagged Latest.

Ad-hoc builds: set any `*_rev` input (master, a branch, a full SHA). Named
`<ver>-dev.<date>`, kept 30 days as a CI artifact, never staged or signed. To sign one
anyway, stage it with *Publish installer release* and its run id.

Rules of thumb: sign what you intend to put in front of testers, nothing else; one pending
draft at a time; `catala.opam` on catala master is bumped to the next version right after
each release (testing builds are named after it); a re-bundle of a released version is
`1.2.1+2`. Windows compares only the numeric version and accepts any upgrade or downgrade.
`gh release edit <tag> --draft=true` hides a published release at once.

## Relation to the catala repo

Builds against catala `master` (the Windows clerk fixes landed in 1.2.1+). The bundled
libs are found via an empty `findlib.conf` marker (not `CATALA_OCAML_LIBDIR`).
