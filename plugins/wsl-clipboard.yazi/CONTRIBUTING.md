# Contributing

Issues and pull requests are welcome.

Please include:

- Windows version
- WSL distribution
- `yazi -V`
- `ya --version`
- whether `powershell.exe` and `wslpath` are available in WSL
- the clipboard source: Windows Explorer, Snipping Tool, browser, another app
- debug logs when possible

Before opening a pull request, run:

```sh
luac -p main.lua
```

If you changed the keymap example, also validate `examples/keymap.toml` with a TOML formatter or linter.

## Maintainer Release Checklist

1. Update `CHANGELOG.md`.
2. Run local checks:

```sh
luac -p main.lua
taplo check examples/keymap.toml
```

3. Commit and push changes.
4. Create and push a tag:

```sh
git tag v0.1.0
git push origin v0.1.0
```

5. Create a GitHub release from the tag.
6. Verify installation from a clean Yazi environment:

```sh
ya pkg add pacjuvenile/wsl-clipboard
```
