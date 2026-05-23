# 安装

## 依赖

- Windows 10/11
- WSL
- Yazi 和 `ya`
- WSL 内可调用 `powershell.exe`
- WSL 内存在 `timeout`、`wslpath`、`test`、`cp`、`mv`、`rm`、`realpath`

检查基础依赖：

```sh
command -v yazi ya powershell.exe timeout wslpath
```

## 内置 native helper

仓库已经内置 Windows helper：

```text
bin/wsl-clipboard-yazi.exe
```

Lua 插件会从自己的插件目录直接调用这个可执行文件，不需要单独部署脚本。`y` / `x` 写入 Windows 文件剪贴板以及 toggle 取消时的所有权检查都严格依赖 helper，不再回退到 PowerShell；`p` 这类读取路径仍可在必要时使用 PowerShell。

如果修改了 helper 源码，或者想重新构建内置的 `.exe`：

```sh
./scripts/build-helper.sh
```

独立验证 helper：

```sh
cd ~/.config/yazi/plugins/wsl-clipboard.yazi
./bin/wsl-clipboard-yazi.exe --trace diagnose
./scripts/smoke-helper.sh
```

## 使用 `ya pkg` 安装

```sh
ya pkg add pacjuvenile/wsl-clipboard
```

GitHub 仓库名是 `wsl-clipboard.yazi`，安装时的包名是 `wsl-clipboard`。

`ya pkg add` 只安装插件文件，不会修改 Yazi 快捷键配置。安装后需要手动编辑：

```sh
~/.config/yazi/keymap.toml
```

加入：

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

如果 `keymap.toml` 已经有 `[mgr]` 和 `prepend_keymap`，只合并数组条目，不要重复创建第二个 `[mgr]` 表。

修改后重新启动 Yazi。

## 从源码安装

```sh
git clone https://github.com/pacjuvenile/wsl-clipboard.yazi \
	~/.config/yazi/plugins/wsl-clipboard.yazi
```

然后把 `examples/keymap.toml` 合并到 `~/.config/yazi/keymap.toml`。

手动安装时要安装整个插件目录，包括 `bin/wsl-clipboard-yazi.exe`。不要只复制 `main.lua`。

## 升级

通过 `ya pkg` 安装时：

```sh
ya pkg upgrade
```

手动安装时：

```sh
git -C ~/.config/yazi/plugins/wsl-clipboard.yazi pull
```
