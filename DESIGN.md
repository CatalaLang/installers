# Design

These installers package the Catala toolchain as a self-contained Windows MSI —
a complete snapshot, with no opam or network resolution at install time.

## Overview

Two stages, both run on Windows (the CI `windows-latest` runner, or a dev box):

1. **Stage** (`build-bundle.ps1`): assemble a relocatable toolchain tree from an
   opam switch + a pinned MinGW-w64 gcc, plus the VS Code `.vsix` and its
   installer helper.
2. **Package** (`wix/Catala.wxs`, WiX dotnet tool): harvest that tree into an MSI.

Output: `catala-<version>-windows-x86_64.msi` (+ `.sha256`).

## Installed layout

```
Catala/
  bin/                 wrapper scripts added to PATH (catala/clerk/lsp/dap/format)
  toolchain/           actual binaries + data (not on PATH directly)
    bin/               catala/clerk/ocamlopt/ninja/flexlink, gcc/ld/as, ...
    lib/               ocaml stdlib, zarith, catala runtime + plugins, gcc libs
    libexec/           gcc internals, defender.ps1, install-vscode-ext.ps1
                       (non-interactive .vsix installer, run by the MSI custom action)
    share/topiary/     queries + configs + prebuilt grammars (.dll)
    x86_64-w64-mingw32/lib/   import libs for linking
  catala-<version>.vsix
  install-vscode-extension.cmd   interactive .vsix installer (Start-Menu shortcut target)
```

