local config = require("fx.config")

local M = {}

local SCOPE = {
	arrow_function = true,
	class_declaration = true,
	class_definition = true,
	class_specifier = true,
	function_declaration = true,
	function_definition = true,
	function_item = true,
	impl_item = true,
	method_declaration = true,
	method_definition = true,
	mod_item = true,
	struct_item = true,
	struct_specifier = true,
}

---@class fx.TsInfo
---@field type string?
---@field range integer[]? {row1, col1, row2, col2} 1-indexed, end col exclusive
---@field text string?
---@field parent string?
---@field scope {type: string, name: string?, range: integer[]}?
---@field inject string? -- language injection (e.g. sql statement in a js file)

---@class fx.Context
---@field buf integer
---@field win integer
---@field path string
---@field rel string
---@field row integer cursor row position
---@field col integer? cursor column position
---@field word string? word under cursor
---@field line string? cursor line text
---@field lnum1 integer? selection start line
---@field lnum2 integer? selection end line
---@field col1 integer? selection start column
---@field col2 integer? selection end column
---@field text string? visual selection
---@field ts fx.TsInfo?
---@field summary string? structured facts for the prompt
---@field label string display label, e.g. "foo.c:4-5" or "foo.c:42"
---@field request string? user prompt

---@param node TSNode
---@return integer[]
local function node_range(node)
	local sr, sc, er, ec = node:range()
	return { sr + 1, sc + 1, er + 1, ec }
end

---@param r integer[]
---@return string
local function fmt_range(r)
	if r[1] == r[3] then
		return ("%d:%d-%d"):format(r[1], r[2], r[4])
	end
	return ("%d:%d-%d:%d"):format(r[1], r[2], r[3], r[4])
end

---@param node TSNode
---@param buf integer
---@return string?
local function node_name(node, buf)
	local ok, fld = pcall(node.field, node, "name")
	if not ok or not fld or not fld[1] then
		return nil
	end
	local tok, text = pcall(vim.treesitter.get_node_text, fld[1], buf)
	if tok then
		return text
	end
end

---@param node TSNode
---@param er integer
---@param ec integer 0-indexed exclusive
---@return TSNode
local function covering(node, er, ec)
	local n = node
	while true do
		local _, _, ner, nec = n:range()
		if ner > er or (ner == er and nec >= ec) then
			return n
		end
		local p = n:parent()
		if not p then
			return node
		end
		n = p
	end
end

---@param buf integer
---@param node TSNode
---@return string?
local function inject_lang(buf, node)
	local ok, parser = pcall(vim.treesitter.get_parser, buf)
	if not ok or not parser then
		return nil
	end
	local sr, sc, er, ec = node:range()
	local tok, tree = pcall(parser.language_for_range, parser, { sr, sc, er, ec })
	local lang = tok and tree and tree:lang() or nil
	local base = vim.treesitter.language.get_lang(vim.bo[buf].filetype) or vim.bo[buf].filetype
	if lang and lang ~= "" and lang ~= base then
		return lang
	end
end

---@param cfg table?
---@param last integer[]?
---@return boolean
local function ts_wanted(cfg, last)
	if not cfg then
		return false
	end
	return not not (
		cfg.type
		or cfg.range
		or cfg.text
		or cfg.parent
		or cfg.scope
		or cfg.inject
		or (cfg.covering and last)
	)
end

---@param buf integer
---@param pos integer[] {row, col} 0-indexed
---@param last integer[]? {row, col} 0-indexed exclusive end
---@param cfg table
---@return fx.TsInfo?
local function ts_capture(buf, pos, last, cfg)
	if not ts_wanted(cfg, last) then
		return nil
	end
	local okp, parser = pcall(vim.treesitter.get_parser, buf)
	if okp and parser then
		pcall(parser.parse, parser)
	end
	local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = pos })
	if not ok or not node then
		return nil
	end
	---@cast node TSNode
	if cfg.covering and last then
		local cok, cov = pcall(covering, node, last[1], last[2])
		if cok and cov then
			node = cov
		end
	end
	if not node:parent() then
		return nil
	end
	local info = {}
	if cfg.type then
		info.type = node:type()
	end
	if cfg.range then
		info.range = node_range(node)
	end
	if cfg.text then
		local tok, text = pcall(vim.treesitter.get_node_text, node, buf)
		if tok then
			info.text = text
		end
	end
	if cfg.parent then
		local p = node:parent()
		if p then
			info.parent = p:type()
		end
	end
	if cfg.scope then
		---@type TSNode?
		local s = node
		while s and not SCOPE[s:type()] do
			s = s:parent()
		end
		if s then
			info.scope = { type = s:type(), name = node_name(s, buf), range = node_range(s) }
		end
	end
	if cfg.inject then
		info.inject = inject_lang(buf, node)
	end
	return info
end

