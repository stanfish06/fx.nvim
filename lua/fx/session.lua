local client = require("fx.client")
local config = require("fx.config")

---@class fx.SessionState
---@field c fx.Client
---@field session_id string
---@field cwd string
---@field model string?
---@field models string[]?

---@class fx.Session
---@field state fx.SessionState?
---@field running boolean
local M = { state = nil, running = false }

--- Debounced :checktime after fx touches files. Core does the rest:
--- 'autoread' reloads unmodified buffers, conflicts get the W12 prompt,
--- and FileChangedShell remains the user's customization point.
local checktime_pending = false
local function schedule_checktime()
	if checktime_pending then
		return
	end
	checktime_pending = true
	vim.defer_fn(function()
		checktime_pending = false
		-- silent!: checktime is disallowed in the cmdline-window
		vim.cmd("silent! checktime")
	end, 200)
end

--- Handlers of agent responses
---@return table<string, function>
local function handlers()
	return {
		["session/update"] = function(params)
			if M.state and params and params.sessionId == M.state.session_id then
				M._on_update(params.update or {})
			end
		end,
		["session/request_permission"] = function(params, respond)
			M._on_permission(params or {}, respond)
		end,
	}
end

--- Route one session/update notification to the UI:
---@param u table
function M._on_update(u)
	local ui = require("fx.ui")
	local kind = u.sessionUpdate
	if kind == "agent_message_chunk" and u.content and u.content.text then
		ui.append_text(u.content.text)
	elseif kind == "tool_call" then
		ui.tool_line(u.toolCallId, u.title or "?", u.status or "pending")
	elseif kind == "tool_call_update" then
		ui.tool_status(u.toolCallId, u.status)
		if u.status == "completed" or u.status == "failed" then
			-- fx may have edited files on disk; sync buffers
			schedule_checktime()
		end
	end
end

--- Answer a session/request_permission request.
--- With config.permission = "yolo", auto allow
--- fx has allow but it appears it is not available to acp
---@param params table {toolCall = {title, ...}, options = [{optionId, name, kind}]}
---@param respond fun(result: table?, err: table?) resolves the pending request
function M._on_permission(params, respond)
	local title = params.toolCall and params.toolCall.title or "permission request"
	if config.permission == "yolo" then
		for _, o in ipairs(params.options or {}) do
			if o.optionId == "allow_once" or o.kind == "allow_once" then
				vim.notify("fx: auto-allowed - " .. title, vim.log.levels.INFO)
				return respond({ outcome = { outcome = "selected", optionId = o.optionId } })
			end
		end
	end
	vim.ui.select(params.options or {}, {
		prompt = "fx wants: " .. title,
		format_item = function(o)
			return o.name or o.optionId
		end,
	}, function(choice)
		if choice then
			respond({ outcome = { outcome = "selected", optionId = choice.optionId } })
		else
			respond({ outcome = { outcome = "cancelled" } })
		end
	end)
end

--- Fetch available models in fx
---@param st fx.SessionState
---@param res table?
local function fetch_model(st, res)
	for _, opt in ipairs(res and res.configOptions or {}) do
		if opt.id == "model" then
			st.model = opt.currentValue
			st.models = vim.tbl_map(function(o)
				return o.value
			end, opt.options or {})
		end
	end
end

---@return string
function M.current_model()
	return M.state and M.state.model or config.default_model or "?"
end

---@param st fx.SessionState
---@param id string
function M.set_model(st, id)
	st.c:request(
		"session/set_config_option",
		{ sessionId = st.session_id, configId = "model", value = id },
		function(err, res)
			if err then
				return vim.notify(("fx: model %s rejected: %s"):format(id, err.message or "?"), vim.log.levels.WARN)
			end
			fetch_model(st, res)
			config.default_model = st.model -- carry the choice into future sessions
			vim.notify("fx: model → " .. st.model)
		end
	)
end

---@param st fx.SessionState
local function apply_session_options(st)
	if config.mode then
		st.c:request("session/set_mode", { sessionId = st.session_id, modeId = config.mode })
	end
	if config.default_model and config.default_model ~= st.model then
		M.set_model(st, config.default_model)
	end
end

--- Build the fx command line, applying configured context limits.
---@return string[]
local function fx_command()
	local cmd = vim.deepcopy(config.fx_cmd)
	for name, v in pairs(config.context_limits or {}) do
		table.insert(cmd, 2, ("%s=%s"):format(name, v))
		table.insert(cmd, 2, "--context-limit")
	end
	return cmd
