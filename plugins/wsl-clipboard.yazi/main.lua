local M = {}

local last_effect = "copy"

local function trim(s)
	return (tostring(s or ""):gsub("\r\n", "\n"):gsub("\n+$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function debug_log(message)
	if os.getenv("WSL_CLIPBOARD_DEBUG") == "1" then
		ya.err("wsl-clipboard: " .. tostring(message))
	end
end

local function describe_args(args)
	local out = {}
	for k, v in pairs(args or {}) do
		out[#out + 1] = tostring(k) .. "=" .. tostring(v)
	end
	table.sort(out)
	return table.concat(out, ",")
end

local current_cwd_sync = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local yanked_state_sync = ya.sync(function()
	local state = { paths = {}, cut = false }
	for _, url in pairs(cx.yanked) do
		state.paths[#state.paths + 1] = tostring(url)
	end
	local cut = cx.yanked.is_cut
	if cut == nil then
		cut = cx.yanked.cut
	end
	state.cut = cut == true
	return state
end)

local function quote_ps(s)
	return tostring(s or ""):gsub("'", "''")
end

local function ps_join(lines)
	return table.concat(lines, "\n")
end

local function exec_capture(program, args, timeout)
	local argv = { tostring(timeout or "3s"), program }
	for _, arg in ipairs(args or {}) do
		argv[#argv + 1] = arg
	end

	local child = Command("timeout")
		:arg(argv)
		:stdin(Command.NULL)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
	if not child then
		return nil
	end

	local output = child:wait_with_output()
	if output and output.status.success then
		local out = trim(output.stdout or "")
		if out ~= "" then
			return out
		end
	end
end

local function exec_ps(script)
	local prefix = table.concat({
		"$utf8 = New-Object System.Text.UTF8Encoding $false",
		"[Console]::OutputEncoding = $utf8",
		"$OutputEncoding = $utf8",
	}, "; ")
	local child, err = Command("timeout")
		:arg({ "--kill-after=2s", "8s", "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", prefix .. "; " .. script })
		:stdin(Command.NULL)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:spawn()
	if not child then
		return nil, tostring(err), 127
	end

	local output, wait_err = child:wait_with_output()
	if not output then
		return nil, tostring(wait_err), 127
	end

	local stdout = trim(output.stdout or "")
	local stderr = trim(output.stderr or "")
	local code = output.status.code or 1
	debug_log("powershell exit=" .. tostring(code) .. " stdout=" .. stdout .. " stderr=" .. stderr)
	if output.status.success then
		return stdout, stderr, 0
	end
	return nil, stderr ~= "" and stderr or stdout, code
end

local function path_to_windows(path)
	local drive, rest = tostring(path):match("^/mnt/([a-zA-Z])/(.*)$")
	if drive then
		return drive:upper() .. ":\\" .. rest:gsub("/", "\\")
	end
	local out = exec_capture("wslpath", { "-w", tostring(path) }, "3s")
	if out then
		return out
	end
	return path
end

local function path_to_wsl(path)
	path = tostring(path or "")
	if path:sub(1, 1) == "/" then
		return path
	end
	if path:sub(1, 8) == "\\\\?\\UNC\\" then
		path = "\\\\" .. path:sub(9)
	elseif path:sub(1, 4) == "\\\\?\\" then
		path = path:sub(5)
	end

	local out = exec_capture("wslpath", { "-u", path }, "3s")
	if out then
		return out
	end

	if path:match("^\\\\wsl%.localhost\\") then
		local mapped = path:gsub("^\\\\wsl%.localhost\\[^\\]+", "")
		mapped = mapped:gsub("\\", "/")
		return mapped ~= "" and mapped or "/"
	end
	if path:lower():match("^\\\\wsl%.localhost\\") then
		local mapped = path:gsub("^\\\\[^\\]+\\[^\\]+", "")
		mapped = mapped:gsub("\\", "/")
		return mapped ~= "" and mapped or "/"
	end
	if path:match("^\\\\wsl%$\\") then
		local mapped = path:gsub("^\\\\wsl%$\\[^\\]+", "")
		mapped = mapped:gsub("\\", "/")
		return mapped ~= "" and mapped or "/"
	end
	return path:gsub("\\", "/"):gsub("^([A-Za-z]):/", function(d)
		return "/mnt/" .. d:lower() .. "/"
	end)
end

local function has_path_separator(name)
	return name:find("/", 1, true) ~= nil or name:find("\\", 1, true) ~= nil
end

local function has_extension(name)
	return name:match("%.([^.]+)$") ~= nil
end

local function prepare_path(dir, name, force)
	if force then
		return dir .. "/" .. name
	end
	local file = fs.unique("file", Url(dir .. "/" .. name))
	return tostring(file or (dir .. "/" .. name))
end

local function basename(path)
	local cleaned = tostring(path or ""):gsub("[/\\]+$", "")
	return cleaned:match("[^/\\]+$") or cleaned
end

local function is_dir(path)
	local child = Command("test")
		:arg({ "-d", tostring(path) })
		:stdin(Command.NULL)
		:stdout(Command.NULL)
		:stderr(Command.NULL)
		:spawn()
	if not child then
		return false
	end
	local status = child:wait()
	return status and status.success == true
end

local function unique_target(cwd, src)
	local name = basename(src)
	if name == "" then
		return cwd
	end
	local kind = is_dir(src) and "dir" or "file"
	local target = fs.unique(kind, Url(cwd .. "/" .. name))
	return tostring(target or (cwd .. "/" .. name))
end

local function current_cwd()
	local ok, cwd = pcall(current_cwd_sync)
	if ok and cwd and cwd ~= "" then
		return cwd
	end
	return nil, "failed to read Yazi cwd: " .. tostring(cwd)
end

local function write_files(paths, cut)
	if #paths == 0 then
		return true
	end

	local lines = {
		"Add-Type -AssemblyName System.Windows.Forms",
		"$d = New-Object System.Windows.Forms.DataObject",
		"$l = New-Object System.Collections.Specialized.StringCollection",
	}
	for _, path in ipairs(paths) do
		lines[#lines + 1] = "$l.Add('" .. quote_ps(path) .. "') | Out-Null"
	end
	lines[#lines + 1] = "$d.SetFileDropList($l)"
	lines[#lines + 1] = cut and "$effect = [byte[]](2,0,0,0)" or "$effect = [byte[]](1,0,0,0)"
	lines[#lines + 1] = "$ms = New-Object System.IO.MemoryStream(,$effect)"
	lines[#lines + 1] = "$d.SetData('Preferred DropEffect', $ms)"
	lines[#lines + 1] = "[System.Windows.Forms.Clipboard]::SetDataObject($d, $true)"

	local _, err, code = exec_ps(ps_join(lines))
	return code == 0, err
end

local function clear_clipboard()
	local _, err, code = exec_ps("Clear-Clipboard")
	return code == 0, err
end

local function read_paste()
	local script = ps_join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"$d = [System.Windows.Forms.Clipboard]::GetDataObject()",
		"if (-not $d) { exit 0 }",
		"if ($d.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop)) {",
		"  Write-Output '__kind__:files'",
		"  if ($d.GetDataPresent('Preferred DropEffect')) {",
		"    $v = $d.GetData('Preferred DropEffect')",
		"    if ($v -is [System.IO.MemoryStream]) {",
		"      $v.Position = 0; $b = New-Object byte[] 4; $null = $v.Read($b, 0, 4); $effect = [BitConverter]::ToInt32($b, 0)",
		"    } elseif ($v -is [byte[]]) {",
		"      $effect = [BitConverter]::ToInt32($v, 0)",
		"    } else {",
		"      $effect = 1",
		"    }",
		"  } else {",
		"    $effect = 1",
		"  }",
		"  Write-Output ('__effect__:' + $(if ($effect -eq 2) { 'move' } else { 'copy' }))",
		"  $d.GetFileDropList() | ForEach-Object { Write-Output $_ }",
		"  exit 0",
		"}",
		"if ($d.GetDataPresent([System.Windows.Forms.DataFormats]::Html)) { Write-Output '__kind__:html'; exit 0 }",
	})

	local out, err, code = exec_ps(script)
	debug_log("read_paste code=" .. tostring(code) .. " out=" .. tostring(out) .. " err=" .. tostring(err))
	if code ~= 0 then
		return nil, nil, err
	end
	if not out or out == "" then
		return nil
	end

	local first = out:match("^([^\n]+)")
	local kind = first and first:match("^__kind__:(.+)$")
	if kind == "files" then
		local effect = out:match("\n__effect__:(.-)\n")
		last_effect = effect == "move" and "move" or "copy"
		local files = {}
		local body = out:gsub("^__kind__:files\n", "", 1):gsub("^__effect__:[^\n]*\n", "", 1)
		for line in body:gmatch("[^\n]+") do
			files[#files + 1] = line
		end
		return #files > 0 and "files" or nil, files
	elseif kind == "html" then
		return "html", true
	end

	return nil
end

local function probe_image()
	local script = ps_join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"Add-Type -AssemblyName System.Drawing",
		"$d = [System.Windows.Forms.Clipboard]::GetDataObject()",
		"if (-not $d) { exit 0 }",
			"if ($d.GetDataPresent('PNG'))  { Write-Output 'png'; exit 0 }",
			"if ($d.GetDataPresent('JFIF')) { Write-Output 'jpg'; exit 0 }",
			"if ($d.GetDataPresent('GIF'))  { Write-Output 'gif'; exit 0 }",
			"if ($d.GetDataPresent('TIFF')) { Write-Output 'tiff'; exit 0 }",
			"if ($d.GetDataPresent('DeviceIndependentBitmap') -or $d.GetDataPresent('Format17')) { Write-Output 'bmp'; exit 0 }",
			"$bitmap = $d.GetData([System.Windows.Forms.DataFormats]::Bitmap)",
			"if ($bitmap -is [System.Drawing.Image]) { Write-Output 'bmp'; exit 0 }",
			"$img = [System.Windows.Forms.Clipboard]::GetImage()",
			"if ($img) {",
			"  Write-Output 'png'",
			"}",
		})

	local out, err, code = exec_ps(script)
	if code ~= 0 then
		return nil, err
	end
	out = trim(out)
	return out ~= "" and out:lower() or nil
end

local function save_html(dst)
	local script = ps_join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"$d = [System.Windows.Forms.Clipboard]::GetDataObject()",
		"if (-not $d) { throw 'No clipboard data object' }",
		"if (-not $d.GetDataPresent([System.Windows.Forms.DataFormats]::Html)) { throw 'No html in clipboard' }",
			"$raw = [string]$d.GetData([System.Windows.Forms.DataFormats]::Html)",
			"$m = [regex]::Match($raw, 'StartHTML:(\\d+).*?EndHTML:(\\d+)', [System.Text.RegularExpressions.RegexOptions]::Singleline)",
			"if ($m.Success) {",
			"  $start = [int]$m.Groups[1].Value; $end = [int]$m.Groups[2].Value",
			"  $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)",
			"  if ($start -ge 0 -and $end -gt $start -and $end -le $bytes.Length) { $raw = [System.Text.Encoding]::UTF8.GetString($bytes, $start, $end - $start) }",
			"} elseif ($raw -match '(<html[\\s\\S]*</html>)') {",
			"  $raw = $Matches[1]",
			"}",
		"[System.IO.File]::WriteAllText('" .. quote_ps(dst) .. "', $raw, [System.Text.Encoding]::UTF8)",
	})
	local _, err, code = exec_ps(script)
	return code == 0, err
end

local function save_image(dst)
	local ext = tostring(dst):match("%.([^.\\/:]+)$")
	if not ext then
		return false, "missing file extension"
	end

	local script = ps_join({
		"Add-Type -AssemblyName System.Windows.Forms",
		"Add-Type -AssemblyName System.Drawing",
		"$d = [System.Windows.Forms.Clipboard]::GetDataObject()",
		"if (-not $d) { throw 'No clipboard data object' }",
			"function Save-RawBytes($formatName, $path) {",
			"  if (-not $d.GetDataPresent($formatName)) { return $false }",
			"  $data = $d.GetData($formatName)",
			"  if ($data -is [System.IO.MemoryStream]) { [System.IO.File]::WriteAllBytes($path, $data.ToArray()); return $true }",
			"  if ($data -is [byte[]]) { [System.IO.File]::WriteAllBytes($path, $data); return $true }",
			"  return $false",
			"}",
			"function Get-ClipboardBytes($formatName) {",
			"  if (-not $d.GetDataPresent($formatName)) { return $null }",
			"  $data = $d.GetData($formatName)",
			"  if ($data -is [System.IO.MemoryStream]) { return $data.ToArray() }",
			"  if ($data -is [byte[]]) { return $data }",
			"  return $null",
			"}",
			"function Save-ImageObject($obj, $path, $fmt) {",
			"  if ($obj -is [System.Drawing.Image]) { $obj.Save($path, $fmt); return $true }",
			"  return $false",
			"}",
			"function Save-DibAsBmp($formatName, $path) {",
			"  $dib = Get-ClipboardBytes $formatName",
			"  if (-not $dib -or $dib.Length -lt 40) { return $false }",
			"  $headerSize = [BitConverter]::ToInt32($dib, 0)",
			"  if ($headerSize -le 0 -or $headerSize -gt $dib.Length) { return $false }",
			"  $bitCount = [BitConverter]::ToUInt16($dib, 14)",
			"  $compression = if ($dib.Length -ge 20) { [BitConverter]::ToInt32($dib, 16) } else { 0 }",
			"  $clrUsed = if ($dib.Length -ge 36) { [BitConverter]::ToInt32($dib, 32) } else { 0 }",
			"  $paletteEntries = 0",
			"  if ($bitCount -le 8) { $paletteEntries = if ($clrUsed -gt 0) { $clrUsed } else { [int][Math]::Pow(2, $bitCount) } }",
			"  $extraMasks = 0",
			"  if ($headerSize -eq 40 -and ($compression -eq 3 -or $compression -eq 6)) { $extraMasks = if ($compression -eq 6) { 16 } else { 12 } }",
			"  $offBits = 14 + $headerSize + $extraMasks + (4 * $paletteEntries)",
			"  if ($offBits -gt 14 + $dib.Length) { $offBits = 14 + $headerSize }",
			"  $fileSize = 14 + $dib.Length",
			"  $bmp = New-Object byte[] $fileSize",
			"  $bmp[0] = 0x42; $bmp[1] = 0x4d",
			"  [BitConverter]::GetBytes([int]$fileSize).CopyTo($bmp, 2)",
			"  [BitConverter]::GetBytes([int]0).CopyTo($bmp, 6)",
			"  [BitConverter]::GetBytes([int]$offBits).CopyTo($bmp, 10)",
			"  [Array]::Copy($dib, 0, $bmp, 14, $dib.Length)",
			"  [System.IO.File]::WriteAllBytes($path, $bmp)",
			"  return $true",
			"}",
			"$dst = '" .. quote_ps(dst) .. "'",
			"$ext = '" .. quote_ps(ext:lower()) .. "'",
			"switch ($ext) {",
			"  'png'  { if (Save-RawBytes 'PNG' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Png }",
			"  'jpg'  { if (Save-RawBytes 'JFIF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Jpeg }",
		"  'jpeg' { if (Save-RawBytes 'JFIF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Jpeg }",
			"  'gif'  { if (Save-RawBytes 'GIF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Gif }",
			"  'tif'  { if (Save-RawBytes 'TIFF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Tiff }",
			"  'tiff' { if (Save-RawBytes 'TIFF' $dst) { exit 0 }; $fmt = [System.Drawing.Imaging.ImageFormat]::Tiff }",
			"  'bmp'  {",
			"    $fmt = [System.Drawing.Imaging.ImageFormat]::Bmp",
			"    if (Save-ImageObject ($d.GetData([System.Windows.Forms.DataFormats]::Bitmap)) $dst $fmt) { exit 0 }",
			"    if (Save-DibAsBmp 'Format17' $dst) { exit 0 }",
			"    if (Save-DibAsBmp 'DeviceIndependentBitmap' $dst) { exit 0 }",
			"  }",
			"  default { throw ('Unsupported image extension: ' + $ext) }",
			"}",
		"$img = [System.Windows.Forms.Clipboard]::GetImage()",
		"if (-not $img) { throw 'No image in clipboard' }",
		"$img.Save($dst, $fmt)",
	})

	local _, err, code = exec_ps(script)
	return code == 0, err
end

local function sync_yanked_state()
	local state = yanked_state_sync()
	local paths = {}
	for _, url in ipairs(state.paths or {}) do
		paths[#paths + 1] = path_to_windows(url)
	end
	if #paths == 0 then
		return
	end
	local ok, err = write_files(paths, state.cut == true)
	if not ok then
		ya.notify { title = "Clipboard", content = "Failed to sync file list: " .. tostring(err), level = "error", timeout = 5 }
	end
end

local function paste_files(paths, force)
	debug_log("paste_files enter")
	local cwd, cwd_err = current_cwd()
	if not cwd then
		return nil, cwd_err
	end
	debug_log("paste_files cwd_raw=" .. tostring(cwd))
	local mode = last_effect == "move" and "mv" or "cp"
	local base_args = mode == "cp" and (force and { "-af" } or { "-a" }) or (force and { "-f" } or { "-n" })
	debug_log("paste_files cwd=" .. tostring(cwd) .. " mode=" .. mode .. " count=" .. tostring(#paths))

	for _, path in ipairs(paths) do
		local src = path_to_wsl(path)
		local dst = force and cwd or unique_target(cwd, src)
		debug_log("paste_file src=" .. tostring(src) .. " raw=" .. tostring(path))
		local argv = {}
		for _, arg in ipairs(base_args) do
			argv[#argv + 1] = arg
		end
		argv[#argv + 1] = "--"
		argv[#argv + 1] = src
		argv[#argv + 1] = dst

		local child, err = Command(mode)
			:arg(argv)
			:cwd(cwd)
			:stdin(Command.NULL)
			:stdout(Command.NULL)
			:stderr(Command.NULL)
			:spawn()
		if not child then
			debug_log("paste_file spawn failed=" .. tostring(err))
			return nil, tostring(err)
		end
		local status = child:wait()
		debug_log("paste_file status=" .. tostring(status and status.code) .. " success=" .. tostring(status and status.success))
		if not status or not status.success then
			return nil, "command failed"
		end
	end

	ya.emit("refresh", {})
	return true
end

local function paste_html(force)
	local cwd, cwd_err = current_cwd()
	if not cwd then
		return nil, cwd_err
	end
	local dst = prepare_path(cwd, "clipboard.html", force)
	local ok, err = save_html(path_to_windows(dst))
	if not ok then
		return nil, err
	end
	ya.emit("refresh", {})
	ya.emit("reveal", { Url(dst), raw = true })
	return true
end

local function image_entry(force, ext, probe_err)
	if ext == nil then
		ext, probe_err = probe_image()
	end
	if not ext or ext == "" then
		if probe_err then
			return ya.notify { title = "Clipboard", content = "Failed to probe image: " .. tostring(probe_err), level = "error", timeout = 5 }
		end
		return ya.notify { title = "Clipboard", content = "No image in clipboard", level = "warn", timeout = 3 }
	end

	local value, event = ya.input {
		pos = { "top-center", y = 2, w = 60 },
		title = "Save clipboard image as:",
		value = os.date("clipboard-%Y%m%d-%H%M%S") .. "." .. ext,
	}
	if event ~= 1 then
		return
	end

	local name = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		name = os.date("clipboard-%Y%m%d-%H%M%S") .. "." .. ext
	elseif has_path_separator(name) then
		return ya.notify { title = "Clipboard", content = "File name cannot contain path separators", level = "error", timeout = 5 }
	elseif not has_extension(name) then
		name = name .. "." .. ext
	end

	local cwd, cwd_err = current_cwd()
	if not cwd then
		return ya.notify { title = "Clipboard", content = tostring(cwd_err), level = "error", timeout = 5 }
	end
	local dst = prepare_path(cwd, name, force)
	local ok, err = save_image(path_to_windows(dst))
	if not ok then
		return ya.notify { title = "Clipboard", content = "Failed to save image: " .. tostring(err), level = "error", timeout = 5 }
	end

	ya.emit("refresh", {})
	ya.emit("reveal", { Url(dst), raw = true })
end

local function paste(force)
	local kind, payload, err = read_paste()
	debug_log("paste kind=" .. tostring(kind) .. " err=" .. tostring(err))
	if kind == "files" then
		local ok, file_err = paste_files(payload, force)
		if not ok then
			ya.notify { title = "Clipboard", content = tostring(file_err), level = "error", timeout = 5 }
		end
	elseif kind == "html" then
		local ext = probe_image()
		if ext then
			return image_entry(force, ext)
		end
		local ok, html_err = paste_html(force)
		if not ok then
			ya.notify { title = "Clipboard", content = tostring(html_err), level = "error", timeout = 5 }
		end
	elseif err then
		ya.notify { title = "Clipboard", content = "Clipboard probe failed: " .. tostring(err), level = "error", timeout = 5 }
	else
		local ext, probe_err = probe_image()
		if probe_err then
			return ya.notify { title = "Clipboard", content = "Failed to probe image: " .. tostring(probe_err), level = "error", timeout = 5 }
		end
		if ext then
			return image_entry(force, ext)
		end
		return
	end
end

function M:entry(job)
	local args = job.args or {}
	local cmd = args[1]
	local force = args.force == true
	debug_log("entry " .. describe_args(args))

	if cmd == "sync" then
		return sync_yanked_state()
	elseif cmd == "paste" then
		return paste(force)
	elseif cmd == "image" then
		return image_entry(force)
	elseif cmd == "clear" then
		local ok, err = clear_clipboard()
		if not ok then
			ya.notify { title = "Clipboard", content = "Failed to clear system clipboard: " .. tostring(err), level = "error", timeout = 5 }
		end
		return
	end

	ya.notify { title = "Clipboard", content = "Unknown command: " .. tostring(cmd), level = "error", timeout = 5 }
end

return M
