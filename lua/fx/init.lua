local M = {}

--- Optional plugin setup; only needed to override config defaults.
---@param opts table? see fx.config for available options
function M.setup(opts)
	require("fx.config").setup(opts)
end

--- Submit prompt to agent with context information
---@param ctx table context information (file, line, etc)
---@param prompt string user prompt
local function submit(ctx, prompt)
	ctx.request = prompt
	require("fx.session").prompt(require("fx.context").blocks(ctx), ctx)
end

--- Prepare context and prompt to submit to agent
---@param visual_range table? {lnum1, lnum2} from visual mode
---@param prompt? string user prompt
function M.ask(visual_range, prompt)
	prompt = prompt and vim.trim(prompt)
	local config = require("fx.config")
	if config.force_write_file and vim.api.nvim_buf_get_name(0) ~= "" and vim.bo.modified then
		vim.cmd("silent! write!")
		if visual_range then
			-- It is possible that visual block gets shifted after file write
			-- update the visual range by visual marks
			visual_range = { vim.fn.line("'<"), vim.fn.line("'>") }
		end
	end
	local ctx = require("fx.context").capture_context(visual_range)
	if prompt and prompt ~= "" then
		submit(ctx, prompt)
	else
		require("fx.ui").input(ctx, function(p)
			submit(ctx, p)
		end)
	end
end

--- Main entry of the program with the following routes:
--- > stop: stop the fx session
--- > restart: restart the fx session
--- > rewind: check the previous request and agent response
--- > history: check the full session history
--- > list: list the workspace's fx sessions, running one first
--- > model: pick the model fx uses for this session
--- > ask <text>: directly send input text to agent (ask alone opens the input box)
--- > nil: open the input box to enter the prompt
---@param o table arguments
function M.main(o)
	local session = require("fx.session")
	local ui = require("fx.ui")
	local sub = o.fargs[1]
	if sub == "stop" then
		session.stop()
	elseif sub == "restart" then
		session.restart()
	elseif sub == "rewind" then
		ui.show_last_turn()
	elseif sub == "history" then
		ui.show_full_history()
	elseif sub == "list" then
		session.list(ui.show_sessions)
	elseif sub == "model" then
		ui.pick_model()
	elseif sub == "ask" or sub == nil then
		local prompt = table.concat(vim.list_slice(o.fargs, 2), " ")
		M.ask(o.range > 0 and { o.line1, o.line2 } or nil, prompt)
	else
		vim.notify(("fx: unknown subcommand %q — use :Fx ask <text>"):format(sub), vim.log.levels.WARN)
	end
end

return M
