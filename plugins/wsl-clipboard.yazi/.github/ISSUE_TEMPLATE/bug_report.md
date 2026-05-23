---
name: Bug report
about: Report a problem with wsl-clipboard.yazi
title: ''
labels: bug
assignees: ''
---

## Environment

- Windows version:
- WSL distribution:
- `yazi -V`:
- `ya --version`:
- Shell:
- Terminal:

## Clipboard Source

What did you copy/cut?

- [ ] Windows Explorer file
- [ ] Windows Explorer folder
- [ ] multiple files/folders
- [ ] Snipping Tool / screenshot
- [ ] browser image
- [ ] text
- [ ] other:

## What Happened

Describe the actual behavior.

## Expected Behavior

Describe what you expected.

## Logs

Please run:

```sh
WSL_CLIPBOARD_DEBUG=1 YAZI_LOG=debug yazi
rg -n "wsl-clipboard|Clipboard" ~/.local/state/yazi/yazi.log
```

Paste relevant log lines here.
