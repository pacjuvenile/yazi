local clipboard = require(".win-clipboard")
local file_ops = require(".file-ops")
local state = require(".yazi-state")
local util = require(".util")
local win_path = require(".win-path")

local M = {}

function M.entry(ext, probe_err)
	if ext == nil then
		ext, probe_err = clipboard.probe_image()
	end
	if not ext or ext == "" then
		if probe_err then
			return util.notify_error("Failed to probe image: " .. tostring(probe_err))
		end
		return util.notify_warn("No image in clipboard")
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
	elseif util.has_path_separator(name) then
		return util.notify_error("File name cannot contain path separators")
	elseif not util.has_extension(name) then
		name = name .. "." .. ext
	end

	local cwd, cwd_err = state.current_cwd()
	if not cwd then
		return util.notify_error(cwd_err)
	end
	local base = cwd .. "/" .. name
	local overwrite = file_ops.path_exists(base) and util.confirm_overwrite({ base })
	local dst = file_ops.prepare_path(cwd, name, overwrite)
	if overwrite then
		local removed, remove_err = file_ops.remove_target(dst)
		if not removed then
			return util.notify_error("Failed to remove existing target: " .. tostring(remove_err))
		end
	end
	local win_dst, path_err = win_path.to_windows(dst)
	if not win_dst then
		return util.notify_error("Failed to convert image path: " .. tostring(path_err))
	end
	local ok, err = clipboard.save_image(win_dst)
	if not ok then
		return util.notify_error("Failed to save image: " .. tostring(err))
	end

	ya.emit("refresh", {})
	ya.emit("reveal", { Url(dst), raw = true })
end

return M
