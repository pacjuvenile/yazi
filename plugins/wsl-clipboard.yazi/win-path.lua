local process = require(".process")

local M = {}

function M.to_windows(path)
	path = tostring(path or "")
	if path:match("^%a:[/\\]") or path:match("^\\\\") then
		return path
	end

	local drive, rest = path:match("^/mnt/([a-zA-Z])/(.*)$")
	if drive then
		return drive:upper() .. ":\\" .. rest:gsub("/", "\\")
	end

	local distro = os.getenv("WSL_DISTRO_NAME") or os.getenv("WSL_DISTRO")
	if path:sub(1, 1) == "/" and distro and distro ~= "" then
		return "\\\\wsl$\\" .. distro .. path:gsub("/", "\\")
	end

	local out = process.exec_capture("wslpath", { "-w", path }, "3s")
	if out and (out:match("^%a:[/\\]") or out:match("^\\\\")) then
		return out
	end

	return nil, "failed to convert path to a Windows-visible path: " .. path
end

function M.to_wsl(path)
	path = tostring(path or "")
	if path:sub(1, 1) == "/" then
		return path
	end
	if path:sub(1, 8) == "\\\\?\\UNC\\" then
		path = "\\\\" .. path:sub(9)
	elseif path:sub(1, 4) == "\\\\?\\" then
		path = path:sub(5)
	end

	local out = process.exec_capture("wslpath", { "-u", path }, "3s")
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

return M
