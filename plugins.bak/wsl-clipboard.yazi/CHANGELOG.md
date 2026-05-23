# wsl-clipboard

## Project Summary

This plugin bridges Yazi in WSL with the Windows clipboard.

Current behavior:

- `y`: use Yazi native `yank`, then sync selected file paths to the Windows clipboard as a copy operation.
- `x`: use Yazi native `yank --cut`, then sync selected file paths to the Windows clipboard as a move operation.
- `p`: read the Windows clipboard and paste file lists or HTML into the current Yazi directory; if the clipboard contains an image, prompt for a file name and save it.
- `P`: same as `p`, but overwrite existing targets when supported.
- `i`: read an image from the Windows clipboard, prompt for a file name, and save it into the current Yazi directory.
- `I`: same as `i`, but allow overwrite.
- `Y` / `X`: clear Yazi yank state and clear the Windows clipboard.

Clipboard object handling:

- `FileDropList` + `Preferred DropEffect`: supported
- `HTML`: supported, saved as `clipboard.html`
- `Images`: supported through `p/P` fallback and through the dedicated image entry
- `Plain text`: intentionally ignored in Yazi file-manager paste flow

Design constraints:

- Plain text must be a no-op in file-manager paste behavior.
- Interactive image naming is allowed from `p/P` only when an actual image is present.
- The plugin must not affect Yazi input/rename mode key behavior.
- Windows clipboard access is done through `powershell.exe`, not hardcoded distro metadata.

Plugin files:

- `main.lua`: single Yazi plugin entry that dispatches `sync` / `paste` / `image` / `clear`
- `keymap.toml`: binds `y/x/p/P/i/I/Y/X` in `mgr` mode

No `init.lua` hook is required for this plugin. The `y/x` mappings explicitly run the sync command after Yazi's native yank command.

## Development Workflow

Required workflow from this point forward:

1. Before making changes, read this file first.
2. Summarize relevant prior failures and constraints from this file.
3. Make the code change.
4. Append the change and the lesson learned here.

## Lessons Learned

- Do not overload `p` with both non-interactive paste and interactive image naming.
- Keep `mgr` key bindings separate from Yazi input-mode behavior.
- Avoid hardcoding WSL distro-specific clipboard path assumptions.
- Stabilize behavior boundaries first, then add features.
- Do not rely on `Command(...):output()` for the Windows clipboard broker path when the process graph may keep stdout/stderr pipes alive.
- Lock the clipboard broker itself, not the Yazi command entry.
- When PowerShell is invoked from WSL, every broker artifact path passed into PowerShell must be converted to a Windows-visible path first.
- If the main action still shows `1 left`, do not keep stdout-collecting helpers in the same path; use `spawn()` + `wait()` and return immediately from the entry as early as possible.
- Keep entry files thin: dispatch work via `ya.async(...)` and do not run clipboard I/O directly in the entry body.
- Do not add a global broker lock when every invocation already uses unique temp files; the lock itself can become the stall point.
- Do not double-append the shared root when constructing temp paths; keep the broker paths canonical and identical on both sides.
- Keep `fs.lua` path conversion minimal; avoid extra distro probing or PowerShell reads that do not affect the user-visible outcome.
- Keep broker temp files in the WSL temp space and convert only the path handed to PowerShell.
- Use one real Yazi plugin directory with `main.lua`; do not emulate sub-entries by inventing plugin names like `wsl-clipboard.paste`.
- Parse plugin flags according to Yazi’s actual `job.args` model: positional args become `args[1..]`, `--flag` becomes `args.flag = true`.
- Keep PowerShell templates inside `clipboard.lua` as plain string concatenations; avoid nested long-bracket strings that can break Lua syntax.
- Do not rely on `init.lua` + `ps.sub_remote("@yank")` for same-instance clipboard sync. A local keymap action is simpler and deterministic.
- Do not wrap PowerShell with `sh -c` for this plugin. Yazi's `Command(...):arg(...)` can pass argv directly, which keeps PowerShell quoting intact.
- `p` must distinguish plain text from image data: plain text is no-op, image data opens the image naming prompt.
- Every PowerShell clipboard call must have a hard timeout so a Windows clipboard stall cannot leave Yazi showing `1 left` forever.

