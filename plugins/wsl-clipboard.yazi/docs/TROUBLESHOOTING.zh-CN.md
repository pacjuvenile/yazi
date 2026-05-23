# 故障排查

## 按键没有触发插件

确认插件文件存在：

```sh
ls ~/.config/yazi/plugins/wsl-clipboard.yazi/*.lua
```

至少应包含 `main.lua`、`win-clipboard.lua`、`paste.lua`、`yank.lua` 等插件 Lua 文件。手动安装时不要只复制 `main.lua`。

确认 `keymap.toml` 使用单入口插件命令：

```toml
plugin wsl-clipboard -- paste
```

不要使用旧式子插件写法：

```toml
plugin wsl-clipboard.paste
```

## 长时间显示 `1 left`

短暂出现 `1 left` 是正常现象。长期不消失表示插件任务没有结束。

如果主要慢在 `y` / `x`，重点检查 native helper 和 WSL interop。`y` / `x` 写 Windows 文件剪贴板以及 toggle 取消时的所有权检查都不再回退到 PowerShell；helper 不可用时应该快速失败并给出原因。

先独立验证 helper：

```sh
cd ~/.config/yazi/plugins/wsl-clipboard.yazi
./bin/wsl-clipboard-yazi.exe --trace diagnose
./scripts/smoke-helper.sh
```

启用调试日志：

```sh
WSL_CLIPBOARD_DEBUG=1 YAZI_LOG=debug yazi
```

退出 Yazi 后检查日志：

```sh
rg -n "wsl-clipboard|Clipboard" ~/.local/state/yazi/yazi.log
```

## Windows 文件无法粘贴到 Yazi

检查 PowerShell：

```sh
powershell.exe -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()'
```

检查 Windows 路径转换：

```sh
wslpath -u 'C:\Windows'
```

如果这些命令失败，插件无法从 Windows 剪贴板读取和落盘文件。

## Yazi 复制后 Windows Explorer 无法粘贴

如果安装了 native helper，先确认 helper 可执行：

```sh
~/.config/yazi/plugins/wsl-clipboard.yazi/bin/wsl-clipboard-yazi.exe version
```

也可以用环境变量显式指定 helper，这主要用于调试或测试自定义构建：

```sh
export WSL_CLIPBOARD_YAZI_HELPER=/mnt/c/path/to/wsl-clipboard-yazi.exe
```

正常安装整个插件目录时，不需要设置这个环境变量；插件会直接使用：

```text
~/.config/yazi/plugins/wsl-clipboard.yazi/bin/wsl-clipboard-yazi.exe
```

如果 `y` / `x` 仍然很慢，先确认正常路径是否已经直接通过 WSL interop 运行 helper：

```sh
WSL_CLIPBOARD_DEBUG=1 YAZI_LOG=debug yazi
```

退出后查看：

```sh
rg -n "shell-background-argv|payload-base64|helper dispatch|stdin-direct|stdin-background-dispatch|helper status|cmd.exe|--path-list|timed out" ~/.local/state/yazi/yazi.log
```

预期 `y` / `x` 出现 `helper spawn mode=shell-background-argv`、`--payload-base64` 和 `helper dispatch code=0`，且不出现 `stdin-direct`、`stdin-background-dispatch`、`helper status`、`cmd.exe` 或 `--path-list`。如果没有 `helper dispatch`，说明 Yazi 没有完成 Linux shell 调度；优先检查 `sh`、helper 路径和 payload 是否超过 24 KiB。

`WSL_CLIPBOARD_DEBUG=1` 会自动给 `y` / `x` helper 调用追加 `--trace`，后台 helper trace 会写入 `~/.local/state/yazi/wsl-clipboard-helper.log`。也可以单独运行：

```sh
cd ~/.config/yazi/plugins/wsl-clipboard.yazi
./bin/wsl-clipboard-yazi.exe --trace diagnose
./scripts/smoke-helper.sh
```