---@param ctx fx.Context
---@param loc string
local function summarize(ctx, loc)
	local parts = { loc }
	if ctx.word then
		parts[#parts + 1] = "word: " .. ctx.word
	end
	if ctx.line then
		parts[#parts + 1] = "line: " .. ctx.line:gsub("%s+", " ")
	end
	local ts = ctx.ts
	if ts then
		local t = { "ts:" }
		if ts.type then
			t[#t + 1] = ts.type
		end
		if ts.range then
			t[#t + 1] = fmt_range(ts.range)
		end
		if ts.text then
			t[#t + 1] = ts.text:gsub("%s+", " ")
		end
		if #t > 1 then
			parts[#parts + 1] = table.concat(t, " ")
		end
		if ts.parent then
			parts[#parts + 1] = "parent: " .. ts.parent
		end
		local s = ts.scope
		if s and s.type then
			parts[#parts + 1] = "scope: "
				.. s.type
				.. (s.name and (" " .. s.name) or "")
				.. (s.range and (" " .. fmt_range(s.range)) or "")
		end
		if ts.inject then
			parts[#parts + 1] = "inject: " .. ts.inject
		end
	end
	ctx.summary = table.concat(parts, "\n")
end

--- Capture the context for agent
---@param range table?
---@return fx.Context
function M.capture_context(range)
	local ac = config.agent_context or {}
	local buf = vim.api.nvim_get_current_buf()
	local win = vim.api.nvim_get_current_win()
	local path = vim.api.nvim_buf_get_name(buf)
	local cursor = vim.api.nvim_win_get_cursor(win)
	local ctx = {
		buf = buf,
		win = win,
		path = path,
		rel = path ~= "" and vim.fn.fnamemodify(path, ":.") or "[No Name]",
		row = cursor[1],
	}
	if range then
		local vis = ac.visual_selection or {}
		local lnum1, lnum2 = range[1], range[2]
		ctx.lnum1, ctx.lnum2, ctx.row = lnum1, lnum2, lnum1
		local a, b = vim.fn.getpos("'<"), vim.fn.getpos("'>")
		local marked = a[2] == lnum1 and b[2] == lnum2
		local last = vim.api.nvim_buf_get_lines(buf, lnum2 - 1, lnum2, false)[1] or ""
		local col1, col2 ---@type integer?, integer?
		if vis.col_range and marked then
			-- 1-indexed inclusive; clamp to last byte (linewise '> col is v:maxcol)
			col1, col2 = a[3], math.min(b[3], #last)
			ctx.col1, ctx.col2 = col1, col2
		end
		if vis.text then
			local ok, lines = false, nil
			if marked then
				ok, lines = pcall(vim.fn.getregion, a, b, { type = vim.fn.visualmode() })
			end
			ctx.text = (ok and lines) and table.concat(lines, "\n")
				or table.concat(vim.api.nvim_buf_get_lines(buf, lnum1 - 1, lnum2, false), "\n")
		end
		if col1 and col2 then
			ctx.label = ("%s:%d:%d-%d:%d"):format(ctx.rel, lnum1, col1, lnum2, col2)
		else
			ctx.label = ("%s:%d-%d"):format(ctx.rel, lnum1, lnum2)
		end
		-- col2 is 1-indexed inclusive, same number as 0-indexed exclusive end
		ctx.ts = ts_capture(
			buf,
			{ lnum1 - 1, (col1 or 1) - 1 },
			{ lnum2 - 1, math.min(col2 or #last, #last) },
			vis.treesitter_nodes or {}
		)
		local loc = ctx.rel
		if vis.row_range and col1 and col2 then
			loc = ("%s, selected %d:%d-%d:%d"):format(ctx.rel, lnum1, col1, lnum2, col2)
		elseif vis.row_range then
			loc = ("%s, selected lines %d-%d"):format(ctx.rel, lnum1, lnum2)
		end
		summarize(ctx, loc)
	else
		local cur = ac.cursor or {}
		if cur.col_position then
			ctx.col = cursor[2] + 1
		end
		if cur.word then
			local w = vim.fn.expand("<cword>")
			if w ~= "" then
				ctx.word = w
			end
		end
		if cur.row_text then
			ctx.line = vim.api.nvim_buf_get_lines(buf, ctx.row - 1, ctx.row, false)[1] or ""
		end
		if ctx.col then
			ctx.label = ("%s:%d:%d"):format(ctx.rel, ctx.row, ctx.col)
		else
			ctx.label = ("%s:%d"):format(ctx.rel, ctx.row)
		end
		ctx.ts = ts_capture(buf, { ctx.row - 1, cursor[2] }, nil, cur.treesitter_node or {})
		local loc = ctx.rel
		if cur.row_position and ctx.col then
			loc = ("%s, cursor at %d:%d"):format(ctx.rel, ctx.row, ctx.col)
		elseif cur.row_position then
			loc = ("%s, cursor at line %d"):format(ctx.rel, ctx.row)
		elseif ctx.col then
			loc = ("%s, cursor at column %d"):format(ctx.rel, ctx.col)
		end
		summarize(ctx, loc)
	end
	return ctx
end

--- Build the ACP prompt blocks
---@param ctx fx.Context
---@return table[] blocks
function M.blocks(ctx)
	local text = ctx.request or ""
	if ctx.summary then
		text = ("%s\n\ncontext:\n%s"):format(text, ctx.summary)
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
