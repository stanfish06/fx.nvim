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
---@field last {id: string, cwd: string}? session :Fx restart reloads
---@field running boolean
local M = { state = nil, last = nil, running = false }

--- Set while a session switch is in flight; a second switch or a prompt landing
--- in that window would talk to the session being replaced.
local switching = false

---@type table<string, {c: fx.Client, turn: fx.Turn}> sessionId -> in-flight session/load replay
local replay = {}

--- Drop the session and any pending replay when the process behind them dies.
---@param c fx.Client
local function process_exit(c)
	for id, r in pairs(replay) do
		if r.c == c then
			replay[id] = nil
		end
	end
	-- a switch riding a dead process never answers; leaving the flag set would
	-- refuse every later command
	switching = false
	if M.state and M.state.c == c then
		M.state, M.running = nil, false
		vim.notify("fx: acp process exited", vim.log.levels.WARN)
	end
end

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
			if not params then
				return
			end
			local into = replay[params.sessionId]
			if into then
				return require("fx.ui").replay_chunk(into.turn, params.update or {})
			end
			if M.state and params.sessionId == M.state.session_id then
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

--- Make st the live session, remembering it for :Fx restart.
---@param st fx.SessionState
local function adopt(st)
	M.state = st
	M.last = { id = st.session_id, cwd = st.cwd }
end

---@param st fx.SessionState
local function apply_mode(st)
	if config.mode then
		st.c:request("session/set_mode", { sessionId = st.session_id, modeId = config.mode })
	end
end

---@param st fx.SessionState
local function apply_session_options(st)
	apply_mode(st)
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

