# wsl-clipboard-yazi helper

This helper is a small Windows executable used by `wsl-clipboard.yazi`
to write, read, and conditionally clear Windows file clipboard data without
starting PowerShell for Yazi `y` or `x` key presses.

`write-files` and `clear-owned` accept direct path arguments, a UTF-8
NUL-separated `--path-list <file>`, a UTF-8 NUL-separated stdin payload with
`--stdin-len <bytes>`, or a base64-encoded UTF-8 NUL-separated payload with
`--payload-base64 <payload>`. The Lua plugin uses `--payload-base64` for
latency-sensitive `y` / `x` dispatch.

The plugin expects the bundled executable here:

```text
bin/wsl-clipboard-yazi.exe
```

Rebuild it from WSL with:

```sh
./scripts/build-helper.sh
```

The build script writes the resulting executable back to `bin/`.

Run a quick interop and clipboard-open diagnosis with:

```sh
bin/wsl-clipboard-yazi.exe --trace diagnose
```

Run the end-to-end helper smoke test from WSL with:

```sh
./scripts/smoke-helper.sh
```

For local debugging, `WSL_CLIPBOARD_YAZI_HELPER` can point the Lua plugin to a
custom helper binary:

```sh
export WSL_CLIPBOARD_YAZI_HELPER=/mnt/c/path/to/wsl-clipboard-yazi.exe
```