## Changelog

### 2026-05-20

#### Initial documented state

- Started formal project record keeping in `CHANGELOG.md`.
- Documented the intended behavior, file layout, and current constraints.

#### Clipboard flow split

- Split image handling out of `p`.
- Kept `p/P` for file-list and HTML paste only.
- Added dedicated image entries:
  - `i` -> `plugin wsl-clipboard.image`
  - `I` -> `plugin wsl-clipboard.image-force`

Files changed in this round:

- `keymap.toml`
- `ops.lua`
- `clipboard.lua`
- `image.lua`
- `image-force.lua`

Reason for change:

- The previous design allowed image handling to participate in the main `p` paste flow.
- That mixed interactive UI with non-interactive paste and caused repeated plugin task hangs (`1 left` / `Run plugin wsl-clipboard.paste`).

Resulting rule:

- `p` must remain a non-interactive file-manager paste path.
- Image save is a separate, explicit operation.

#### Broker rewrite

- Rewrote `clipboard.lua` to use:
  - a broker lock under `$XDG_RUNTIME_DIR` or `/tmp`
  - PowerShell scripts written to temporary files
  - result/error files for data return
  - `status()` instead of `output()` for process completion

Files changed in this round:

- `clipboard.lua`
- `CHANGELOG.md`

Reason for change:

- The previous broker waited on command output pipes.
- Under WSL + Windows clipboard interop, that model can hang even when the logical clipboard action itself is simple.

Resulting rule:

- Clipboard broker invocations must be serialized.
- Clipboard data exchange must not depend on child stdout/stderr pipe closure.

#### Broker path fix

- Removed the `-File <WSL path>` PowerShell invocation model from the broker.
- Switched broker execution back to `-Command <script>`.
- Ensured broker result paths passed into PowerShell are converted with `path_to_windows()`.
- Added explicit timeout-status handling for exit code `124`.

Files changed in this round:

- `clipboard.lua`
- `CHANGELOG.md`

Reason for change:

- The previous broker rewrite still passed WSL-side temp artifact paths into PowerShell.
- From `powershell.exe`, those paths are not valid Windows paths, so the broker could not reliably write results.

#### Output-free file command path

- Replaced `Command(...):output()`-based file copy/move helper with `spawn()` + `wait()`.
- Reintroduced `ops.lua` as a thin file-ops module with no stdout collection.

Files changed in this round:

- `ops.lua`
- `CHANGELOG.md`

Reason for change:

- The earlier file command helper still had an output-collection shape that was too close to the hanging pattern.
- The new helper keeps the task side-effect only and reduces the amount of buffered child-process state.

#### Thin entry dispatch

- Changed `paste.lua`, `paste-force.lua`, `image.lua`, and `image-force.lua` into thin dispatch wrappers.
- Moved actual clipboard work behind `ya.async(...)` so the entry body can return immediately.

Files changed in this round:

- `paste.lua`
- `paste-force.lua`
- `image.lua`
- `image-force.lua`
- `CHANGELOG.md`

Reason for change:

- Keeping heavy clipboard and file work in the entry body can keep the plugin task alive and leave the UI stuck showing `1 left`.

#### Remove broker lock

- Removed the global broker lock from `clipboard.lua`.
- Kept only per-invocation temp out/err files under a shared directory.

Files changed in this round:

- `clipboard.lua`
- `CHANGELOG.md`

Reason for change:

- The lock added no correctness because each invocation already had unique result files.
- It could only introduce a new blocking point.

#### Canonical shared root

- Fixed `state_paths()` so the shared root is used once, not appended twice.

Files changed in this round:

- `clipboard.lua`
- `CHANGELOG.md`

Reason for change:

- The previous path construction produced duplicate root segments, making the broker artifact paths inconsistent.

#### Minimal path conversion

- Removed distro probing from `fs.lua`.
- Kept only drive-letter conversion and `wslpath -w` fallback.

Files changed in this round:

- `fs.lua`
- `CHANGELOG.md`

Reason for change:

- Extra probing increased the surface area for hangs without changing actual paste behavior.

