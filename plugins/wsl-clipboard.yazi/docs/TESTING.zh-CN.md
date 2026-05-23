# 手动测试清单

## 基础检查

```sh
find . -maxdepth 1 -name '*.lua' -print0 | xargs -0 luac -p
taplo check examples/keymap.toml
cargo check --manifest-path helper/Cargo.toml
sh -n scripts/*.sh
```

如果安装了 native helper：

```sh
~/.config/yazi/plugins/wsl-clipboard.yazi/bin/wsl-clipboard-yazi.exe version
~/.config/yazi/plugins/wsl-clipboard.yazi/bin/wsl-clipboard-yazi.exe --trace diagnose
cd ~/.config/yazi/plugins/wsl-clipboard.yazi
./scripts/smoke-helper.sh
```

## 纯文本 no-op

1. 在 Windows 中复制一段文本。
2. 在 Yazi 文件浏览界面按 `p`。

预期：

- 不生成文件。
- 不弹出输入框。
- 不长期停留在 `1 left`。

短暂 `1 left` 闪烁是正常现象，因为插件需要探测 Windows 剪贴板类型。安装 native helper 后，文件剪贴板探测通常会更快。

## Windows 文件复制到 Yazi

1. 在 Windows Explorer 中复制一个文件。
2. 回到 Yazi，进入目标目录。
3. 按 `p`。

预期：文件出现在当前 Yazi 目录。

## Windows 多文件复制到 Yazi

1. 在 Windows Explorer 中复制多个文件。
2. 回到 Yazi，进入目标目录。
3. 按 `p`。

预期：多个文件都被复制到当前目录。

## Windows 目录复制到 Yazi

1. 在 Windows Explorer 中复制一个目录。
2. 回到 Yazi，进入目标目录。
3. 按 `p`。

预期：目录及其内容被复制到当前目录。

## Windows 剪切到 Yazi

1. 在 Windows Explorer 中剪切一个测试文件。
2. 回到 Yazi，进入目标目录。
3. 按 `p`。

预期：文件移动到当前目录。

## Yazi 复制到 Windows

1. 在 Yazi 中选中文件或目录。
2. 按 `y`。
3. 回到 Windows Explorer。
4. 按 `Ctrl+V`。

预期：Windows Explorer 可以粘贴对应文件或目录。

同时建议打开 debug 日志确认 `y` / `x` 只走 helper 路径：

```sh
WSL_CLIPBOARD_DEBUG=1 YAZI_LOG=debug yazi
rg -n "shell-background-argv|payload-base64|helper dispatch|stdin-direct|stdin-background-dispatch|helper status|cmd.exe|--path-list|timed out" ~/.local/state/yazi/yazi.log
```

预期：`y` / `x` 路径出现 `helper spawn mode=shell-background-argv`、`--payload-base64` 和 `helper dispatch code=0`，不出现 `stdin-direct`、`stdin-background-dispatch`、`helper status`、`cmd.exe`、`--path-list`、`timed out`、`helper write_files fallback`、`helper clear_owned fallback` 或后续 `powershell exit=0`。

`WSL_CLIPBOARD_DEBUG=1` 会自动给 `y` / `x` helper 调用追加 `--trace`。由于 `y` / `x` 为了速度会后台运行 helper，helper trace 不再写入 `yazi.log`，而是写入 `~/.local/state/yazi/wsl-clipboard-helper.log`。也可以单独运行：

```sh
cd ~/.config/yazi/plugins/wsl-clipboard.yazi
./bin/wsl-clipboard-yazi.exe --trace diagnose
./scripts/smoke-helper.sh
```

## Yazi 复制 toggle 取消

1. 在 Yazi 中选中同一个文件或目录。
2. 按 `y`。
3. 再按一次 `y`。
4. 回到 Windows Explorer。
5. 按 `Ctrl+V`。

预期：Yazi yank 状态被取消，Windows Explorer 不再粘贴刚才的文件或目录。debug 日志里第二次 `y` 应调用 `clear-owned`，不应调用 `read-paste` 或 PowerShell。

还需要测试单文件 hover 场景：不选中文件，只把光标停在一个文件上，按 `y` 后再按 `y`。预期同样是取消复制，而不是重新复制。

同样需要用多个选中文件重复一次，确认多文件 yank 后第二次按 `y` 会取消整组文件，而不是只改成复制 hover 文件。

## Yazi 复制 toggle 不误清新剪贴板

1. 在 Yazi 中选中一个文件或目录。
2. 按 `y`。
3. 在 Windows 中使用 `Win+Shift+S` 截图，让系统剪贴板变成图片。
4. 回到 Yazi，对同一批文件再按一次 `y`。
5. 在终端运行 `wl-paste --list-types`，或在 Windows 中直接粘贴。

预期：Yazi yank 状态被取消，但 Windows 剪贴板中的截图仍然存在。插件不应清空或替换后来由 Windows 放入剪贴板的新内容。

还需要测试 Windows 后来复制同一文件的场景：第 2 步后，在 Windows Explorer 中重新复制同一个文件，再回 Yazi 按同一批 `y`。预期：Yazi yank 状态被取消，但 Windows Explorer 仍能粘贴刚才由 Windows 自己复制的文件。

## Yazi 剪切到 Windows

1. 在 Yazi 中选中一个测试文件。
2. 按 `x`。
3. 回到 Windows Explorer。
4. 按 `Ctrl+V`。

预期：Windows Explorer 按移动语义处理。

## Yazi 剪切 toggle 取消

1. 在 Yazi 中选中一个测试文件。
2. 按 `x`。
3. 再按一次 `x`。
4. 回到 Windows Explorer。
5. 按 `Ctrl+V`。

预期：Yazi yank 状态被取消，Windows Explorer 不再粘贴刚才的文件。

还需要测试单文件 hover 场景：不选中文件，只把光标停在一个文件上，按 `x` 后再按 `x`。预期同样是取消剪切，而不是重新剪切。

## `Y` / `X` / `P` no-op

1. 在 Yazi 中选中一个测试文件。
2. 按 `y`。
3. 按 `Y`、`X` 或 `P`。
4. 回到 Windows Explorer。
5. 按 `Ctrl+V`。

预期：这些键不改变复制状态，Windows Explorer 仍然可以粘贴第 2 步复制的文件。

## Windows 截图保存到 Yazi

1. 使用 `Win+Shift+S` 截图。
2. 回到 Yazi。
3. 按 `p`。
4. 确认命名框是空的。
5. 输入 `shot` 后回车。

预期：当前目录生成 `shot.<剪贴板图片格式>`。

再重复一次，命名框出现后直接回车。

预期：当前目录生成默认时间戳文件，例如 `clipboard-20260523-153000.bmp`。

再重复一次，输入 `shot.png`、`shot.jpg` 或 `shot.bmp`。

预期：当前目录生成用户指定后缀的图片文件。支持的输出后缀是 `png`、`jpg`、`jpeg`、`bmp`、`tif`、`tiff` 和 `gif`；`svg` 和 `pdf` 应提示不支持。

## 图片保存取消

1. 使用 `Win+Shift+S` 截图。
2. 回到 Yazi。
3. 按 `p`。
4. 输入框出现后按 `Esc`。

预期：不生成文件。

## 重名与覆盖

1. Windows 复制 `a.txt`。
2. Yazi 当前目录已有 `a.txt`。
3. 按 `p`。
4. 在确认框里选 `No`。

预期：生成唯一文件名，例如 `a_1.txt`。

5. 再按 `p`。
6. 在确认框里选 `Yes`。

预期：覆盖当前目录已有的 `a.txt`。
