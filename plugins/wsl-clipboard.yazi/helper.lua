local process = require(".process")
local util = require(".util")

local M = {}

local MAX_ARG_PAYLOAD = 24 * 1024
local BASE64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function trim_trailing_slash(path)
	return tostring(path or ""):gsub("[/\\]+$", "")
end

local function normalize_exe_path(path)
	path = tostring(path or "")
	local drive, rest = path:match("^([A-Za-z]):[/\\](.*)$")
	if drive then
		return "/mnt/" .. drive:lower() .. "/" .. rest:gsub("\\", "/")
	end
	return path
end

local function file_exists(path)
	local f = io and io.open and io.open(path, "rb")
	if not f then
		return false
	end
	f:close()
	return true
end

local function read_file(path)
	local f = io and io.open and io.open(path, "rb")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()
	return content
end

local function config_dir()
	local explicit = os.getenv("YAZI_CONFIG_HOME")
	if explicit and explicit ~= "" then
		return trim_trailing_slash(explicit)
	end
	local xdg = os.getenv("XDG_CONFIG_HOME")
	if xdg and xdg ~= "" then
		return trim_trailing_slash(xdg) .. "/yazi"
	end
	local home = os.getenv("HOME")
	if home and home ~= "" then
		return trim_trailing_slash(home) .. "/.config/yazi"
	end
end

local function trace_enabled()
	local value = os.getenv("WSL_CLIPBOARD_HELPER_TRACE")
	if value == "1" or value == "true" or value == "yes" then
		return true
	end
	return os.getenv("WSL_CLIPBOARD_DEBUG") == "1"
end

function M.path()
	local explicit = os.getenv("WSL_CLIPBOARD_YAZI_HELPER")
	if explicit and explicit ~= "" then
		return normalize_exe_path(explicit)
	end

	local cfg = config_dir()
	if not cfg then
		return nil
	end
	local plugin_dir = cfg .. "/plugins/wsl-clipboard.yazi"
	local candidates = {
		plugin_dir .. "/bin/wsl-clipboard-yazi.exe",
		plugin_dir .. "/bin/wsl-clipboard-yazi",
	}
	for _, candidate in ipairs(candidates) do
		if file_exists(candidate) then
			return candidate
		end
	end
	return nil
end