--- Spawn fx rooted at cwd
---@param cwd string
---@param cb fun(c: fx.Client?) nil when the handshake failed
local function connect(cwd, cb)
	local cmd = fx_command()
	-- vim.system throws on a missing executable; fail with a hint instead
	if vim.fn.executable(cmd[1]) ~= 1 then
		vim.notify(("fx: %q is not executable (see :checkhealth fx)"):format(cmd[1]), vim.log.levels.ERROR)
		return cb(nil)
	end
	local c
	c = client.spawn({
		cmd = cmd,
		cwd = cwd,
		env = config.permission and { FX_PERMISSION_MODE = config.permission } or nil,
		handlers = handlers(),
		on_exit = function()
			process_exit(c)
		end,
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

--- Spawn a process rooted at cwd and open a fresh session in it.
---@param cwd string
---@param cb fun(st: fx.SessionState?)
local function start(cwd, cb)
	connect(cwd, function(c)
		if not c then
			return cb(nil)
		end
		c:request("session/new", { cwd = cwd, mcpServers = {} }, function(err, res)
			if err or not (res and res.sessionId) then
				vim.notify(("fx: session/new failed: %s"):format(err and err.message or "?"), vim.log.levels.ERROR)
				c:kill()
				return cb(nil)
			end
			adopt({ c = c, session_id = res.sessionId, cwd = cwd })
			fetch_model(M.state, res)
			apply_session_options(M.state)
			cb(M.state)
		end)
	end)
end

--- Ensure a live fx process + session, lazily spawning on first use.
---@param cb fun(st: fx.SessionState?)
function M.ensure(cb)
	if M.state and not M.state.c.dead and M.state.session_id then
		return cb(M.state)
	end
	start(vim.fn.getcwd(), cb)
end

---@return boolean
local function busy()
	if M.running then
		vim.notify("fx is running (:Fx stop to interrupt)", vim.log.levels.WARN)
		return true
	end
	if switching then
		vim.notify("fx is switching session", vim.log.levels.WARN)
		return true
	end
	return false
end

--- Open a fresh session, carrying nothing over. Respawns when the cwd moved,
--- since fx pins a session to the process it was created in.
function M.new()
	if busy() then
		return
	end
	switching = true
	local cwd = vim.fn.getcwd()
	if not M.state or M.state.c.dead or M.state.cwd ~= cwd then
		if M.state then
			M.state.c:kill()
		end
		M.state = nil
		return start(cwd, function(st)
			switching = false
			if st then
				vim.notify("fx: new session in " .. vim.fn.fnamemodify(cwd, ":~"), vim.log.levels.INFO)
			end
		end)
	end
	local st = M.state
	st.c:request("session/new", { cwd = cwd, mcpServers = {} }, function(err, res)
		switching = false
		if err or not (res and res.sessionId) then
			return vim.notify(("fx: session/new failed: %s"):format(err and err.message or "?"), vim.log.levels.ERROR)
		end
		st.session_id = res.sessionId
		adopt(st)
		fetch_model(st, res)
		apply_session_options(st)
		vim.notify("fx: new session", vim.log.levels.INFO)
	end)
end

--- A live process, whichever session it happens to be on.
---@param cb fun(c: fx.Client?, cwd: string, spawned: boolean)
local function ensure_client(cb)
	if M.state and not M.state.c.dead then
		return cb(M.state.c, M.state.cwd, false)
	end
	local cwd = vim.fn.getcwd()
	connect(cwd, function(c)
		cb(c, cwd, true)
	end)
end

--- Resume a saved session: fx keeps its context, the transcript starts empty.
---@param id string sessionId from session/list
function M.resume(id)
	if busy() then
		return
	end
	switching = true
	ensure_client(function(c, cwd, spawned)
		if not c or (M.state and M.state.session_id == id) then
			switching = false
			return
		end
		c:request("session/resume", { sessionId = id, cwd = cwd, mcpServers = {} }, function(err, res)
			switching = false
			if err then
				if spawned then
					c:kill()
				end
				return vim.notify(("fx: session/resume failed: %s"):format(err.message or "?"), vim.log.levels.ERROR)
			end
			adopt({ c = c, session_id = id, cwd = cwd })
			fetch_model(M.state, res)
			apply_mode(M.state)
			vim.notify("fx: session resumed", vim.log.levels.INFO)
		end)
	end)
end

--- Saved sessions of the running session's workspace, or of the current
--- directory when fx is not up yet.
---@param cb fun(sessions: table[], current: string?) current is the running sessionId
function M.list(cb)
	local function ask(c, cwd, current, after)
		-- fx lists every workspace of the profile when cwd is omitted
		c:request("session/list", { cwd = cwd }, function(err, res)
			if after then
				after()
			end
			if err then
				return vim.notify(("fx: session/list failed: %s"):format(err.message or "?"), vim.log.levels.ERROR)
			end
			cb(res and res.sessions or {}, current)
		end)
	end
	if M.state and not M.state.c.dead then
		return ask(M.state.c, M.state.cwd, M.state.session_id)
	end
	local cwd = vim.fn.getcwd()
	connect(cwd, function(c)
		if c then
			ask(c, cwd, nil, function()
				c:kill()
			end)
		end
	end)
end

--- Run one turn of fx
---@param blocks table[] ACP block
---@param ctx fx.Context
function M.prompt(blocks, ctx)
	if busy() then
		return
	end
	M.running = true
	M.ensure(function(st)
		if not st then
			M.running = false
			return
		end
		local ui = require("fx.ui")
		ui.begin_turn(ctx, st.session_id)
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

--- Adopt a saved session, replaying its transcript into a fresh buffer.
---@param c fx.Client
---@param cwd string
---@param id string
---@param cb fun(st: fx.SessionState?)
local function load(c, cwd, id, cb)
	local ui = require("fx.ui")
	local turn = ui.begin_replay(id)
	replay[id] = { c = c, turn = turn }
	c:request("session/load", { sessionId = id, cwd = cwd, mcpServers = {} }, function(err, res)
		replay[id] = nil
		ui.end_replay(turn)
		if err then
			vim.notify(("fx: session/load failed: %s"):format(err.message or "?"), vim.log.levels.ERROR)
			return cb(nil)
		end
		local st = { c = c, session_id = id, cwd = cwd }
		fetch_model(st, res)
		apply_mode(st)
		cb(st)
	end)
end

--- Replay the running session's transcript, which :Fx resume leaves empty.
function M.load()
	if busy() then
		return
	end
	local st = M.state
	if not st or st.c.dead then
		return vim.notify("fx: no session to load", vim.log.levels.INFO)
	end
	switching = true
	load(st.c, st.cwd, st.session_id, function(loaded)
		switching = false
		if loaded then
			adopt(loaded)
			vim.notify("fx: session history loaded", vim.log.levels.INFO)
		end
	end)
end

--- Restart the process and reload the session it was on, transcript included.
function M.restart()
	if switching then
		return vim.notify("fx is switching session", vim.log.levels.WARN)
	end
	local prev = M.last
	if M.state then
		M.state.c:kill()
		M.state = nil
	end
	M.running = false
	if not prev then
		return M.ensure(function(st)
			if st then
				vim.notify("fx: restarted", vim.log.levels.INFO)
			end
		end)
	end
	switching = true
	connect(prev.cwd, function(c)
		if not c then
			switching = false
			return
		end
		load(c, prev.cwd, prev.id, function(st)
			switching = false
			if not st then
				return c:kill()
			end
			adopt(st)
			vim.notify("fx: restarted, session restored", vim.log.levels.INFO)
		end)
	end)
end

return M