#### WSL temp broker artifacts

- Moved broker temp files back to a WSL temp directory.
- Kept Windows-path conversion only at the PowerShell boundary.

Files changed in this round:

- `clipboard.lua`
- `CHANGELOG.md`

Reason for change:

- Using a Windows-visible shared directory for every broker artifact added unnecessary filesystem indirection and more room for failure.

#### Single real plugin entry

- Replaced pseudo-plugin entry names like `wsl-clipboard.paste` with one official plugin entry: `wsl-clipboard`.
- Added `main.lua` and moved command dispatch into `job.args`.
- Removed obsolete pseudo-entry files:
  - `paste.lua`
  - `paste-force.lua`
  - `sync.lua`
  - `clear.lua`
  - `image-force.lua`
- Restored `ops.lua` to include a real `paste()` implementation.
- Updated `keymap.toml` to call:
  - `plugin wsl-clipboard -- sync`
  - `plugin wsl-clipboard -- paste`
  - `plugin wsl-clipboard -- paste --force`
  - `plugin wsl-clipboard -- image`
  - `plugin wsl-clipboard -- image --force`
  - `plugin wsl-clipboard -- clear`

Files changed in this round:

- `keymap.toml`
- `main.lua`
- `ops.lua`
- `CHANGELOG.md`

Files removed in this round:

- `paste.lua`
- `paste-force.lua`
- `sync.lua`

### 2026-05-22

#### Deterministic keymap-driven sync

- Restored explicit `y/x` sync in `keymap.toml`:
  - `y` runs native `yank`, then `plugin wsl-clipboard -- sync`
  - `x` runs native `yank --cut`, then `plugin wsl-clipboard -- sync`
- Removed the `init.lua` startup hook.
- Removed the unused `M:setup()` / `ps.sub_remote("@yank")` path from `main.lua`.

Reason for change:

- The previous version depended on a startup subscription for Yazi-to-Windows copy, while the keymap only called native `yank`.
- That meant syncing could silently fail if the hook was not loaded or if the remote subscription did not receive same-instance yank events.

Resulting rule:

- The manager keymap is the source of truth for `y/x` integration.
- Syncing selected files to Windows must be triggered directly by the same keypress that changes Yazi's yank state.

#### Direct PowerShell argv invocation

- Replaced the `sh -c "powershell.exe ..."` wrapper with direct `Command("timeout"):arg({ "8s", "powershell.exe", ... })`.
- Stopped rewriting every PowerShell single quote into a double quote.

Reason for change:

- The shell wrapper added an extra quoting layer and corrupted PowerShell scripts that intentionally used single-quoted strings.
- Direct argv invocation matches Yazi's command API better and avoids shell interpolation.
- The hard timeout prevents a Windows clipboard stall from leaving a permanent Yazi plugin task.

#### Paste semantics correction

- Fixed `p` so plain text is a no-op.
- Kept image paste on `p/P`, but only after probing that the clipboard actually contains image data.
- Fixed one-line `__kind__:html` parsing after stdout trimming.
- Fixed cut-state detection for both `cx.yanked.is_cut` and DDS-style `state.cut`.
- Changed post-save `reveal` calls to pass `Url(dst)`, matching Yazi preset plugin usage.

Reason for change:

- The previous version treated every non-file/non-HTML clipboard payload as a possible image, which broke the plain-text no-op requirement.
- HTML could fail because the parser expected a newline after the kind marker.
- Passing a plain string to `reveal` is less consistent with Yazi's own plugin examples than passing a `Url`.
- `clear.lua`
- `image-force.lua`

Reason for change:

- The prior layout did not match Yazi’s documented plugin model.
- The old `p` path also called a nonexistent `ops.paste`, which was a direct logic error.

#### Correct plugin arg parsing

- Updated `main.lua` to read `force` from `job.args.force` instead of scanning positional args for `"--force"`.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- Yazi parses plugin command strings into positional args and named flags separately.

#### PowerShell template syntax fix

- Rewrote clipboard PowerShell templates in `clipboard.lua` using plain concatenation.
- Verified the plugin Lua files parse successfully with `lua 5.4`.

Files changed in this round:

