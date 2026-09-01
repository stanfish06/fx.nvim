local M = {}

---@class fx.EventData payload of the "Fx:<method>" User autocmd
---@field method string ACP method, e.g. "session/prompt"
---@field phase "request"|"notify"|"response"
---@field direction "in"|"out" relative to the editor
---@field sessionId string?
---@field params table? request/notify payload
---@field result table? response payload
---@field err table? response error

--- Broadcast one ACP message as a User autocmd.
--- Pattern is "Fx:" .. method with "/" swapped for ":" ("Fx:session:update"):
--- a "/" in the fired pattern breaks tail-matching subscribers like "Fx:*"
--- (see :h autocmd-pattern). data.method keeps the exact ACP name.
---@param method string
---@param data table phase/direction plus params or result/err
local function emit(method, data)
	data.method = method
	data.sessionId = (data.params or data.result or {}).sessionId
	local ok, err = pcall(vim.api.nvim_exec_autocmds, "User", {
		pattern = "Fx:" .. method:gsub("/", ":"),
		modeline = false,
		data = data,
	})
	if not ok then
		vim.notify_once("fx: error in Fx:" .. method .. " autocmd: " .. tostring(err), vim.log.levels.ERROR)
	end
end

---@class fx.Client
---@field proc table
---@field next_id integer
---@field pending table<integer, {method: string, cb: fun(err: table?, result: table?)?}>
---@field handlers table<string, function>
---@field dead boolean
local Client = {}
Client.__index = Client

--- Spawn the agent process and start reading its stdout.
---@param opts { cmd: string[], cwd: string, env: table<string, string>?, handlers: table<string, function>?, on_exit: fun()? }
---@return fx.Client
function M.spawn(opts)
	local self = setmetatable({
		next_id = 0,
		pending = {},
		handlers = opts.handlers or {},
		stdout_buf = "",
		dead = false,
	}, Client)
	-- Example:
	--   Client:
	--   {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1}}
	--   {"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":".","mcpServers":[]}}
	--   {"jsonrpc":"2.0","id":1,"method":"session/prompt","params":{"sessionId":"1787721810719-1787721810719985710-0ba2e0059ef6c429","prompt":[{"type":"text","text":"hello, tell me a joke"}]}}
	--   Response:
	--   {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"1787721810719-1787721810719985710-0ba2e0059ef6c429","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Why do programmers prefer dark mode?\n\n"}}}}
	--   {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"1787721810719-1787721810719985710-0ba2e0059ef6c429","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Because light attracts bugs."}}}}
	--   {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"1787721810719-1787721810719985710-0ba2e0059ef6c429","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"\n"}}}}
	self.proc = vim.system(opts.cmd, {
		cwd = opts.cwd,
		env = opts.env,
		stdin = true,
		stdout = function(_, data)
			if not data then
				return
			end
			self.stdout_buf = self.stdout_buf .. data
			while true do
				local nl = self.stdout_buf:find("\n", 1, true)
				if not nl then
					break
				end
				local line = self.stdout_buf:sub(1, nl - 1)
				self.stdout_buf = self.stdout_buf:sub(nl + 1)
				if line ~= "" then
					vim.schedule(function()
						self:_handle(line)
					end)
				end
			end
		end,
	}, function()
		self.dead = true
		if opts.on_exit then
			vim.schedule(opts.on_exit)
		end
	end)

	return self
end

--- Decode and handle agent response:
--- method + id: agent-initiated request
--- method only: notification
--- id only: response to one of our requests
---@param line string one complete JSON message
function Client:_handle(line)
	local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
	if not ok or type(msg) ~= "table" then
		return
	end
	if msg.method then
		local handler = self.handlers[msg.method]
		if msg.id ~= nil then
			emit(msg.method, { phase = "request", direction = "in", params = msg.params })
			if handler then
				-- This is for answering fx permission request
				handler(msg.params, function(result, err)
					emit(msg.method, { phase = "response", direction = "out", result = result, err = err })
					self:_send({ jsonrpc = "2.0", id = msg.id, result = result, error = err })
				end)
			else
				self:_send({ jsonrpc = "2.0", id = msg.id, error = { code = -32601, message = "method not found" } })
			end
		else
			emit(msg.method, { phase = "notify", direction = "in", params = msg.params })
			if handler then
				handler(msg.params)
			end
		end
	elseif msg.id ~= nil then
		local p = self.pending[msg.id]
		self.pending[msg.id] = nil
		if p then
			emit(p.method, { phase = "response", direction = "in", result = msg.result, err = msg.error })
			if p.cb then
				p.cb(msg.error, msg.result)
			end
		end
	end
end

--- Encode and write to agent.
---@param obj table JSON message
function Client:_send(obj)
	if self.dead then
		return
	end
	self.proc:write(vim.json.encode(obj) .. "\n")
end

--- Send a request.
---@param method string JSON method, e.g. "session/prompt"
---@param params table method params
---@param cb fun(err: table?, result: table?)? response callback
function Client:request(method, params, cb)
	self.next_id = self.next_id + 1
	self.pending[self.next_id] = { method = method, cb = cb }
	emit(method, { phase = "request", direction = "out", params = params })
	self:_send({ jsonrpc = "2.0", id = self.next_id, method = method, params = params })
end

--- Send a notification
---@param method string JSON method
---@param params table method params
function Client:notify(method, params)
	emit(method, { phase = "notify", direction = "out", params = params })
	self:_send({ jsonrpc = "2.0", method = method, params = params })
end

--- Terminate the agent process
function Client:kill()
	self.dead = true
	pcall(function()
		self.proc:kill("sigterm")
	end)
end

return M
