local M = {}

function M.trim(s)
	return (tostring(s or ""):gsub("\r\n", "\n"):gsub("\n+$", ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.debug_log(message)
	if os.getenv("WSL_CLIPBOARD_DEBUG") == "1" then
		ya.err("wsl-clipboard: " .. tostring(message))
	end
end

function M.describe_args(args)
	local out = {}
	for k, v in pairs(args or {}) do
		out[#out + 1] = tostring(k) .. "=" .. tostring(v)
	end
	table.sort(out)
	return table.concat(out, ",")
end

function M.has_path_separator(name)
	return name:find("/", 1, true) ~= nil or name:find("\\", 1, true) ~= nil
end

function M.has_extension(name)
	return name:match("%.([^.]+)$") ~= nil
end

function M.basename(path)
	local cleaned = tostring(path or ""):gsub("[/\\]+$", "")
	return cleaned:match("[^/\\]+$") or cleaned
end

local function format_target_list(paths)
	local lines = {}
	for i, path in ipairs(paths or {}) do
		if i > 5 then
			lines[#lines + 1] = "... and " .. tostring(#paths - 5) .. " more"
			break
		end
		lines[#lines + 1] = M.basename(path)
	end
	return table.concat(lines, "\n")
end

function M.confirm_overwrite(paths)
	local count = #(paths or {})
	if count == 0 then
		return false
	end

	local title = count == 1 and "Overwrite existing item?" or ("Overwrite " .. tostring(count) .. " existing items?")
	local list = format_target_list(paths)
	local body = list
		.. "\n\n"
		.. "Yes: overwrite existing targets\n"
		.. "No: create _1/_2 copies"

	return ya.confirm {
		pos = { "top-center", y = 2, w = 64 },
		title = title,
		body = body,
	} == true
end

function M.same_path_set(left, right)
	if #left ~= #right then
		return false
	end

	local counts = {}
	for _, path in ipairs(left) do
		counts[path] = (counts[path] or 0) + 1
	end
	for _, path in ipairs(right) do
		local count = counts[path]
		if not count then
			return false
		end
		if count == 1 then
			counts[path] = nil
		else
			counts[path] = count - 1
		end
	end
	return true
end

function M.notify_error(content)
	ya.notify { title = "Clipboard", content = tostring(content), level = "error", timeout = 5 }
end

function M.notify_warn(content)
	ya.notify { title = "Clipboard", content = tostring(content), level = "warn", timeout = 3 }
end

return M
