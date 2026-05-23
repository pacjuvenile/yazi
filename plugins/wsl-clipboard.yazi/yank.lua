local clipboard = require(".win-clipboard")
local state = require(".yazi-state")
local store = require(".yank-store")
local util = require(".util")
local win_path = require(".win-path")

local M = {}

local last_yank = { paths = {}, cut = false }

local function copy_paths(paths)
	local copied = {}
	for _, path in ipairs(paths or {}) do
		copied[#copied + 1] = path
	end
	return copied
end

local function remember(paths, cut)
	last_yank = { paths = copy_paths(paths), cut = cut == true }
end

local function persist(paths, cut)
	remember(paths, cut)
	local ok, err = store.write(paths, cut == true)
	if not ok then
		util.notify_warn("Failed to persist yank state: " .. tostring(err))
	end
end

local function contains_path(paths, target)
	for _, path in ipairs(paths or {}) do
		if path == target then
			return true
		end
	end
	return false
end

local function current_stored_yank()
	local stored = store.read()
	if stored then
		return stored
	end
	return last_yank
end

local function resolve_targets(snapshot, stored)
	local targets = snapshot.targets or {}
	if #targets == 1 and #(snapshot.yanked or {}) == 0 and contains_path(stored.paths, targets[1]) then
		return copy_paths(stored.paths)
	end
	return targets
end

local function same_yank(snapshot, targets, cut, stored)
	cut = cut == true
	if snapshot.yanked_cut == cut and util.same_path_set(snapshot.yanked or {}, targets) then
		return true
	end
	return stored.cut == cut and util.same_path_set(stored.paths or {}, targets)
end

local function sync_paths(paths, cut)
	local win_paths = {}
	for _, url in ipairs(paths or {}) do
		local path, err = win_path.to_windows(url)
		if not path then
			util.notify_error("Failed to convert file path: " .. tostring(err))
			return false
		end
		win_paths[#win_paths + 1] = path
	end
	if #win_paths == 0 then
		return true
	end
	local ok, err = clipboard.write_files(win_paths, cut == true)
	if not ok then
		util.notify_error("Failed to sync file list: " .. tostring(err))
		return false
	end
	return true
end

function M.sync(cut_hint)
	local yanked = state.yanked_state()
	if cut_hint ~= nil then
		yanked.cut = cut_hint == true
	end
	local ok = sync_paths(yanked.paths or {}, yanked.cut == true)
	if ok then
		persist(yanked.paths or {}, yanked.cut == true)
	end
	return ok
end

function M.toggle(cut)
	local snapshot = state.yank_snapshot()
	local stored = current_stored_yank()
	local targets = resolve_targets(snapshot, stored)
	if #targets == 0 then
		return
	end

	if same_yank(snapshot, targets, cut, stored) then
		ya.emit("unyank", {})
		M.clear_managed()
		return
	end

	if sync_paths(targets, cut == true) then
		persist(targets, cut == true)
		ya.emit("yank", { cut = cut == true })
	end
end

function M.reset()
	last_yank = { paths = {}, cut = false }
	store.clear()
end

function M.clear_managed()
	local stored = store.read()
	if not stored or #(stored.paths or {}) == 0 then
		M.reset()
		return true
	end

	local stored_win_paths = {}
	for _, path in ipairs(stored.paths or {}) do
		local win, err = win_path.to_windows(path)
		if not win then
			util.notify_warn("Failed to verify clipboard owner: " .. tostring(err))
			return false
		end
		stored_win_paths[#stored_win_paths + 1] = win
	end

	local ok, err = clipboard.clear_owned(stored_win_paths, stored.cut == true)
	if not ok then
		util.notify_error("Failed to clear system clipboard: " .. tostring(err))
		return false
	end
	M.reset()
	return true
end

return M
