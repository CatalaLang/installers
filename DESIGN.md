# Design

These installers package the Catala toolchain as a self-contained Windows MSI —
a complete snapshot, with no opam or network resolution at install time.

## Overview

Two stages, both run on Windows (the CI `windows-latest` runner, or a dev box):

1. **Stage** (`build-bundle.ps1`): assemble a relocatable toolchain tree from an
   opam switch + a pinned MinGW-w64 gcc, plus the VS Code `.vsix`.
2. **Package** (`wix/Catala.wxs`, WiX dotnet tool): harvest that tree into an MSI.

Output: `catala-<version>-windows-x86_64.msi` (+ `.sha256`).

## Installed layout

```
Catala/
  bin/                 wrapper scripts added to PATH (catala/clerk/lsp/dap/format)
  toolchain/           actual binaries + data (not on PATH directly)
    bin/               catala/clerk/ocamlopt/ninja/flexlink, gcc/ld/as, ...
    lib/               ocaml stdlib, zarith, catala runtime + plugins, gcc libs
    libexec/           gcc internals, defender.ps1
    share/topiary/     queries + configs
    x86_64-w64-mingw32/lib/   import libs for linking
  catala-<version>.vsix
```

The `bin\*.cmd` wrappers compute their own location (`%~dp0..`) and set
`CATALA_OCAML_LIBDIR`, `OCAMLLIB`, `NINJA_BIN`, `CATALA_PLUGINS`, `LIBRARY_PATH`,
`FLEXLINKFLAGS` and `PATH` (with `setlocal` isolation, so they don't disturb a
developer's own opam) before exec-ing the real binary. The tree is fully
relocatable; the MSI only has to add `bin\` to PATH.

## Install model

- **Two scopes, chosen at build time (`-Scope`):** *per-machine* (default, the
  shipped MSI) → `C:\ProgramData\Catala`, system PATH, elevated, for IT push
  (Intune/GPO); *per-user* → `%LOCALAPPDATA%\Programs\Catala`, user PATH, no admin
  (for machines without local admin). Both target **space-free** paths: clerk's
  generated build rules aren't fully space-safe yet, so `C:\Program Files` is
  avoided.
- **PATH** is managed via the MSI `Environment` table (added on install, removed
  on uninstall). **Upgrades** use `MajorUpgrade` (newer replaces older; downgrades
  blocked). **Uninstall** via Add/Remove Programs or `msiexec /x`.
- The only shipped helper script is `defender.ps1` (in `toolchain\libexec`).

## Self-containment

The native toolchain is single-sourced from one winlibs release; only `libgmp`
comes from the opam/Cygwin sysroot (itself a mingw-native build — no
`cygwin1.dll`). A static **import-closure check** over every staged `.exe`/`.dll`
fails the build if an imported DLL is neither bundled nor a known Windows system
DLL — so a half-resolved toolchain (the cause of past `STATUS_DLL_NOT_FOUND` on
clean boxes) can't ship.

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
- **`CATALA_OCAML_LIBDIR`** support in clerk (catala branch `clerk-ocaml-libdir`),
  so clerk finds the bundled OCaml libs at a non-standard path. Pending upstream.

## Constraints

- **External OCaml modules:** programs depending on arbitrary opam packages can't
  be compiled with the bundle — that audience uses a real opam install.
- **catala opam repo:** `gitlab.inria.fr/catala/opam-repository` is needed to
  install `catala-lsp` / current `catala-format` (not on opam.ocaml.org).

## Open / not yet built

- **Defender UI checkbox** — `TUNE_DEFENDER` is command-line only; the MSI uses
  `WixUI_Minimal`. A "speed up builds" checkbox is a follow-up.
- **Code signing** — unsigned third-party exes + MSI draw SmartScreen/Defender
  scrutiny; signing is the proper fix for managed/gov machines.
- **Release workflow** — build on a tag, upload MSI + checksum to a GitHub release.
- **macOS / Linux** — out of scope here; use opam.
