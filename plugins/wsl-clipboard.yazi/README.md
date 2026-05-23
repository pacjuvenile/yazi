# wsl-clipboard.yazi

A Yazi plugin that bridges file and image clipboard operations between WSL and Windows.

`wsl-clipboard.yazi` makes Yazi inside WSL work with the Windows clipboard in a file-manager-friendly way:

- Yank files in Yazi and paste them in Windows Explorer.
- Copy files in Windows Explorer and paste them in Yazi.
- Save screenshots and other image clipboard data from Windows into the current Yazi directory.
- Ignore plain text in file-manager paste mode, so accidental text clipboard content does not create files.

## Requirements

- Windows 10 or Windows 11
- WSL
- Yazi and `ya`
- `powershell.exe` available from WSL
- `timeout`, `wslpath`, `test`, `cp`, `mv`, `rm`, and `realpath` available in WSL

This plugin is designed for Windows + WSL. It is not a general Linux, Wayland, X11, or macOS clipboard plugin.

### Bundled Native Helper

This repository ships a native Windows helper at `bin/wsl-clipboard-yazi.exe`. The Lua plugin loads that executable from its own plugin directory, so no separate deploy step is needed.

If you change the helper source or want to rebuild the bundled executable:

```sh
./scripts/build-helper.sh
```

`y` / `x` file clipboard writes and toggle-off ownership checks require the helper and do not fall back to PowerShell. Read-oriented operations such as `p` can still use the PowerShell path when needed. `WSL_CLIPBOARD_YAZI_HELPER` can override the helper path for local debugging.

## Installation

Install with Yazi's package manager:

```sh
ya pkg add pacjuvenile/wsl-clipboard
```

The GitHub repository is named `wsl-clipboard.yazi`, while the package name used by `ya pkg add` is `wsl-clipboard`.

`ya pkg add` installs the plugin only. Key bindings must be added manually to `~/.config/yazi/keymap.toml`:

```toml
[mgr]
prepend_keymap = [
	{ on = "<Esc>", run = [ "escape --all", "unyank" ], desc = "Clear selection and yank state" },
	{ on = "v", run = "toggle", desc = "Toggle the current selection state" },
	{ on = "V", run = "visual_mode", desc = "Enter visual selection mode" },
	{ on = "y", run = "plugin wsl-clipboard -- toggle --copy", desc = "Toggle yank to Windows clipboard" },
	{ on = "x", run = "plugin wsl-clipboard -- toggle --cut", desc = "Toggle cut to Windows clipboard" },
	{ on = "p", run = "plugin wsl-clipboard -- paste", desc = "Paste from Windows clipboard" },
	{ on = "P", run = "noop", desc = "Disable default overwrite paste" },
	{ on = "Y", run = "noop", desc = "Disable default yank cancel" },
	{ on = "X", run = "noop", desc = "Disable default yank cancel" },
]
```

Restart Yazi after changing the keymap.

## Manual Installation

For local testing or source installs:

```sh
git clone https://github.com/pacjuvenile/wsl-clipboard.yazi \
	~/.config/yazi/plugins/wsl-clipboard.yazi
```

Then merge `examples/keymap.toml` into `~/.config/yazi/keymap.toml`.

Install the whole plugin directory, including `bin/wsl-clipboard-yazi.exe`. Do not copy only `main.lua`.

To validate the helper outside Yazi:

```sh
cd ~/.config/yazi/plugins/wsl-clipboard.yazi
./bin/wsl-clipboard-yazi.exe --trace diagnose
./scripts/smoke-helper.sh
```

## Usage

| Key | Action |
| --- | --- |
| `y` | Toggle selected or hovered files as copy in Yazi and the Windows clipboard |
| `x` | Toggle selected or hovered files as cut in Yazi and the Windows clipboard |
| `p` | Paste files, folders, HTML, or images from the Windows clipboard into the current Yazi directory |
| `Y` / `X` / `P` | Disabled by the recommended keymap |

## Clipboard Behavior

Clipboard formats are handled in this order:

1. Windows `FileDropList`
2. Image formats
3. HTML
4. Plain text

Plain text is intentionally ignored in `p` paste flow. Yazi is a file manager; this plugin does not materialize text clipboard content as `clipboard.txt`.

When a target already exists, `p` asks whether to overwrite it. Choosing no creates a unique name such as `file_1.txt`.

Pressing `y` or `x` again on the same selected or hovered files cancels the Yazi yank state. The native helper performs the ownership check and clears the Windows clipboard only when the clipboard still contains this plugin's ownership marker plus the same file list and copy/cut intent written by the plugin; newer screenshots, text, externally copied files, or other clipboard content are left untouched. `Y` and `X` are disabled in the recommended keymap so cancellation lives on the lowercase toggle keys. `P` is disabled because overwrite choice lives inside `p`.

## Debugging

Run Yazi with debug logging:

```sh
WSL_CLIPBOARD_DEBUG=1 YAZI_LOG=debug yazi
```

Then inspect Yazi's log:

```sh
rg -n "wsl-clipboard|Clipboard" ~/.local/state/yazi/yazi.log
```

`y` / `x` writes dispatch the helper through a short-lived Linux shell bridge with a base64 argv payload, so Yazi does not wait on the Windows `.exe` process directly. With `WSL_CLIPBOARD_DEBUG=1`, background helper traces are written to `~/.local/state/yazi/wsl-clipboard-helper.log`. For standalone helper checks, run `./bin/wsl-clipboard-yazi.exe --trace diagnose` or `./scripts/smoke-helper.sh` from the plugin directory.

## Notes

- `Y`, `X`, and `P` are mapped to `noop` in the recommended keymap to avoid falling back to Yazi's local clipboard behavior.
- Large file or directory operations can run for a while and currently do not show progress.
- A short `1 left` status flash can appear while the plugin probes the Windows clipboard. File-copy `y` / `x` operations use the native helper directly; `p` may still probe multiple clipboard formats.
- Rename/input mode paste behavior is not changed by this plugin.
- The plugin still exposes `plugin wsl-clipboard -- image` as an optional explicit image-save command, but `p` already handles images and is the recommended default entry.

## More Documentation

- [Chinese installation guide](docs/INSTALL.zh-CN.md)
- [Chinese testing checklist](docs/TESTING.zh-CN.md)
- [Chinese troubleshooting guide](docs/TROUBLESHOOTING.zh-CN.md)

## License

BSD-2-Clause
