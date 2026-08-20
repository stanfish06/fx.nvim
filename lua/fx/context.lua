local M = {}

---@class fx.Context
---@field buf integer
---@field win integer
---@field path string
---@field rel string
---@field row integer cursor row position
---@field lnum1 integer? selection start line
---@field lnum2 integer? selection end line
---@field text string? visual selection
---@field label string display label, e.g. "foo.c:4-5" or "foo.c:42"
---@field request string? user prompt

--- Capture the context for agent
---@param range table?
---@return fx.Context
function M.capture_context(range)
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local path = vim.api.nvim_buf_get_name(buf)
	local ctx = {
		buf = buf,
		win = win,
		path = path,
		rel = path ~= "" and vim.fn.fnamemodify(path, ":.") or "[No Name]",
		row = vim.api.nvim_win_get_cursor(win)[1],
	}
	if range then
		ctx.lnum1, ctx.lnum2 = range[1], range[2]
		ctx.text = table.concat(vim.api.nvim_buf_get_lines(buf, ctx.lnum1 - 1, ctx.lnum2, false), "\n")
		ctx.row = ctx.lnum1
		ctx.label = ("%s:%d-%d"):format(ctx.rel, ctx.lnum1, ctx.lnum2)
	else
		ctx.label = ("%s:%d"):format(ctx.rel, ctx.row)
	end
	return ctx
end

--- Build the ACP prompt blocks
---@param ctx fx.Context
---@return table[] blocks
function M.blocks(ctx)
	local request = ctx.request
	local text = request
	if ctx.path ~= "" then
		if ctx.lnum1 then
			text = ("%s\n\n(context: %s, selected lines %d-%d)"):format(request, ctx.rel, ctx.lnum1, ctx.lnum2)
		else
			text = ("%s\n\n(context: %s, cursor at line %d)"):format(request, ctx.rel, ctx.row)
		end
	end
	local blocks = { { type = "text", text = text } }
	if ctx.path ~= "" then
		local resource = { uri = vim.uri_from_fname(ctx.path) }
		if ctx.text then
			resource.text = ctx.text
		end
		blocks[#blocks + 1] = { type = "resource", resource = resource }
	end
	return blocks
end

return M
