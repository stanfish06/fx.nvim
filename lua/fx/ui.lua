local config = require("fx.config")

local api = vim.api

---@class fx.Turn
---@field ctx fx.Context
---@field buf integer
---@field request string
---@field at integer start time
---@field tools table<string, {line: integer, title: string}> tool call id -> transcript line
---@field last_was_tool boolean
---@field spinner_frame integer
---@field spinner_mark integer?
---@field spinner_timer table?
---@field win integer?

---@class fx.Ui
---@field turn fx.Turn?
---@field turns fx.Turn[]
local M = { turn = nil, turns = {} }

local ns = api.nvim_create_namespace("fx_ui")
local spinner_patterns = {
	snake = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
	trig = { "▴", "▸", "▾", "◂" },
	dots = { "⣾", "⣽", "⣻", "⢿", "⡿", "⣟", "⣯", "⣷" },
	orbit = { "⠁", "⠂", "⠄", "⡀", "⢀", "⠠", "⠐", "⠈" },
	line = { "|", "/", "-", "\\" },
	pulse = { "◐", "◓", "◑", "◒" },
	corners = { "◰", "◳", "◲", "◱" },
	arrows = { "←", "↖", "↑", "↗", "→", "↘", "↓", "↙" },
	bar = { "▁", "▃", "▄", "▅", "▆", "▇", "█", "▇", "▆", "▅", "▄", "▃" },
	bounce = {
		"⠂",
		"⠄",
		"⠆",
		"⠇",
		"⠋",
		"⠙",
		"⠸",
		"⠰",
		"⠠",
		"⠰",
		"⠸",
		"⠙",
		"⠋",
		"⠇",
		"⠆",
		"⠄",
	},
	moon = { "🌑", "🌒", "🌓", "🌔", "🌕", "🌖", "🌗", "🌘" },
	zap = { "»  ", "»» ", "»»»", " »»", "  »", "  «", " ««", "«««", "«« ", "«  ", interval = 70 },
	ping = { "●∙∙", "∙●∙", "∙∙●", "∙●∙", interval = 80 },
}
local spinner_frames = spinner_patterns[config.spinner] or spinner_patterns.snake
local spinner_interval = spinner_frames.interval or 120

local glyph = { pending = "·", in_progress = "…", completed = "✓", failed = "✗" }
local HISTORY_MAX = 50

local function set_hl()
	api.nvim_set_hl(0, "FxSpinner", { link = "DiagnosticVirtualTextInfo", default = true })
	api.nvim_set_hl(0, "FxNormal", { link = "NormalFloat", default = true })
	api.nvim_set_hl(0, "FxBorder", { link = "FloatBorder", default = true })
	api.nvim_set_hl(0, "FxTitle", { link = "FloatTitle", default = true })
end
set_hl()
api.nvim_create_autocmd("ColorScheme", { callback = set_hl })

local FLOAT_WINHL = "NormalFloat:FxNormal,FloatBorder:FxBorder,FloatTitle:FxTitle"

--- Float width clamped to the current screen.
---@return integer
local function float_width()
	return math.min(config.output.width, vim.o.columns - 8)
end

--- Pick the side for a float window
---@param grid_row integer
---@param grid_col integer
---@param width integer
---@param height integer
---@return table cfg
local function flip_cfg(grid_row, grid_col, width, height)
	local total_h, total_w = height + 2, width + 2
	local above = grid_row - 1 >= total_h
	local grow_left = (vim.o.columns - grid_col) < total_w and grid_col - 1 >= total_w
	return {
		anchor = (above and "S" or "N") .. (grow_left and "E" or "W"),
		row = above and 0 or 1,
		col = grow_left and 1 or 0,
	}
end

--- Best float for current cursor
---@param width integer
---@param height integer
---@return table cfg
local function cursor_float_cfg(width, height)
	local win_pos = api.nvim_win_get_position(0)
	local cfg = flip_cfg(win_pos[1] + vim.fn.winline(), win_pos[2] + vim.fn.wincol(), width, height)
	cfg.relative = "cursor"
	return cfg
end

--- Open a small editable float under the cursor to type a request.
---@param ctx fx.Context
---@param cb fun(text: string)
function M.input(ctx, cb)
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local win = api.nvim_open_win(
		buf,
		true,
		vim.tbl_extend("force", cursor_float_cfg(float_width(), 2), {
			width = float_width(),
			height = 2,
			style = "minimal",
			border = config.border,
			title = (" fx · %s "):format(ctx.label),
			title_pos = "left",
		})
	)
	vim.wo[win].wrap = true
	vim.wo[win].winhighlight = FLOAT_WINHL
	local function close()
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end
	local function submit()
		local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		close()
		if text ~= "" then
			cb(text)
		end
	end
	vim.keymap.set("i", "<CR>", function()
		vim.cmd.stopinsert()
		submit()
	end, { buffer = buf })
	vim.keymap.set("n", "<CR>", submit, { buffer = buf })
	vim.keymap.set("n", "<Esc>", close, { buffer = buf })
	vim.keymap.set("n", "q", close, { buffer = buf })
	vim.cmd.startinsert()