- `clipboard.lua`
- `CHANGELOG.md`

Reason for change:

- Nested long-bracket strings and embedded PowerShell blocks had produced a Lua syntax error near `$`.

### Final static-state checkpoint

Current stable shape:

- One plugin directory: `wsl-clipboard.yazi`
- One entrypoint: `main.lua`
- Supported entry commands:
  - `sync`
  - `paste`
  - `paste --force`
  - `image`
  - `image --force`
  - `clear`
- `keymap.toml` uses official Yazi plugin invocation syntax with `plugin wsl-clipboard -- ...`
- Lua syntax has been validated with `lua 5.4`

Remaining runtime validation target:

- Confirm the plugin behavior in the actual Yazi runtime.

Do not regress:

- Do not reintroduce pseudo plugin entries.
- Do not reintroduce a global broker lock.
- Do not make `p` prompt for plain text or unknown clipboard payloads; it may prompt only after an image probe succeeds.
- Do not reintroduce `Command(...):output()` in the broker path.

#### Entry model collapse

- Collapsed the runtime path into one self-contained `main.lua` entry.
- Removed the entry-time dependency on sibling `require(".ops")`, `require(".clipboard")`, `require(".image")`, and `require(".fs")`.
- Kept the keymap on official `plugin wsl-clipboard -- ...` syntax.
- Preserved the existing command surface:
  - `sync`
  - `paste`
  - `paste --force`
  - `image`
  - `image --force`
  - `clear`

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- The multi-file entry layout kept leaving room for loader mismatch and task-model confusion.
- A single entrypoint is the smallest shape that matches Yazi’s actual loader and avoids the broken sub-entry indirection.

Resulting rule:

- Treat `wsl-clipboard` as a single Yazi plugin entry at runtime.
- Keep all new commands routed through `plugin wsl-clipboard -- <cmd>`.

#### Startup hook

- Added a top-level `init.lua` hook that calls `dofile(.../plugins/wsl-clipboard.yazi/main.lua):setup()`.
- Kept the clipboard yank subscription in plugin startup instead of relying on `y/x` key order.

Files changed in this round:

- `init.lua`
- `main.lua`
- `CHANGELOG.md`

Reason for change:

- `setup()` is not automatic; it needs a startup hook.
- The yank subscription must be active before file-copy and paste interactions begin.

Resulting rule:

- `y/x` stay native.
- Clipboard sync is wired at Yazi startup, not manually chained after each yank keybind.

#### img-clip-style execution model

- Rebuilt `main.lua` around one-shot shell execution, modeled after `img-clip.nvim`.
- Stopped using the earlier temp-file broker and direct `try_wait()` polling path.
- Moved Windows clipboard reads and writes to `sh -c "powershell.exe -NoProfile -NonInteractive -STA -Command '...'"`.
- Added image fallback from `p` when file/html probe returns empty.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- `img-clip.nvim` proves the Windows clipboard path itself is viable from WSL Lua.
- The previous failures were more likely caused by my Yazi-side execution model than by PowerShell itself.

Resulting rule at that time, superseded on 2026-05-22:

- One-shot shell execution was tried for Windows clipboard access, but direct PowerShell argv invocation is now preferred.
- Keep the Yazi side thin and avoid the custom broker/process state machine.

#### Path conversion correction

- Fixed `path_to_windows()` so `wslpath -w` runs on the WSL side, not inside PowerShell.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- Running `wslpath` inside `powershell.exe` is simply wrong and breaks path conversion for clipboard writes and file saves.

Resulting rule:

- WSL path conversion stays in WSL.
- PowerShell only receives already-converted Windows paths.

### 2026-05-22

#### Nix validation and reveal correction

- Validated the plugin with the pinned NixOS flake under `/workspace/nixos`.
- Confirmed the flake-resolved Yazi version:
  - `Yazi 26.5.6 (aa52643 2026-05-05)`
- Confirmed `main.lua` parses with the flake-provided Lua 5.2:
  - `luac -p plugins/wsl-clipboard.yazi/main.lua`
- Confirmed `keymap.toml` parses as TOML and contains:
  - `y` -> `["yank", "plugin wsl-clipboard -- sync"]`
  - `x` -> `["yank --cut", "plugin wsl-clipboard -- sync"]`
