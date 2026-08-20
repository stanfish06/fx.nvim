local api = vim.api

---@class fx.Reload
---@field mtimes table<string, number> path -> last seen mtime (fractional seconds)
---@field turn_start integer os.time() at snapshot
---@field pending boolean
local M = { mtimes = {}, turn_start = 0, pending = false }

--- File mtime as fractional seconds; nil if unreadable.
---@param path string
---@return number?
local function file_mtime(path)
	local s = vim.uv.fs_stat(path)
	return s and (s.mtime.sec + s.mtime.nsec / 1e9) or nil
end

--- Buffer participates in sync: loaded, normal file, named.
---@param buf integer
---@return boolean
local function eligible(buf)
	return api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= ""
end

--- Reload from disk.
---@param buf integer
local function reload(buf)
	local views = {}
	for _, w in ipairs(vim.fn.win_findbuf(buf)) do
		views[w] = api.nvim_win_call(w, vim.fn.winsaveview)
	end
	local w = vim.fn.win_findbuf(buf)[1]
	if w then
		api.nvim_win_call(w, function()
			vim.cmd("silent! keepalt edit!")
		end)
	else
		local ok, lines = pcall(vim.fn.readfile, api.nvim_buf_get_name(buf))
		if not ok then
			return
		end
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modified = false
	end
	for win, view in pairs(views) do
		if api.nvim_win_is_valid(win) then
			api.nvim_win_call(win, function()
				vim.fn.winrestview(view)
			end)
		end
	end
end

--- fx rewrote a file whose buffer has unsaved changes
---@param buf integer
---@param path string
function M._conflict(buf, path)
	local rel = vim.fn.fnamemodify(path, ":.")
	vim.ui.select({ "Keep my unsaved buffer", "Take fx's version (discard my edits)", "Diff buffer vs disk" }, {
		prompt = ("fx edited %s but the buffer has unsaved changes"):format(rel),
	}, function(_, idx)
		if idx == 2 then
			reload(buf)
		elseif idx == 3 then
			local w = vim.fn.win_findbuf(buf)[1]
			if not w then
				return vim.notify("fx: buffer not visible", vim.log.levels.WARN)
			end
			local disk = vim.fn.readfile(path)
			api.nvim_set_current_win(w)
			vim.cmd("diffthis")
			vim.cmd("rightbelow vnew")
			api.nvim_buf_set_lines(0, 0, -1, false, disk)
			vim.bo.buftype = "nofile"
			vim.bo.bufhidden = "wipe"
			vim.bo.filetype = vim.bo[buf].filetype
			vim.cmd("diffthis")
		end
	end)
end

--- Record mtimes at turn start so the sweep can tell what fx touched.
function M.snapshot()
	M.turn_start = os.time()
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if eligible(buf) then
			local path = api.nvim_buf_get_name(buf)
			local m = file_mtime(path)
			if m then
				M.mtimes[path] = m
			end
		end
	end
end

--- Debounced sweep, called after each completed tool call.
function M.schedule_sweep()
	if M.pending then
		return
	end
	M.pending = true
	vim.defer_fn(function()
		M.pending = false
		M.sweep()
	end, 200)
end

--- Reload buffers whose files changed; modified buffers go to _conflict.
function M.sweep()
	for _, buf in ipairs(api.nvim_list_bufs()) do
		if eligible(buf) then
			local path = api.nvim_buf_get_name(buf)
			local m = file_mtime(path)
			local known = M.mtimes[path]
			if m and ((known and m > known) or (not known and m >= M.turn_start)) then
				M.mtimes[path] = m
				if vim.bo[buf].modified then
					M._conflict(buf, path)
				else
					reload(buf)
				end
			end
		end
	end
end

return M