end

--- Start a turn
---@param ctx fx.Context
function M.begin_turn(ctx)
	M.close_output()
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].filetype = "markdown"
	api.nvim_buf_set_lines(buf, 0, -1, false, { "❯ " .. ctx.request:gsub("\n", " "), "" })
	local turn = {
		ctx = ctx,
		buf = buf,
		request = ctx.request,
		at = os.time(),
		tools = {},
		last_was_tool = false,
		spinner_frame = 1,
	}
	M.turn = turn
	M.turns[#M.turns + 1] = turn
	if #M.turns > HISTORY_MAX then
		local old = table.remove(M.turns, 1)
		if old.buf and api.nvim_buf_is_valid(old.buf) then
			pcall(api.nvim_buf_delete, old.buf, { force = true })
		end
	end
	if api.nvim_buf_is_valid(ctx.buf) then
		turn.spinner_mark = api.nvim_buf_set_extmark(ctx.buf, ns, math.max(ctx.row - 1, 0), 0, {
			virt_text = { { " " .. spinner_frames[1] .. " fx", "FxSpinner" } },
			virt_text_pos = "eol",
		})
		turn.spinner_timer = vim.uv.new_timer()
		turn.spinner_timer:start(
			spinner_interval,
			spinner_interval,
			vim.schedule_wrap(function()
				M._tick()
			end)
		)
	end
end

--- Advance the spinner one frame.
function M._tick()
	local t = M.turn
	if not t or not t.spinner_timer or not t.spinner_mark or not api.nvim_buf_is_valid(t.ctx.buf) then
		return
	end
	local at = api.nvim_buf_get_extmark_by_id(t.ctx.buf, ns, t.spinner_mark, {})[1]
	if not at then
		return
	end
	t.spinner_frame = t.spinner_frame % #spinner_frames + 1
	api.nvim_buf_set_extmark(t.ctx.buf, ns, at, 0, {
		id = t.spinner_mark,
		virt_text = { { " " .. spinner_frames[t.spinner_frame] .. " fx", "FxSpinner" } },
		virt_text_pos = "eol",
	})
end

--- Show a turn's transcript in an unfocused float, anchored near where the
--- request was made (editor corner if that window is gone). q/<Esc> closes.
---@param turn fx.Turn? defaults to the latest turn
function M.show_last_turn(turn)
	turn = turn or M.turn
	if not turn or not api.nvim_buf_is_valid(turn.buf) then
		return vim.notify("fx: no output to show", vim.log.levels.INFO)
	end
	M.close_output()
	local ctx = turn.ctx
	local width, height = float_width(), M._height(turn)
	local cfg
	-- the window may show another buffer by now, which ctx.row does not index
	if ctx and api.nvim_win_is_valid(ctx.win) and api.nvim_win_get_buf(ctx.win) == ctx.buf then
		-- clamp row
		local row = math.min(math.max(ctx.row, 1), api.nvim_buf_line_count(ctx.buf))
		local pos = vim.fn.screenpos(ctx.win, row, 1)
		if pos.row > 0 then -- 0 means that line is scrolled out of view
			cfg = vim.tbl_extend("force", flip_cfg(pos.row, math.max(pos.col, 1), width, height), {
				relative = "win",
				win = ctx.win,
				bufpos = { row - 1, 0 },
			})
		end
	end
	if not cfg then
		cfg = {
			relative = "editor",
			row = vim.o.lines - 3,
			col = math.max(vim.o.columns - width - 4, 0),
			anchor = "SW",
		}
	end
	turn.win = api.nvim_open_win(
		turn.buf,
		true, -- enter the float so q/<Esc>/scrolling work without mousing in
		vim.tbl_extend("force", cfg, {
			width = width,
			height = height,
			style = "minimal",
			border = config.border,
			title = (" fx · %s "):format(ctx and ctx.label or ""),
			title_pos = "left",
		})
	)
	vim.wo[turn.win].wrap = true
	vim.wo[turn.win].linebreak = true
	vim.wo[turn.win].winhighlight = FLOAT_WINHL
	vim.keymap.set("n", "q", M.close_output, { buffer = turn.buf })
	vim.keymap.set("n", "<Esc>", M.close_output, { buffer = turn.buf })
end

--- Close any open transcript float (turns and their buffers are kept).
function M.close_output()
	for _, t in ipairs(M.turns) do
		if t.win and api.nvim_win_is_valid(t.win) then
			api.nvim_win_close(t.win, true)
		end
		t.win = nil
	end
end

--- Pick a past prompt via vim.ui.select (newest first) and view its transcript.
function M.show_full_history()
	if #M.turns == 0 then
		return vim.notify("fx: no history", vim.log.levels.INFO)
	end
	local items = {}
	for i = #M.turns, 1, -1 do
		items[#items + 1] = M.turns[i]
	end
	vim.ui.select(items, {
		prompt = "fx history",
		format_item = function(t)
			return ("%s  %s  %s"):format(os.date("%H:%M", t.at), t.ctx.label, t.request:gsub("%s+", " "))
		end,
	}, function(choice)
		if choice then
			M.show_last_turn(choice)
		end
	end)
end

--- Float height that fits the transcript, clamped to config.output.max_height.
---@param turn fx.Turn
---@return integer
function M._height(turn)
	local count = api.nvim_buf_line_count(turn.buf)
	return math.min(config.output.max_height, math.max(2, count))
end

--- Resize the current turn's float to fit and keep the tail visible,
--- unless the user has focused the float (don't fight their scrolling).
function M._refresh()
	local t = M.turn
	if not t or not t.win or not api.nvim_win_is_valid(t.win) then
		return
	end
	api.nvim_win_set_config(t.win, { height = M._height(t) })
	if api.nvim_get_current_win() ~= t.win then
		api.nvim_win_set_cursor(t.win, { api.nvim_buf_line_count(t.buf), 0 })
	end
end

--- Append agent text to the current transcript.
---@param text string
function M.append_text(text)
	local t = M.turn
	if not t or not api.nvim_buf_is_valid(t.buf) then
		return
	end
	if t.last_was_tool then
		api.nvim_buf_set_lines(t.buf, -1, -1, false, { "" })
		t.last_was_tool = false
	end
	local lines = vim.split(text, "\n", { plain = true })
	local last = api.nvim_buf_get_lines(t.buf, -2, -1, false)[1] or ""
	api.nvim_buf_set_lines(t.buf, -2, -1, false, { last .. lines[1] })
	if #lines > 1 then
		api.nvim_buf_set_lines(t.buf, -1, -1, false, vim.list_slice(lines, 2))
	end
	M._refresh()
end

--- Add a tool-activity line ("✓ Editing", "… Searching") to the transcript
--- and remember its position so later status updates can rewrite it.
---@param id string toolCallId from the session update
---@param title string human-readable tool action
---@param status string "pending" | "in_progress" | "completed" | "failed"
function M.tool_line(id, title, status)
	local t = M.turn
	if not t or not api.nvim_buf_is_valid(t.buf) then
		return
	end
	api.nvim_buf_set_lines(t.buf, -1, -1, false, { ("%s %s"):format(glyph[status] or "·", title) })
	t.tools[id] = { line = api.nvim_buf_line_count(t.buf) - 1, title = title }
	t.last_was_tool = true
	M._refresh()
end

--- Update the status glyph of a previously added tool line in place.
---@param id string toolCallId from the session update
---@param status string "pending" | "in_progress" | "completed" | "failed"
function M.tool_status(id, status)
	local t = M.turn
	if not t or not api.nvim_buf_is_valid(t.buf) then
		return
	end
	local info = t.tools[id]
	if not info then
		return
	end
	api.nvim_buf_set_lines(
		t.buf,
		info.line,
		info.line + 1,
		false,
		{ ("%s %s"):format(glyph[status] or "·", info.title) }
	)
	M._refresh()
end

--- Finish the current turn: stop the spinner, append the outcome line to the
--- transcript, and notify (errors loudly, success quietly).
---@param err_msg string? error text if the prompt request failed
---@param stop_reason string? ACP stopReason ("end_turn", "cancelled", ...)
function M.end_turn(err_msg, stop_reason)
	local t = M.turn
	if not t then
		return
	end
	if t.spinner_timer then
		t.spinner_timer:stop()
		t.spinner_timer:close()
		t.spinner_timer = nil
	end
	if t.spinner_mark and api.nvim_buf_is_valid(t.ctx.buf) then
		pcall(api.nvim_buf_del_extmark, t.ctx.buf, ns, t.spinner_mark)
	end
	if api.nvim_buf_is_valid(t.buf) then
		api.nvim_buf_set_lines(
			t.buf,
			-1,
			-1,
			false,
			{ "", err_msg and ("✗ " .. err_msg) or ("— " .. (stop_reason or "done")) }
		)
		M._refresh()
	end
	if err_msg then
		vim.notify("fx: " .. err_msg, vim.log.levels.ERROR)
	else
		vim.notify("fx: " .. (stop_reason or "done"), vim.log.levels.INFO)
	end
end

return M
