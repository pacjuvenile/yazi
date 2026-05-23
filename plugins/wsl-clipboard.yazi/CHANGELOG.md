# Changelog

All notable changes to this project will be documented in this file.

## Unreleased

### Fixed

- Clear the Windows clipboard through the native helper's Win32
  `EmptyClipboard()` path instead of the optional `Clear-Clipboard` PowerShell
  cmdlet, which is not available in all `powershell.exe` environments launched
  from WSL.
- Keep per-Yazi-session plugin-managed yank state as a fallback so pressing `y`
  or `x` again on the same single file or file set reliably toggles it off even
  though Yazi runs each plugin entry in a fresh Lua VM.
- Avoid clearing newer Windows clipboard content when toggling `y` or `x` off.
  The plugin now clears the Windows clipboard only when it still contains the
  plugin ownership marker plus the same file list and copy/cut intent written
  by the plugin, so later screenshots, text, or externally copied files are not
  destroyed by a stale toggle.
- Reduce `y` / `x` latency when writing the Windows clipboard. Write/clear
  operations now require the native helper and no longer go through
  PowerShell.
- Add a helper `diagnose` command and richer clipboard-open diagnostics so
  WSL interop failures, clipboard lock contention, and helper startup issues
  are visible without manual Yazi debugging.
- Replace toggle-off clipboard verification with the native helper
  `clear-owned` command. Pressing `y` / `x` again on the same files no longer
  calls the generic clipboard probe or PowerShell fallback before clearing
  plugin-owned clipboard contents.
- Dispatch `write-files` and `clear-owned` through a short-lived Linux shell
  bridge using a base64 argv payload instead of waiting on the Windows helper
  process from Yazi. This keeps `y` / `x` responsive even when Yazi's
  `Command` wait path does not observe Windows `.exe` completion correctly
  under WSL interop.
- Serialize background helper writes with `flock` when available, reducing
  races from rapid repeated `y` / `x` toggles.
- Pass file lists for `y` / `x` through `--payload-base64`, avoiding shell
  quoting while keeping the dispatch path simple. Payloads above 24 KiB fail
  fast with a clear error instead of falling back to a temporary file.
- Dispatch `write-files` and `clear-owned` through the Linux shell bridge and
  keep `clear` on direct WSL interop instead of `cmd.exe`, avoiding UNC
  working-directory and `cmd.exe` quoting failures.
- Keep the persisted yank state if `clear-owned` fails during toggle-off, so a
  later retry can still clear plugin-owned Windows clipboard contents.

### Changed

- Split the implementation into focused Lua modules while keeping `main.lua`
  as the public Yazi plugin entry point.
- Add a native Windows helper for file clipboard read/write/clear operations.
  File clipboard writes and clears now require this helper; read-oriented paths
  can still use PowerShell where needed.
- Pass native helper control arguments and base64 path payloads through argv
  for `y` / `x` operations.
- Capture shell dispatch stdout/stderr for `y` / `x` operations and write
  helper trace output to the Yazi state log directory when
  `WSL_CLIPBOARD_DEBUG=1`.
- Add helper trace support and self-contained build/smoke scripts so the
  native helper path can be validated without manual Yazi debugging.
- Bundle the helper at `bin/wsl-clipboard-yazi.exe` so users can install the
  plugin directory directly without a separate helper deployment step.
- Make the helper build script use an isolated local rustup/cargo cache by
  default, so it does not accidentally reuse a broken user Rust toolchain.
- Open the Windows clipboard with `OpenClipboard(NULL)` for write/clear paths,
  avoiding message-only window creation on latency-sensitive `y` / `x`
  operations.
- Prefer direct WSL UNC paths for Linux-side files when writing Windows file
  clipboard data, avoiding per-file `wslpath` calls for normal WSL paths.
- Avoid spawning `mkdir -p` on every yank-state write once the state directory
  already exists.
- Update manual installation instructions for multi-file Lua plugin packaging.
- Make lowercase `y` / `x` the toggle keys for Yank/Copy and Cut. Pressing the
  same key again on the same files now cancels the yank state and clears the
  Windows clipboard only if it still contains this plugin's ownership marker,
  file list, and copy/cut intent.
- Map uppercase `Y` / `X` to `noop` in the recommended keymap so they no longer
  cancel yank state by accident.
- Stop routing `Esc`, `Ctrl+[`, `q`, `Q`, `v`, or `V` through plugin code.
  The example keymap keeps only native Yazi commands for `Esc` / `v` / `V`,
  while `Ctrl+[` / `q` / `Q` are left to Yazi defaults.
- Remove default `i` / `I` image-save key bindings. The explicit image command
  remains available, but `p` is the recommended image paste entry.
- Replace the default `P` overwrite binding with `noop`. `p` now asks on name
  conflicts: yes overwrites existing targets, no creates `_1` / `_2` unique
  names.
- Remove public `--force`, `clear`, and `clear-yank` dispatcher branches from
  the plugin entry because the recommended keymap no longer exposes them.
- Remove the local deployment script; the bundled helper is part of the plugin
  directory and is invoked directly by Lua.
- Keep public usage and troubleshooting docs focused on plugin-owned clipboard
  behavior instead of documenting normal Yazi exit and selection behavior.

## v0.1.0

Initial public release.

### Added

- Sync Yazi file yank/cut operations to the Windows clipboard as `FileDropList`.
- Paste Windows Explorer file and folder clipboard contents into the current Yazi directory.
- Preserve copy vs move intent through Windows `Preferred DropEffect` when available.
- Save Windows clipboard images from Yazi with an interactive file-name prompt.
- Save HTML clipboard content as `clipboard.html`.
- Ignore plain text clipboard content in Yazi file-manager paste flow.
- Provide `p` unique-name behavior and `P` overwrite behavior.
- Provide `i` and `I` for explicit clipboard-image saving.
- Provide `Y` and `X` keymap examples that clear both Yazi yank state and the Windows clipboard.

### Notes

- This plugin targets Windows + WSL.
- The public Yazi plugin entry is `main.lua`.
- Invoke it as `plugin wsl-clipboard -- <command>`.
- Do not invoke it as `plugin wsl-clipboard.<command>`.
- `ya pkg add` installs the plugin, but users still need to configure `keymap.toml` manually.
