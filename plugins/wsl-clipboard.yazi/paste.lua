local clipboard = require(".win-clipboard")
local file_ops = require(".file-ops")
local image = require(".image")
local state = require(".yazi-state")
local util = require(".util")
local win_path = require(".win-path")

local M = {}

local last_effect = "copy"

local function conflict_targets(items)
	local targets = {}
	for _, item in ipairs(items) do
		if file_ops.path_exists(item.base) then
			targets[#targets + 1] = item.base
		end
	end
	return targets
end

local function paste_files(paths)
	util.debug_log("paste_files enter")
	local cwd, cwd_err = state.current_cwd()
	if not cwd then
		return nil, cwd_err
	end
	local mode = last_effect == "move" and "mv" or "cp"
	util.debug_log("paste_files cwd=" .. tostring(cwd) .. " mode=" .. mode .. " count=" .. tostring(#paths))

	local items = {}
	for _, path in ipairs(paths) do
		local src = win_path.to_wsl(path)
		local name = util.basename(src)
		if name == "" then
			return nil, "cannot determine source file name"
		end
		items[#items + 1] = {
			raw = path,
			src = src,
			name = name,
			base = cwd .. "/" .. name,
		}
	end

	local overwrite = false
	local conflicts = conflict_targets(items)
	if not overwrite and #conflicts > 0 then
		overwrite = util.confirm_overwrite(conflicts)
	end

	local reserved = {}
	for _, item in ipairs(items) do
		local dst
		if overwrite and file_ops.path_exists(item.base) and not reserved[item.base] then
			dst = item.base
		else
			dst = file_ops.unique_target(cwd, item.src, reserved)
		end
		reserved[dst] = true

		util.debug_log("paste_file src=" .. tostring(item.src) .. " raw=" .. tostring(item.raw))
		if file_ops.path_exists(item.src) and file_ops.is_same_or_child(dst, item.src) then
			return nil, "cannot paste a directory into itself"
		end

		if dst == item.base and file_ops.path_exists(dst) then
			local removed, remove_err = file_ops.remove_target(dst)
			if not removed then
				return nil, "failed to remove existing target: " .. tostring(remove_err)
			end
		end

		local ok, ps_err = file_ops.paste_file_with_powershell(item.raw, item.src, dst, mode, false)
		if not ok then
			if file_ops.path_exists(dst) then
				file_ops.remove_target(dst)
			end
			local unix_ok, unix_err = file_ops.paste_file_with_unix(item.src, dst, mode, cwd)
			if not unix_ok then
				return nil, "command failed: powershell: " .. tostring(ps_err or "copy/move failed") .. "; unix fallback: " .. tostring(unix_err or "copy/move failed")
			end
		end
	end

	ya.emit("refresh", {})
	return true
end

local function paste_html()
	local cwd, cwd_err = state.current_cwd()
	if not cwd then
		return nil, cwd_err
	end
	local base = cwd .. "/clipboard.html"
	local overwrite = file_ops.path_exists(base) and util.confirm_overwrite({ base })
	local dst = file_ops.prepare_path(cwd, "clipboard.html", overwrite)
	if overwrite then
		local removed, remove_err = file_ops.remove_target(dst)
		if not removed then
			return nil, "failed to remove existing target: " .. tostring(remove_err)
		end
	end
	local win_dst, path_err = win_path.to_windows(dst)
	if not win_dst then
		return nil, path_err
	end
	local ok, err = clipboard.save_html(win_dst)
	if not ok then
		return nil, err
	end
	ya.emit("refresh", {})
	ya.emit("reveal", { Url(dst), raw = true })
	return true
end

function M.entry()
	local kind, payload, err, effect = clipboard.read_paste()
	if effect then
		last_effect = effect
	end
	util.debug_log("paste kind=" .. tostring(kind) .. " err=" .. tostring(err))
	if kind == "files" then
		local ok, file_err = paste_files(payload)
		if not ok then
			util.notify_error(file_err)
		end
	elseif kind == "image" then
		return image.entry(payload)
	elseif kind == "html" then
		local ext = clipboard.probe_image()
		if ext then
			return image.entry(ext)
		end
		local ok, html_err = paste_html()
		if not ok then
			util.notify_error(html_err)
		end
	elseif err then
		util.notify_error("Failed to read Windows clipboard: " .. tostring(err))
	elseif kind == "text" then
		return
	else
		local ext, probe_err = clipboard.probe_image()
		if probe_err then
			return util.notify_error("Failed to probe image: " .. tostring(probe_err))
		end
		if ext then
			return image.entry(ext)
		end
		return
	end
end

return M
