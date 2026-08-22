local M = {
	fx_cmd = { "fx", "acp" },
	mode = "code",
	default_model = "deepseek/deepseek-v4-flash",
	permission = "yolo",
	context_limits = { skill_catalog_bytes = 0 },
	force_write_file = true, -- force write current file before sending to fx
	output = { width = 64, max_height = 14 }, -- float sizing, used by ui.lua
	spinner = "zap", -- snake|trig|dots|orbit|line|pulse|corners|arrows|bar|bounce|moon|zap|ping
	border = "single", -- float border: single|rounded|double|solid|shadow|none
}

--- Merge user options
---@param opts table? user config overrides
function M.setup(opts)
	for k, v in pairs(opts or {}) do
		if type(v) == "table" and type(M[k]) == "table" then
			M[k] = vim.tbl_extend("force", M[k], v)
		else
			M[k] = v
		end
	end
end

return M
