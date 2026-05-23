local image = require(".image")
local paste = require(".paste")
local util = require(".util")
local yank = require(".yank")

local M = {}

function M:entry(job)
	local args = job.args or {}
	local cmd = args[1]
	util.debug_log("entry " .. util.describe_args(args))

	if cmd == "sync" then
		local cut_hint = args.cut == true and true or args.copy == true and false or nil
		return yank.sync(cut_hint)
	elseif cmd == "toggle" then
		local cut_hint = args.cut == true and true or false
		return yank.toggle(cut_hint)
	elseif cmd == "paste" then
		return paste.entry()
	elseif cmd == "image" then
		return image.entry()
	end

	util.notify_error("Unknown command: " .. tostring(cmd))
end

return M
