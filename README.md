# Catala Installers

**Status: work in progress — not ready for general use yet.**

Native installers for the [Catala](https://catala-lang.org) toolchain.

This repository is **Windows-only**. On **Linux, macOS, and WSL, install via
opam** instead — see the
[Catala installation guide](https://book.catala-lang.org/en/1-1-0-installing.html).

## Windows

A self-contained Windows installer (`.msi`): it bundles a complete, relocatable
snapshot of `catala`, `clerk`, `catala-lsp`, `catala-dap`, `catala-format` and the
native compilation toolchain (MinGW-w64 gcc, flexlink, ninja) that `clerk build`
needs — so no separate OCaml/opam setup is required to install or use it. (opam is
used to build the installer.)

### Install

Download `catala-<version>-windows-x86_64.msi` from the releases page and run it —
double-click and accept the UAC prompt, or from an **elevated** terminal
(`msiexec /i catala-<version>-windows-x86_64.msi`; add `/qn` for silent).

It installs **per-machine** to `C:\ProgramData\Catala`, adds it to the system
`PATH`, and needs administrator rights. Open a new terminal afterwards for `PATH`
to take effect. (A no-admin **per-user** build — `%LOCALAPPDATA%\Programs\Catala` —
is also available; see [HACKING.md](HACKING.md).)

The snippets below use `$base = "C:\ProgramData\Catala"` for the install directory.

### Windows Defender exclusions (optional, faster builds)

Catala's build/test loop spawns many short-lived native compilers; Defender's
real-time scanning of those slows `clerk test` noticeably. You can opt into scoped
exclusions (install dir + the bundled compilers). This needs admin (one UAC
prompt) and is optional — the toolchain works without it, just slower.

At install time:

```powershell
msiexec /i catala-<version>-windows-x86_64.msi TUNE_DEFENDER=1
```

Or anytime after, with the bundled script (use `-Remove` to undo):

```powershell
& "$base\toolchain\libexec\defender.ps1" -Add -SelfElevate -InstallDir "$base"
```

On a locked-down machine where you cannot elevate, the script prints the exact
exclusion list so IT can push it via GPO/Intune. For unattended per-machine
rollout (Intune/GPO), install the per-machine MSI silently with `TUNE_DEFENDER=1`.

### VS Code extension

The installer **installs the Catala VS Code extension for you** by default: the
*VS Code extension* checkbox (ticked) runs `code --install-extension` on the bundled
`catala-<version>.vsix` during install. If VS Code isn't present the install still
succeeds and leaves a Start-Menu shortcut ("Install Catala VS Code extension") to
add it later.

**Restart VS Code afterwards** — fully quit, don't just reload the window — so the
extension picks up the new `PATH`; otherwise `catala` won't be found and
formatting/LSP won't work until VS Code is relaunched from a fresh environment.

_Manual install (fallback)_ — only if you unticked the box or added VS Code later:
double-click `install-vscode-extension.cmd` in `$base`, or run `code
--install-extension (Get-ChildItem "$base\catala-*.vsix").FullName` (needs the
`code` command on `PATH`). Uninstalling Catala leaves the extension in place; you
can also install **Catala** from the VS Code Marketplace, but the bundled `.vsix`
matches the toolchain version you just installed.

### Uninstall

Use **Settings → Apps → Installed apps → Catala**, or
`msiexec /x catala-<version>-windows-x86_64.msi /qn`. This also removes the `PATH`
entry and any Defender exclusions the installer added.

## Licensing

These installers and the Catala tools they install are licensed under the
[Apache 2.0 License](https://www.apache.org/licenses/LICENSE-2.0).

**Windows bundles** additionally include components licensed under the GNU
General Public License v3 (GPL-3.0-or-later):

- GCC (`gcc.exe`, `as.exe`, `ld.exe`) and binutils, from
  [winlibs](https://github.com/brechtsanders/winlibs_mingw)
- `liblto_plugin.dll`

These components are redistributed unmodified; source is available at
<https://github.com/brechtsanders/winlibs_mingw>. The MinGW-w64 and GCC runtime
support libraries (`libgcc*.a`, `libgmp.dll.a`, MinGW-w64 `.a` stubs) are licensed
under permissive terms (ZLib, BSD-2, public domain, or the GCC Runtime Library
Exception) and impose no GPL obligations on programs compiled with them.
