local process = require(".process")
local ps = require(".ps")
local util = require(".util")
local win_path = require(".win-path")

local M = {}

function M.prepare_path(dir, name, overwrite)
	local target = dir .. "/" .. name
	if overwrite then
		return target
	end
	local file = fs.unique("file", Url(target))
	return tostring(file or target)
end

function M.is_dir(path)
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

function M.path_exists(path)
	local child = Command("test")
		:arg({ "-e", tostring(path) })
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

local function numbered_name(name, index, dir)
	if dir then
		return name .. "_" .. tostring(index)
	end

	local stem, ext = name:match("^(.+)%.([^%.]+)$")
	if stem and stem ~= "" then
		return stem .. "_" .. tostring(index) .. "." .. ext
	end
	return name .. "_" .. tostring(index)
end

function M.unique_named_target(cwd, name, dir, reserved)
	if name == "" then
		return cwd
	end
	local target = cwd .. "/" .. name
	if not M.path_exists(target) and not (reserved and reserved[target]) then
		return target
	end

	for i = 1, 10000 do
		target = cwd .. "/" .. numbered_name(name, i, dir)
		if not M.path_exists(target) and not (reserved and reserved[target]) then
			return target
		end
	end
	return cwd .. "/" .. os.date("clipboard-%Y%m%d-%H%M%S") .. "-" .. name
end

function M.unique_target(cwd, src, reserved)
	return M.unique_named_target(cwd, util.basename(src), M.is_dir(src), reserved)
end

function M.normalized_path(path)
	return process.exec_capture("realpath", { "-m", tostring(path) }, "3s") or tostring(path)
end

function M.is_same_or_child(path, parent)
	path = M.normalized_path(path)
	parent = M.normalized_path(parent):gsub("/+$", "")
	return path == parent or path:sub(1, #parent + 1) == parent .. "/"
end

function M.remove_target(path)
	if not M.path_exists(path) then
		return true
	end
	return process.run_wait("rm", { "-rf", "--", tostring(path) })
end

function M.paste_file_with_powershell(raw_src, src, dst, mode, force)
	local ps_src = tostring(raw_src or "")
	if ps_src:sub(1, 1) == "/" then
		local err
		ps_src, err = win_path.to_windows(src)
		if not ps_src then
			return false, err
		end
	end
	local ps_dst, dst_err = win_path.to_windows(dst)
	if not ps_dst then
		return false, dst_err
	end
	local script = ps.join({
		"$ErrorActionPreference = 'Stop'",
		"$src = '" .. ps.quote(ps_src) .. "'",
		"$dst = '" .. ps.quote(ps_dst) .. "'",
		"$overwrite = " .. ps.bool(force),
		"function Ensure-Parent([string]$path) {",
		"  $parent = Split-Path -LiteralPath $path -Parent",
		"  if ($parent -and -not [System.IO.Directory]::Exists($parent)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }",
		"}",
		"function Copy-Path([string]$from, [string]$to, [bool]$overwrite) {",
		"  if ([System.IO.Directory]::Exists($from)) {",
		"    if ([System.IO.File]::Exists($to)) { throw ('Destination exists as a file: ' + $to) }",
		"    if ([System.IO.Directory]::Exists($to) -and -not $overwrite) { throw ('Destination exists: ' + $to) }",
		"    [System.IO.Directory]::CreateDirectory($to) | Out-Null",
		"    Get-ChildItem -LiteralPath $from -Force | ForEach-Object { Copy-Path $_.FullName ([System.IO.Path]::Combine($to, $_.Name)) $overwrite }",
		"  } elseif ([System.IO.File]::Exists($from)) {",
		"    if ([System.IO.Directory]::Exists($to)) { $to = [System.IO.Path]::Combine($to, [System.IO.Path]::GetFileName($from)) }",
		"    if ([System.IO.File]::Exists($to) -and -not $overwrite) { throw ('Destination exists: ' + $to) }",
		"    Ensure-Parent $to",
		"    [System.IO.File]::Copy($from, $to, $overwrite)",
		"  } else {",
		"    throw ('Source not found: ' + $from)",
		"  }",
		"}",
		"function Move-Path([string]$from, [string]$to, [bool]$overwrite) {",
		"  if ([System.IO.Directory]::Exists($from)) {",
		"    if ([System.IO.File]::Exists($to)) { throw ('Destination exists as a file: ' + $to) }",
		"    if ([System.IO.Directory]::Exists($to) -and $overwrite) { [System.IO.Directory]::Delete($to, $true) }",
		"    if ([System.IO.Directory]::Exists($to)) { throw ('Destination exists: ' + $to) }",
		"    Ensure-Parent $to",
		"    try { [System.IO.Directory]::Move($from, $to) } catch { Copy-Path $from $to $overwrite; [System.IO.Directory]::Delete($from, $true) }",
		"  } elseif ([System.IO.File]::Exists($from)) {",
		"    if ([System.IO.Directory]::Exists($to)) { $to = [System.IO.Path]::Combine($to, [System.IO.Path]::GetFileName($from)) }",
		"    if ([System.IO.File]::Exists($to) -and $overwrite) { [System.IO.File]::Delete($to) }",
		"    if ([System.IO.File]::Exists($to)) { throw ('Destination exists: ' + $to) }",
		"    Ensure-Parent $to",
		"    try { [System.IO.File]::Move($from, $to) } catch { Copy-Path $from $to $overwrite; [System.IO.File]::Delete($from) }",
		"  } else {",
		"    throw ('Source not found: ' + $from)",
		"  }",
		"}",
		mode == "mv" and "Move-Path $src $dst $overwrite" or "Copy-Path $src $dst $overwrite",
	})
	local _, err, code = process.exec_ps(script, "600s")
	return code == 0, err
end

function M.paste_file_with_unix(src, dst, mode, cwd)
	if mode == "mv" then
		return process.run_wait("mv", { "--", src, dst }, cwd)
	end
	return process.run_wait("cp", { "-R", "--", src, dst }, cwd)
end

return M