- Confirmed `yazi --debug` reads:
  - `YAZI_CONFIG_HOME=/workspace/home/.config/yazi`
  - no `init.lua`
  - `keymap.toml`
- Changed post-save `reveal` calls to pass `Url(dst)` instead of a plain string.

Reason for change:

- The plugin needs to be checked against the same Yazi version family used by the user's NixOS configuration.
- Yazi's preset plugins pass `Url` objects to `reveal`, so the custom plugin should do the same after saving HTML or images.

Resulting rule:

- Future validation should use `/workspace/nixos#nixosConfigurations.wsl.pkgs.yazi` and `/workspace/nixos#nixosConfigurations.wsl.pkgs.lua`.
- Keep this plugin to two deployable items only:
  - `keymap.toml`
  - `plugins/wsl-clipboard.yazi/main.lua`

#### Runtime trace gate

- Added `WSL_CLIPBOARD_DEBUG=1` gated entry tracing in `main.lua`.
- The trace records the actual `job.args` received by the plugin entry.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- DDS-driven runtime validation was not proving whether `wsl-clipboard` reached `main.lua`.
- The trace must be opt-in so normal Yazi usage is not polluted by debug log entries.

Resulting rule:

- Use `WSL_CLIPBOARD_DEBUG=1` only during validation.
- If a runtime test has no `wsl-clipboard: entry ...` line, the issue is before plugin code execution.

#### Runtime branch tracing

- Added gated trace points around:
  - PowerShell command result capture
  - `read_paste()` kind detection
  - `paste_files()` cwd/source/status

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- The entry trace proved `paste` reaches `main.lua`, but the file still did not land.
- More precise branch tracing is needed to separate clipboard read, path conversion, and copy command failures.

Resulting rule:

- With `WSL_CLIPBOARD_DEBUG=1`, a failed file paste should show the exact last completed branch in `yazi.log`.

#### Paste file tracing

- Added entry logging inside `paste_files()` before and after cwd capture.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- The previous trace showed `paste kind=files`, but no `paste_files` trace.
- This is the smallest extra probe needed to separate an early Lua failure from a later copy-command failure.

Resulting rule:

- If `paste_files enter` is missing, the failure is before cwd resolution.
- If `paste_files cwd_raw=...` appears but no file lands, the copy command path is the next suspect.

#### Yazi state snapshot fix

- Replaced direct `cx.active.current.cwd` reads with a `ya.sync(...)` cwd snapshot.
- Replaced direct `cx.yanked` reads with a `ya.sync(...)` yank-state snapshot.
- Added explicit errors when cwd cannot be read.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- Runtime tracing proved `paste` reached `paste_files enter` and then stopped before cwd logging.
- Yazi preset plugins access `cx` state through `ya.sync(...)`; the plugin was violating that pattern.

Resulting rule:

- Do not read `cx.*` directly from ordinary helper functions.
- Capture Yazi state through `ya.sync(...)`, then pass plain Lua values into clipboard/file helpers.

#### Nix runtime validation

- Validated file copy paste with a fake `powershell.exe` FileDropList:
  - `p` copied a source file into the Yazi cwd.
- Validated multi-file copy paste:
  - `p` copied two FileDropList entries into the Yazi cwd.
- Validated file move paste with `__effect__:move`:
  - `p` moved the source file into the Yazi cwd and removed the original.
- Validated Yazi-to-Windows sync:
  - native `yank` followed by `sync` invoked PowerShell with `SetFileDropList(...)` and `Preferred DropEffect`.
- Validated image paste:
  - fake BMP clipboard probe opened the image naming flow.
  - pressing Enter saved a default timestamped `.bmp` file.
- Validated plain/unknown clipboard no-op:
  - `p` generated no files and returned without hanging.

Files changed in this round:

- `CHANGELOG.md`

Reason for change:

- The plugin now has end-to-end runtime proof against the Nix-pinned Yazi instead of only syntax/config checks.

Resulting rule:

- Keep future regressions reproducible with fake `powershell.exe` runtime tests under isolated `XDG_RUNTIME_DIR` and `XDG_STATE_HOME`.

