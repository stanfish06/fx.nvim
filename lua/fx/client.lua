local M = {}

---@class fx.Client
---@field proc table
---@field next_id integer
---@field pending table<integer, fun(err: table?, result: table?)>
---@field handlers table<string, function>
---@field dead boolean
local Client = {}
Client.__index = Client

--- Spawn the agent process and start reading its stdout.
---@param opts { cmd: string[], cwd: string, handlers: table<string, function>?, on_exit: fun()? }
---@return fx.Client
function M.spawn(opts)
	local self = setmetatable({
		next_id = 0,
		pending = {},
		handlers = opts.handlers or {},
		stdout_buf = "",
		dead = false,
	}, Client)

	self.proc = vim.system(opts.cmd, {
		cwd = opts.cwd,
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
			if handler then
				-- This is for answering fx permission request
				handler(msg.params, function(result, err)
					self:_send({ jsonrpc = "2.0", id = msg.id, result = result, error = err })
				end)
			else
				self:_send({ jsonrpc = "2.0", id = msg.id, error = { code = -32601, message = "method not found" } })
			end
		elseif handler then
			handler(msg.params)
		end
	elseif msg.id ~= nil then
		local cb = self.pending[msg.id]
		self.pending[msg.id] = nil
		if cb then
			cb(msg.error, msg.result)
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
	if cb then
		self.pending[self.next_id] = cb
	end
	self:_send({ jsonrpc = "2.0", id = self.next_id, method = method, params = params })
end

--- Send a notification
---@param method string JSON method
---@param params table method params
function Client:notify(method, params)
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