local function describe_command(exe, args)
	local out = { exe }
	local redact_next = false
	for _, arg in ipairs(args or {}) do
		if redact_next then
			out[#out + 1] = "<base64:" .. tostring(#tostring(arg)) .. ">"
			redact_next = false
		else
			out[#out + 1] = tostring(arg)
			redact_next = arg == "--payload-base64"
		end
	end
	return table.concat(out, " ")
end

local function serialize_paths(paths)
	local out = {}
	for _, item in ipairs(paths or {}) do
		local value = tostring(item)
		if value:find("\0", 1, true) then
			return nil, "path contains NUL byte"
		end
		out[#out + 1] = value
		out[#out + 1] = "\0"
	end
	return table.concat(out), nil
end

local function base64_encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a = data:byte(i) or 0
		local b = data:byte(i + 1) or 0
		local c = data:byte(i + 2) or 0
		local n = a * 65536 + b * 256 + c
		local c1 = math.floor(n / 262144) % 64
		local c2 = math.floor(n / 4096) % 64
		local c3 = math.floor(n / 64) % 64
		local c4 = n % 64

		out[#out + 1] = BASE64:sub(c1 + 1, c1 + 1)
		out[#out + 1] = BASE64:sub(c2 + 1, c2 + 1)
		if i + 1 > #data then
			out[#out + 1] = "=="
		elseif i + 2 > #data then
			out[#out + 1] = BASE64:sub(c3 + 1, c3 + 1)
			out[#out + 1] = "="
		else
			out[#out + 1] = BASE64:sub(c3 + 1, c3 + 1)
			out[#out + 1] = BASE64:sub(c4 + 1, c4 + 1)
		end
	end
	return table.concat(out)
end

local function encode_paths(paths)
	local payload, payload_err = serialize_paths(paths)
	if not payload then
		return nil, payload_err, 127
	end

	local encoded = base64_encode(payload)
	if #encoded > MAX_ARG_PAYLOAD then
		return nil, "Clipboard payload too large for argv transport (" .. tostring(#encoded) .. " bytes)", 123
	end
	return encoded, nil, 0
end

local function is_windows_exe(path)
	return tostring(path or ""):lower():match("%.exe$") ~= nil
end

local function interop_available(exe)
	if not is_windows_exe(exe) then
		return true
	end

	local binfmt = read_file("/proc/sys/fs/binfmt_misc/WSLInterop")
	if not binfmt then
		return false, "WSL interop is unavailable: /proc/sys/fs/binfmt_misc/WSLInterop is missing"
	end
	if binfmt:match("disabled") or not binfmt:match("enabled") then
		return false, "WSL interop is unavailable: WSLInterop binfmt is disabled"
	end
	return true
end

local function build_args(args, include_trace)
	local out = {}
	if include_trace and trace_enabled() then
		out[#out + 1] = "--trace"
	end
	for _, arg in ipairs(args or {}) do
		out[#out + 1] = arg
	end
	return out
end

local function executable()
	local exe = M.path()
	if not exe then
		return nil, "helper not installed", 127
	end
	local interop_ok, interop_err = interop_available(exe)
	if not interop_ok then
		return nil, interop_err, 126
	end
	return exe
end

local function run_capture(args)
	local exe, err, code = executable()
	if not exe then
		return nil, err, code
	end

	local argv = build_args(args, true)
	util.debug_log("helper spawn mode=capture")
	util.debug_log("helper command=" .. describe_command(exe, argv))
	local out
	out, err, code = process.exec_direct(exe, argv)
	util.debug_log("helper exit=" .. tostring(code) .. " stdout=" .. tostring(out) .. " stderr=" .. tostring(err))
	return out, err, code
end

local function run_status(args)
	local exe, err, code = executable()
	if not exe then
		return nil, err, code
	end

	local argv = build_args(args, false)
	util.debug_log("helper spawn mode=direct-status")
	util.debug_log("helper command=" .. describe_command(exe, argv))
	local out
	out, err, code = process.exec_status_timeout(exe, argv, "2s")
	util.debug_log("helper status code=" .. tostring(code) .. " stderr=" .. tostring(err))
	return out, err, code
end

local function run_argv_dispatch(args)
	local exe, err, code = executable()
	if not exe then
		return nil, err, code
	end

	local argv = build_args(args, true)
	util.debug_log("helper spawn mode=shell-background-argv")
	util.debug_log("helper command=" .. describe_command(exe, argv))
	local out
	out, err, code = process.exec_background(exe, argv)
	util.debug_log("helper dispatch code=" .. tostring(code) .. " stderr=" .. tostring(err))
	if out and out ~= "" then
		util.debug_log("helper dispatch stdout=" .. tostring(out))
	end
	return out, err, code
end

function M.write_files(paths, cut)
	local payload, payload_err, payload_code = encode_paths(paths)
	if not payload then
		return false, payload_err, payload_code
	end
	local args = { "write-files", cut and "--cut" or "--copy", "--payload-base64", payload }
	local _, err, code = run_argv_dispatch(args)
	return code == 0, err, code
end

function M.clear()
	local _, err, code = run_status({ "clear" })
	return code == 0, err, code
end

function M.clear_owned(paths, cut)
	local payload, payload_err, payload_code = encode_paths(paths)
	if not payload then
		return false, payload_err, payload_code
	end
	local args = { "clear-owned", cut and "--cut" or "--copy", "--payload-base64", payload }
	local _, err, code = run_argv_dispatch(args)
	return code == 0, err, code
end

function M.diagnose()
	return run_capture({ "diagnose" })
end

function M.read_paste()
	local out, err, code = run_capture({ "read-paste" })
	if code ~= 0 then
		return nil, err, code
	end
	return out or "", nil, 0
end

function M.probe_image()
	local out, err, code = run_capture({ "probe-image" })
	if code ~= 0 then
		return nil, err, code
	end
	return util.trim(out or ""), nil, 0
end

return M