#### PowerShell encoding and image precedence fix

- Forced PowerShell stdout/stderr to UTF-8 before any clipboard script runs.
- Switched `path_to_wsl()` to try `wslpath -u` first, then fall back to manual Windows path mapping.
- Tightened HTML extraction to respect byte offsets more safely.
- Made image probe/save prefer bitmap data when available, including `DeviceIndependentBitmap` / `Format17` fallback.
- Changed mixed HTML + image clipboard handling to prefer the image save flow.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- The previous version could mis-handle non-ASCII PowerShell output, custom Windows path forms, and clipboard payloads that exposed both HTML and image data.

Resulting rule:

- Keep PowerShell output encoding explicit.
- Prefer the platform path converter before manual mapping.
- When clipboard content has both HTML and image metadata, treat the image as the more actionable payload for `p`.

#### PowerShell statement-boundary fix

- Added `ps_join()` and changed every multi-line clipboard script passed to `powershell.exe -Command` to preserve newline statement boundaries.
- Revalidated the single-file plugin with a direct Lua harness that stubs Yazi state and fake Windows clipboard responses.
- Covered file copy, multi-file copy, file move, plain-text no-op, HTML save, image save, HTML+image image-precedence, Yazi sync, and clear behavior in that harness.

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- The prior fake runtime checks verified plugin branching but did not parse PowerShell.
- Joining PowerShell statements with spaces can merge assignments, string output, and conditionals into invalid or ambiguous PowerShell syntax.

Resulting rule:

- Do not assemble non-trivial PowerShell clipboard scripts with space-only joins.
- Fake clipboard tests must assert the generated PowerShell command shape, not just the Lua branch result.

#### Multi-agent verification checkpoint

- Rechecked the Yazi 26.5.6 plugin loader/source model:
  - `plugin wsl-clipboard -- paste` loads `plugins/wsl-clipboard.yazi/main.lua`.
  - positional args are available as `job.args[1]`.
  - `--force` is available as `job.args.force == true`.
  - `[mgr] prepend_keymap` does not affect input/rename mode.
- Confirmed the plugin intentionally has no `--- @sync entry`, so `Command(...):wait_with_output()` and `ya.input()` run in async plugin entry mode.
- Confirmed `cx.yanked` is not a normal table; its Rust binding delegates `pairs(cx.yanked)` to an iterator over URLs only, while `cx.yanked.is_cut` remains a field.
- Re-ran Lua-level behavior validation against the current `main.lua`.

Files changed in this round:

- `CHANGELOG.md`

Reason for change:

- A final verification pass needed to record why the previous `yield from outside a coroutine` failure and the suspected `cx.yanked.is_cut` iteration issue do not apply to the current plugin shape.

Resulting rule:

- Keep `main.lua` as an async entry.
- Do not add `--- @sync entry`.
- Continue using `pairs(cx.yanked)` for paths and `cx.yanked.is_cut` only for the cut flag.

#### Unique target paste and final verification

- Changed Windows-to-Yazi file paste without `--force` to copy/move into a unique target path instead of relying on `cp -n`.
- Added local helpers for basename extraction, directory detection, and unique destination selection.
- Kept `P` / `--force` behavior as direct overwrite/merge through the target directory.
- Revalidated generated PowerShell scripts by parsing all 14 captured script variants with PowerShell Core.
- Revalidated behavior with a Lua harness covering:
  - paths with spaces, single quotes, and non-ASCII names
  - directories
  - Windows path conversion through `wslpath -u`
  - move/cut behavior
  - same-name no-force unique target behavior
  - force overwrite
  - plain-text no-op
  - HTML save
  - image save
  - HTML+image image precedence
  - Yazi-to-Windows sync and cut effect
  - clipboard clear

Files changed in this round:

- `main.lua`
- `CHANGELOG.md`

Reason for change:

- A final review found that `cp -n` could silently skip same-name targets and directory paste could merge in ways that felt less like a file manager.

Resulting rule:

- `p` should avoid destructive or silent same-name behavior by choosing a unique target.
- `P` remains the explicit overwrite path.
