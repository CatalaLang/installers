# Developer notes

This repo packages the Catala toolchain as a Windows MSI (Windows-only).

## Layout

```
build-bundle.ps1        stage the toolchain + build the MSI (run on Windows)
test-clean-install.ps1  manual clean-machine MSI validation (hides opam, asserts no leakage)
wix/Catala.wxs          WiX v5 MSI authoring
wix/license.rtf         license shown by the installer UI
helpers/                scripts shipped inside the bundle
.github/workflows/ci.yml             build + install/test matrix on windows-latest
.github/workflows/publish.yml        promote a vetted CI artifact to a draft release
.github/workflows/verify-publish.yml verify the signed MSI, un-draft
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

Releases are **promoted from a vetted CI build**, never rebuilt (no opam lockfile:
a rebuild may resolve different dependencies). The published `.msi` is byte-for-byte
what was tested, plus the signature.

Two kinds, one pipeline:

| | Pre-release (testing) | Release |
|---|---|---|
| Bundles | catala `master` (or any SHA) | a catala opam release, by its tag |
| Tag | blank ⇒ `windows-testing-YYYY.MM.DD-<catala-sha>` | `v<version>`, checked against the MSI |
| GitHub | pre-release flag | latest |
| Manual pass | short (~30 min) | full (~2 h, metal box) |

Steps:

1. **Build.** Push to `main`, or `workflow_dispatch` on `ci.yml` with the refs to bundle.
   Wait for green. Note the run id (`…/actions/runs/<run_id>`).
2. **Vet.** Download `bundle-windows` from the run and do the manual pass (VS Code
   extension, LSP, test explorer, upgrade over an install, offline formatting — what CI
   can't do). Copy the MSI locally first; `msiexec` off a share fails with error 110.
3. **Stage.** Actions → *Publish installer release* → run with `run_id`, the tag (or blank),
   `prerelease`, and `draft` left on. This creates a **draft** carrying
   `catala-<ver>-windows-x86_64-<sha>-unsigned.msi` + `.sha256`. Drafts are invisible to
   the public; an unsigned MSI must never be.
4. **Sign.** On the internal GitLab project `catala-signature`, *Run pipeline* and start
   the manual `sign` job. It finds the pending draft (or the one named in its `TAG`
   variable), signs the MSI (INRIA certificate, timestamped), uploads the signed MSI and a
   fresh `.sha256`, deletes the unsigned MSI, and dispatches *Verify and publish* here.
   It never edits the release itself.
5. **Verify and publish** runs on its own (windows-latest): checksum, Authenticode chain
   (Valid, signer INRIA, timestamp present), silent install + `catala --version`,
   uninstall, then appends the provenance line (date, sign pipeline, both digests) to the
   notes and un-drafts. Red means nothing went public: read the log, fix, re-run the sign
   job after deleting the signed asset from the draft.
6. **Confirm** from the public URL on a clean box: `Get-FileHash` against the published
   `.sha256`, install once.

One pending draft at a time: the sign job discovers work by the `-unsigned` suffix.

**If something is wrong after publishing:** `gh release edit <tag> --draft=true` hides it
immediately (reversible); `gh release delete <tag> --yes --cleanup-tag` withdraws it. Then
re-cut from step 1. Never patch a published release in place.

**Versioning:** the MSI ProductVersion is the **catala compiler version** as read from
`catala.opam` at the bundled commit (users think "catala toolchain 1.x"); the filename
carries the catala short-sha so two builds of one version are distinguishable;
`manifest.json` inside the install is the source of truth for every component SHA.
Installer-only fixes ship as new pre-releases of the same catala version.

## Relation to the catala repo

Builds against catala `master` (the Windows clerk fixes landed in 1.2.1+). The bundled
libs are found via an empty `findlib.conf` marker (not `CATALA_OCAML_LIBDIR`).
