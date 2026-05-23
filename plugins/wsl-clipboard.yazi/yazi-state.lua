local M = {}

local current_cwd_sync = ya.sync(function()
	return tostring(cx.active.current.cwd)
end)

local yanked_state_sync = ya.sync(function()
	local state = { paths = {}, cut = false }
	for _, url in pairs(cx.yanked) do
		state.paths[#state.paths + 1] = tostring(url)
	end
	local cut = cx.yanked.is_cut
	if cut == nil then
		cut = cx.yanked.cut
	end
	state.cut = cut == true
	if #state.paths == 0 then
		for _, url in pairs(cx.active.selected) do
			state.paths[#state.paths + 1] = tostring(url)
		end
		if #state.paths == 0 and cx.active.current.hovered then
			state.paths[#state.paths + 1] = tostring(cx.active.current.hovered.url)
		end
	end
	return state
end)

local yank_snapshot_sync = ya.sync(function()
	local snapshot = { targets = {}, yanked = {}, yanked_cut = false }
	local yanked_lookup = {}

	for _, url in pairs(cx.yanked) do
		local path = tostring(url)
		snapshot.yanked[#snapshot.yanked + 1] = path
		yanked_lookup[path] = true
	end

	for _, url in pairs(cx.active.selected) do
		snapshot.targets[#snapshot.targets + 1] = tostring(url)
	end
	if #snapshot.targets == 0 and cx.active.current.hovered then
		local hovered = tostring(cx.active.current.hovered.url)
		if yanked_lookup[hovered] then
			for _, path in ipairs(snapshot.yanked) do
				snapshot.targets[#snapshot.targets + 1] = path
			end
		else
			snapshot.targets[#snapshot.targets + 1] = hovered
		end
	end
	local cut = cx.yanked.is_cut
	if cut == nil then
		cut = cx.yanked.cut
	end
	snapshot.yanked_cut = cut == true

	return snapshot
end)

function M.current_cwd()
	local ok, cwd = pcall(current_cwd_sync)
	if ok and cwd and cwd ~= "" then
		return cwd
	end
	return nil, "failed to read Yazi cwd: " .. tostring(cwd)
end

function M.yanked_state()
	return yanked_state_sync()
end

function M.yank_snapshot()
	return yank_snapshot_sync()
end

return M
