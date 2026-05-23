local util = require(".util")

local M = {}

function M.exec_capture(program, args, timeout)
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
		local out = util.trim(output.stdout or "")
		if out ~= "" then
			return out
		end
	end
end

local function output_result(output)
	local stdout = util.trim(output.stdout or "")
	local stderr = util.trim(output.stderr or "")
	local code = output.status.code or 1
	if output.status.success then
		return stdout, stderr, 0
	end
	return nil, stderr ~= "" and stderr or stdout, code
end

function M.exec(program, args, timeout)
	local argv = { "--kill-after=1s", tostring(timeout or "3s"), program }
	for _, arg in ipairs(args or {}) do
		argv[#argv + 1] = arg
	end

	local child, err = Command("timeout")
		:arg(argv)
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
	return output_result(output)
end

function M.exec_direct(program, args)
	local child, err = Command(program)
		:arg(args or {})
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
	return output_result(output)
end

function M.exec_status(program, args)
	local status, err = Command(program)
		:arg(args or {})
		:stdin(Command.NULL)
		:stdout(Command.NULL)
		:stderr(Command.NULL)
		:status()
	if not status then
		return nil, tostring(err), 127
	end
	if status.success then
		return "", "", 0
	end
	local code = status.code or 1
	return nil, "exit " .. tostring(code), code
end

function M.exec_status_timeout(program, args, timeout, cwd)
	local argv = { "--kill-after=1s", tostring(timeout or "3s"), program }
	for _, arg in ipairs(args or {}) do
		argv[#argv + 1] = arg
	end

	local command = Command("timeout")
		:arg(argv)
		:stdin(Command.NULL)
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
	if cwd then
		command:cwd(cwd)
	end

	local child, err = command:spawn()
	if not child then
		return nil, tostring(err), 127
	end

	local output, wait_err = child:wait_with_output()
	if not output then
		return nil, tostring(wait_err), 127
	end

	local stdout = util.trim(output.stdout or "")
	local stderr = util.trim(output.stderr or "")
	if output.status.success then
		return "", "", 0
	end
	local code = output.status.code or 1
	local detail = stderr ~= "" and stderr or stdout
	if code == 124 or code == 137 or code == 143 then
		local message = "exit " .. tostring(code) .. ": " .. tostring(program) .. " timed out after " .. tostring(timeout or "3s")
		if detail ~= "" then
			message = message .. ": " .. detail
		end
		return nil, message, code
	end
	if detail ~= "" then
		return nil, "exit " .. tostring(code) .. ": " .. detail, code
	end
	return nil, "exit " .. tostring(code), code
end

function M.exec_background(program, args)
	local script = table.concat({
		"if [ \"${WSL_CLIPBOARD_DEBUG:-}\" = \"1\" ]; then",
		"  log_dir=\"${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/yazi\"",
		"  mkdir -p \"$log_dir\" 2>/dev/null || true",
		"  log=\"$log_dir/wsl-clipboard-helper.log\"",
		"fi",
		"run_helper() {",
		"  if [ \"${WSL_CLIPBOARD_DEBUG:-}\" = \"1\" ]; then",
		"    \"$@\" </dev/null >> \"$log\" 2>&1",
		"  else",
		"    \"$@\" </dev/null >/dev/null 2>&1",
		"  fi",
		"}",
		"if command -v flock >/dev/null 2>&1; then",
		"  lock_dir=\"${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}\"",
		"  [ -d \"$lock_dir\" ] || lock_dir=\"${TMPDIR:-/tmp}\"",
		"  lock=\"$lock_dir/wsl-clipboard-yazi.lock\"",
		"  ( if flock 9; then run_helper \"$@\"; fi ) 9>\"$lock\" </dev/null >/dev/null 2>&1 &",
		"else",
		"  ( run_helper \"$@\" ) </dev/null >/dev/null 2>&1 &",
		"fi",
	}, "\n")
	local argv = { "-c", script, "wsl-clipboard-yazi-dispatch", program }
	for _, arg in ipairs(args or {}) do
		argv[#argv + 1] = arg
	end

	local child, err = Command("sh")
		:arg(argv)
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
	return output_result(output)
end

function M.exec_ps(script, timeout)
	local prefix = table.concat({
		"$utf8 = New-Object System.Text.UTF8Encoding $false",
		"[Console]::OutputEncoding = $utf8",
		"$OutputEncoding = $utf8",
	}, "; ")
	local child, err = Command("timeout")
		:arg({ "--kill-after=2s", tostring(timeout or "8s"), "powershell.exe", "-NoProfile", "-NonInteractive", "-STA", "-Command", prefix .. "; " .. script })
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

	local stdout = util.trim(output.stdout or "")
	local stderr = util.trim(output.stderr or "")
	local code = output.status.code or 1
	util.debug_log("powershell exit=" .. tostring(code) .. " stdout=" .. stdout .. " stderr=" .. stderr)
	if output.status.success then
		return stdout, stderr, 0
	end
	return nil, stderr ~= "" and stderr or stdout, code
end

function M.run_wait(program, args, cwd)
	local command = Command(program)
		:arg(args)
		:stdin(Command.NULL)
		:stdout(Command.NULL)
		:stderr(Command.PIPED)
	if cwd then
		command:cwd(cwd)
	end
	local child, err = command:spawn()
	if not child then
		return false, tostring(err)
	end
	local output, wait_err = child:wait_with_output()
	if not output then
		return false, tostring(wait_err)
	end
	if output.status.success then
		return true
	end
	local stderr = util.trim(output.stderr or "")
	return false, stderr ~= "" and stderr or ("exit " .. tostring(output.status.code or 1))
end

return M