如果 `diagnose` 没有 `trace:process:start`，说明 `.exe` 进程没有成功启动，优先查 WSL interop 或 helper 路径。停在 `trace:open-clipboard:*` 通常表示 Windows 剪贴板被其他进程占用或打开失败；停在 `trace:write-files:set-cf-hdrop` / `trace:write-files:set-drop-effect` 表示 Windows 剪贴板数据写入阶段卡住。

如果 `diagnose` 或日志里出现 `exec format error`，先修 WSL interop；这通常和 `explorer.exe .` 也无法执行是同一个问题。

再检查当前路径是否能转换为 Windows 可见路径：

```sh
wslpath -w "$PWD"
```

输出应类似：

```text
\\wsl.localhost\Ubuntu\home\user\...
```

或：

```text
C:\...
```

插件会优先把普通 WSL 绝对路径写成 `\\wsl$\<Distro>\...`，以减少 per-file `wslpath` 调用；`wslpath` 仍可用来核对 Windows 是否能看到当前路径。

## 图片没有进入命名框

检查 Windows 剪贴板是否暴露图片格式：

```sh
powershell.exe -NoProfile -NonInteractive -STA -Command '
Add-Type -AssemblyName System.Windows.Forms
$d = [System.Windows.Forms.Clipboard]::GetDataObject()
$d.GetFormats()
'
```

如果只看到 `UnicodeText` 或 `Text`，剪贴板中不是图片数据。

## 图片保存后缀不支持

图片命名框为空时，直接回车会使用默认时间戳文件名和剪贴板图片格式。输入不带后缀的名称时，插件会自动补上剪贴板图片格式后缀。

如果输入了后缀，插件会按该后缀保存并转换图片格式。当前支持 `png`、`jpg`、`jpeg`、`bmp`、`tif`、`tiff` 和 `gif`。`svg` 和 `pdf` 不是位图编码格式，插件不会把截图伪装成矢量图或 PDF。

## 纯文本按 `p` 没有动作

这是设计行为。

插件不会把纯文本剪贴板内容写成 `clipboard.txt`。文件管理器中的 `p` 只处理文件、目录、图片和 HTML。

## `p` 弹出覆盖确认

这是设计行为。

- 选 `Yes`: 覆盖已有目标。
- 选 `No`: 自动生成 `_1`、`_2` 这类唯一文件名。

建议先在临时目录中验证覆盖行为。

## `y` / `x` 再按一次会取消复制

这是设计行为。

推荐 keymap 中 `y` / `x` 是 toggle：

```toml
{ on = "y", run = "plugin wsl-clipboard -- toggle --copy" }
{ on = "x", run = "plugin wsl-clipboard -- toggle --cut" }
```

第一次按会设置 Yazi yank 状态并写入 Windows 剪贴板；对同一批文件再按一次，会清除 Yazi yank 状态。第二次按键会调用 native helper 的 `clear-owned` 命令，在 Windows 进程里完成所有权检查。只有当 Windows 剪贴板仍然带有本插件写入的所有权标记，并且仍然是同一批文件列表和复制/剪切意图时，插件才会清空它；如果你后来又截图、复制文本、在 Windows 中复制文件或复制了其他内容，插件不会清掉这些新的剪贴板内容。

## `Y` / `X` / `P` 没有动作

这是推荐 keymap 的设计行为。

```toml
{ on = "Y", run = "noop" }
{ on = "X", run = "noop" }
{ on = "P", run = "noop" }
```

这样可以覆盖 Yazi 默认的 `Y` / `X` 取消复制行为和 `P` 强制粘贴行为。取消复制只由小写 `y` / `x` toggle 完成，覆盖选择只由 `p` 内部确认框完成。

## 提交 issue 时的信息

建议包含：

```sh
yazi -V
ya --version
uname -a
echo "$WSL_DISTRO_NAME"
command -v powershell.exe
command -v wslpath
```

以及相关日志：

```sh
WSL_CLIPBOARD_DEBUG=1 YAZI_LOG=debug yazi
rg -n "wsl-clipboard|Clipboard" ~/.local/state/yazi/yazi.log
```