end

--- Spawn fx.
---@param on_exit fun(c: fx.Client)? process exit callback
---@param cb fun(c: fx.Client?) nil when the handshake failed
local function connect(on_exit, cb)
	local cmd = fx_command()
	-- vim.system throws on a missing executable; fail with a hint instead
	if vim.fn.executable(cmd[1]) ~= 1 then
		vim.notify(("fx: %q is not executable (see :checkhealth fx)"):format(cmd[1]), vim.log.levels.ERROR)
		return cb(nil)
	end
	local c
	c = client.spawn({
		cmd = cmd,
		cwd = vim.fn.getcwd(),
		env = config.permission and { FX_PERMISSION_MODE = config.permission } or nil,
		handlers = handlers(),
		on_exit = on_exit and function()
			on_exit(c)
		end or nil,
	})
	c:request("initialize", {
		protocolVersion = 1,
		clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
	}, function(err)
		if err then
			vim.notify(("fx: initialize failed: %s"):format(err.message or "?"), vim.log.levels.ERROR)
			c:kill()
			return cb(nil)
		end
		cb(c)
	end)
end

--- Ensure a live fx process + session, lazily spawning and initializing on first use.
---@param cb fun(st: fx.SessionState?)
function M.ensure(cb)
	local cwd = vim.fn.getcwd()
	if M.state and not M.state.c.dead and M.state.session_id then
		if M.state.cwd == cwd then
			return cb(M.state)
		end
		M.state.c:kill()
		M.state = nil
		vim.notify("fx: new session for " .. vim.fn.fnamemodify(cwd, ":~"), vim.log.levels.INFO)
	end
	connect(function(c)
		if M.state and M.state.c == c then
			M.state, M.running = nil, false
			vim.notify("fx: acp process exited", vim.log.levels.WARN)
		end
	end, function(c)
		if not c then
			return cb(nil)
		end
		c:request("session/new", { cwd = cwd, mcpServers = {} }, function(serr, res)
			if serr or not (res and res.sessionId) then
				vim.notify(("fx: session/new failed: %s"):format(serr and serr.message or "?"), vim.log.levels.ERROR)
				c:kill()
				return cb(nil)
			end
			M.state = { c = c, session_id = res.sessionId, cwd = cwd }
			fetch_model(M.state, res)
			apply_session_options(M.state)
			cb(M.state)
		end)
	end)
end

--- Saved sessions of the current workspace.
---@param cb fun(sessions: table[], current: string?) current is the running sessionId
function M.list(cb)
	local function ask(c, current, after)
		c:request("session/list", {}, function(err, res)
			if after then
				after()
			end
			if err then
				return vim.notify(("fx: session/list failed: %s"):format(err.message or "?"), vim.log.levels.ERROR)
			end
			cb(res and res.sessions or {}, current)
		end)
	end
	if M.state and not M.state.c.dead and M.state.cwd == vim.fn.getcwd() then
		return ask(M.state.c, M.state.session_id)
	end
	connect(nil, function(c)
		if c then
			ask(c, nil, function()
				c:kill()
			end)
		end
	end)
end

--- Run one turn of fx
---@param blocks table[] ACP block
---@param ctx fx.Context
function M.prompt(blocks, ctx)
	if M.running then
		return vim.notify("fx: a turn is already running (:Fx stop to interrupt)", vim.log.levels.WARN)
	end
	M.running = true
	M.ensure(function(st)
		if not st then
			M.running = false
			return
		end
		local ui = require("fx.ui")
		ui.begin_turn(ctx)
		st.c:request("session/prompt", { sessionId = st.session_id, prompt = blocks }, function(err, res)
			M.running = false
			vim.cmd("silent! checktime")
			ui.end_turn(err and (err.message or "error") or nil, res and res.stopReason)
		end)
	end)
end

--- Cancel the running turn
function M.stop()
	if M.state and M.running then
		M.state.c:notify("session/cancel", { sessionId = M.state.session_id })
	elseif M.running then
		M.running = false
		vim.notify("fx: cancelled before the session started", vim.log.levels.INFO)
	else
		vim.notify("fx: nothing to stop", vim.log.levels.INFO)
	end
end

--- Full restart
function M.restart()
	if M.state then
		M.state.c:kill()
		M.state = nil
	end
	M.running = false
	M.ensure(function(st)
		if st then
			vim.notify("fx: restarted", vim.log.levels.INFO)
		end
	end)
end

return M