The `bin\*.cmd` wrappers compute their own location (`%~dp0..`) and set
`OCAMLLIB`, `NINJA_BIN`, `CATALA_PLUGINS`, `LIBRARY_PATH`, `FLEXLINKFLAGS` and
`PATH` (with `setlocal` isolation, so they don't disturb a developer's own opam)
before exec-ing the real binary. The bundled OCaml libs are located via an empty
`findlib.conf` marker in the tree, not a `CATALA_OCAML_LIBDIR` env var. The tree is
fully relocatable; the MSI only has to add `bin\` to PATH.

## Install model

- **Two scopes, chosen at build time (`-Scope`):** *per-machine* (default, the
  shipped MSI) → `C:\ProgramData\Catala`, system PATH, elevated, for IT push
  (Intune/GPO); *per-user* → `%LOCALAPPDATA%\Programs\Catala`, user PATH, no admin
  (for machines without local admin). Both default to space-free roots, but an
  install dir **with** spaces now works too: the two layers that broke it are fixed
  — the bundle wrapper quotes its `-L` flexlink flag, and clerk quotes the exe
  paths in its generated ninja commands (catala `clerk-windows-fixes`).
- **PATH** is managed via the MSI `Environment` table (added on install, removed
  on uninstall). **Upgrades** use `MajorUpgrade` (newer replaces older; downgrades
  blocked). **Uninstall** via Add/Remove Programs or `msiexec /x`.
- **VS Code extension** is an optional, default-on feature (`WixUI_FeatureTree`
  checkbox). When ticked, a deferred **impersonated** custom action runs
  `install-vscode-ext.ps1` (`code --install-extension`) so the extension lands in
  the *invoking user's* VS Code even though a per-machine MSI runs as SYSTEM;
  `Return="ignore"` makes it non-fatal when VS Code is absent. A Start-Menu
  shortcut to `install-vscode-extension.cmd` is the manual fallback. The extension
  is **not** removed on uninstall (VS Code owns its own extension lifecycle).
- Shipped helper scripts: `defender.ps1`, `install-vscode-ext.ps1` (in
  `toolchain\libexec`) and `install-vscode-extension.cmd` (at the install root).

## Self-containment

The native toolchain is single-sourced from one winlibs release; only `libgmp`
comes from the opam/Cygwin sysroot (itself a mingw-native build — no
`cygwin1.dll`). A static **import-closure check** over every staged `.exe`/`.dll`
fails the build if an imported DLL is neither bundled nor a known Windows system
DLL — so a half-resolved toolchain (the cause of past `STATUS_DLL_NOT_FOUND` on
clean boxes) can't ship.

## Code formatting (catala-format / topiary)

`catala-format` is a thin wrapper that drives the `topiary` binary, which parses
Catala with a **tree-sitter grammar**. Out of the box topiary *fetches that grammar
from git and compiles it with a C compiler on first use* (cached under
`%LOCALAPPDATA%\topiary`). On a clean end-user machine — no git, no compiler, and
the bundled gcc is a partial (cc1-less) subset — that first run **fails**
(`Error Fetching Language: Git error: program not found`). It only appears to work
on a dev box because the cache was populated earlier.

So at **build time** (where git + a real mingw gcc are present) we compile the three
grammars (`catala_{en,fr,pl}`) once and ship the `.dll`s in
`toolchain\share\topiary\grammars\`. At runtime topiary loads them via
`grammar.source.path` instead of fetching git — so the end-user machine needs neither
git nor a C compiler. The grammars only import `kernel32`/`msvcrt`, so they pass the
import-closure check. The `.dll` is pinned to the same grammar `rev` as the query.

`grammar.source.path` is a topiary **≥ 0.6.0** feature (v0.6.0 "Gilded Ginkgo",
2025-01-30; [PR #747](https://github.com/tweag/topiary/pull/747), *"Added support for
specifying paths to prebuilt grammars in Topiary's configuration"*). It does not exist
in 0.5.x — that is the concrete reason catala-format moved to topiary 0.6 (0.6.0 is
also the last 0.6.x on opam). 0.6 also changed grammar building to `tree-sitter-loader`
([#830](https://github.com/tweag/topiary/pull/830)) and config priority
([#790](https://github.com/tweag/topiary/pull/790)).

**The `source.path` is absolute and only known at install time** (it differs per
scope: `C:\ProgramData\Catala` vs `%LOCALAPPDATA%\Programs\Catala`), so we do **not**
bake it at build time. `build-bundle.ps1` ships the `.dll`s plus the unmodified
git-source `catala.ncl`; a WiX **deferred custom action** (`grammar-config.ps1`, run
after `InstallFiles`) rewrites `catala.ncl` in place with the real `[INSTALLFOLDER]`
path. This works for **both** scopes (and avoids a build-time hardcoded path, which
would be fragile and wrong for per-user). catala-format itself stays
platform-agnostic — it just reads whatever `catala.ncl` it finds next to the binary
(`<exec_dir>/../share/topiary/configs/`); the obsolete Windows-specific
`%LOCALAPPDATA%\Catala` lookup (which assumed a topiary *fork* with a built-in config)
was removed. On Linux/opam the shipped git-source `catala.ncl` is used unchanged.

## Windows Defender exclusions

Defender's real-time scanning of the per-module native compile storm
(ocamlopt → flexlink → gcc → ld → as, heavy `.o`/`.cmx`/`.cmxs` I/O) measurably
slows `clerk test` (~25–30 % on the cold full build here, more on weak machines).

Exclusions are **opt-in** (`TUNE_DEFENDER=1`), **scoped** (install dir + full-path
process exclusions for the bundled compilers — not a global disable), and
**reversible** (removed on uninstall). They need elevation, so `defender.ps1`
self-elevates via one UAC prompt and is **non-fatal**: if declined or
policy-locked, it prints the exclusion list for IT to push via GPO/Intune and the
install still succeeds. In the MSI it's a deferred custom action gated on
`TUNE_DEFENDER=1`, with a registry marker so uninstall only removes what was added.

## Build inputs

- **opam switch** with `catala`, `clerk`, `catala-lsp`, `catala-dap`,
  `catala-format` (+ topiary), `zarith`, `ninja`, OCaml 5.x (system-mingw).
- **MinGW-w64 gcc, MSVCRT variant** from a pinned
  [winlibs](https://github.com/brechtsanders/winlibs_mingw) release — MSVCRT (not
  UCRT) links `msvcrt.dll`, always present on Windows; UCRT DLLs may be absent on
  clean machines. Only the ~16 MB flexlink needs is extracted (not the ~260 MB zip).
- A **catala build with the Windows fixes** (branch `clerk-windows-fixes`):
  drive-case path relativization, valid `file://` URLs, and quoting of exe paths in
  the generated ninja (spaces-in-install-dir). The bundled OCaml libs are located
  via an empty **`findlib.conf`** marker in the tree (not the old
  `CATALA_OCAML_LIBDIR` env var). Pending upstream.

## Constraints

- **External OCaml modules:** programs depending on arbitrary opam packages can't
  be compiled with the bundle — that audience uses a real opam install.
- **catala opam repo:** `gitlab.inria.fr/catala/opam-repository` is needed to
  install `catala-lsp` / current `catala-format` (not on opam.ocaml.org).

## Open / not yet built

- **Defender UI checkbox** — `TUNE_DEFENDER` is still command-line only. The UI is
  now `WixUI_FeatureTree` (it already renders the VS Code extension feature), so a
  "speed up builds" checkbox could hang off the same dialog — not yet wired.
- **Code signing** — unsigned third-party exes + MSI draw SmartScreen/Defender
  scrutiny; signing is the proper fix for managed/gov machines.
- **macOS / Linux** — out of scope here; use opam.

(The release workflow now exists — `.github/workflows/publish.yml` promotes a
vetted CI artifact to a GitHub release; see HACKING.md → "Making an alpha release".)
