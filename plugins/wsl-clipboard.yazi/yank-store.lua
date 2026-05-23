local process = require(".process")
local util = require(".util")

local M = {}

local function trim_trailing_slash(path)
	return tostring(path or ""):gsub("/+$", "")
end

local function state_dir()
	local base = os.getenv("XDG_RUNTIME_DIR") or os.getenv("TMPDIR") or "/tmp"
	return trim_trailing_slash(base) .. "/wsl-clipboard.yazi"
end

local function app_id()
	if ya and ya.id then
		local ok, id = pcall(ya.id, "app")
		if ok and id ~= nil then
			local value_ok, value = pcall(function()
				return id.value
			end)
			if value_ok and value ~= nil then
				return tostring(value)
			end
			return tostring(id)
		end
	end
	return os.getenv("YAZI_ID") or os.getenv("YAZI_PID") or "default"
end

local function state_path()
	local id = app_id():gsub("[^%w_.-]", "_")
	return state_dir() .. "/yank-" .. id .. ".state"
end

local function escape(value)
	return tostring(value or ""):gsub("%%", "%%25"):gsub("\r", "%%0D"):gsub("\n", "%%0A")
end

local function unescape(value)
	return tostring(value or ""):gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)
end

local function ensure_dir()
	local ok, err = process.run_wait("mkdir", { "-p", state_dir() })
	if not ok then
		return false, err
	end
	return true
end

local function open_file(path, mode)
	if not io or not io.open then
		return nil, "io.open is not available"
	end
	return io.open(path, mode)
end

function M.read()
	local file = open_file(state_path(), "rb")
	if not file then
		return nil
	end

	local version = file:read("*l")
	if version ~= "v1" then
		file:close()
		return nil
	end

	local state = { paths = {}, cut = false }
	for line in file:lines() do
		if line == "cut=1" then
			state.cut = true
		elseif line == "cut=0" then
			state.cut = false
		elseif line:sub(1, 5) == "path=" then
			state.paths[#state.paths + 1] = unescape(line:sub(6))
		end
	end
	file:close()

	if #state.paths == 0 then
		return nil
	end
	return state
end

local function write_state_file(tmp, paths, cut)
	local file, open_err = open_file(tmp, "wb")
	if not file then
		return false, open_err
	end

	file:write("v1\n")
	file:write(cut and "cut=1\n" or "cut=0\n")
	for _, item in ipairs(paths or {}) do
		file:write("path=", escape(item), "\n")
	end

	local close_ok, close_err = file:close()
	if not close_ok then
		os.remove(tmp)
		return false, close_err
	end
	return true
end

function M.write(paths, cut)
	if #(paths or {}) == 0 then
		return M.clear()
	end

	local path = state_path()
	local tmp = path .. ".tmp"
	local ok, err = write_state_file(tmp, paths, cut)
	if not ok then
		local dir_ok, dir_err = ensure_dir()
		if not dir_ok then
			return false, dir_err
		end
		ok, err = write_state_file(tmp, paths, cut)
		if not ok then
			return false, err
		end
	end

	local rename_ok, rename_err = os.rename(tmp, path)
	if not rename_ok then
		os.remove(tmp)
		return false, rename_err
	end
	return true
end

function M.clear()
	local path = state_path()
	local file = open_file(path, "rb")
	if not file then
		return true
	end
	file:close()

	local ok, err = os.remove(path)
	if not ok then
		util.debug_log("failed to clear yank state file: " .. tostring(err))
	end
	return ok == true, err
end

return M
