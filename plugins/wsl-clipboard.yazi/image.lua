local clipboard = require(".win-clipboard")
local file_ops = require(".file-ops")
local state = require(".yazi-state")
local util = require(".util")
local win_path = require(".win-path")

local M = {}

local supported_exts = {
	bmp = true,
	gif = true,
	jpeg = true,
	jpg = true,
	png = true,
	tif = true,
	tiff = true,
}

local function timestamp_name(ext)
	return os.date("clipboard-%Y%m%d-%H%M%S") .. "." .. ext
end

local function normalize_ext(ext)
	return tostring(ext or ""):lower():gsub("^%.", "")
end

local function resolve_name(value, detected_ext)
	detected_ext = normalize_ext(detected_ext)
	local name = (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
	if name == "" then
		return timestamp_name(detected_ext)
	end

	if util.has_path_separator(name) then
		return nil, "File name cannot contain path separators"
	end

	local prefix, requested_ext = name:match("^(.*)%.([^.]+)$")
	if not requested_ext then
		return name .. "." .. detected_ext
	end

	requested_ext = normalize_ext(requested_ext)
	if prefix == "" then
		return nil, "File name prefix cannot be empty"
	end
	if not supported_exts[requested_ext] then
		return nil, "Unsupported image extension: " .. requested_ext
	end

	return prefix .. "." .. requested_ext
end

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
		value = "",
	}
	if event ~= 1 then
		return
	end

	local name, name_err = resolve_name(value, ext)
	if not name then
		return util.notify_error(name_err)
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
