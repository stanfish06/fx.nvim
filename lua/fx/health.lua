local M = {}

function M.check()
	vim.health.start("fx.nvim")
	if vim.fn.has("nvim-0.10") == 1 then
		vim.health.ok("Neovim >= 0.10")
	else
		vim.health.error("Neovim >= 0.10 required (vim.system)")
	end
	local exe = require("fx.config").fx_cmd[1]
	if vim.fn.executable(exe) == 1 then
		vim.health.ok(("`%s`: %s"):format(exe, vim.fn.exepath(exe)))
	else
		vim.health.error(
			("`%s` not found in $PATH"):format(exe),
			"install fx (https://github.com/vercel-labs/fx) or point config.fx_cmd at it"
		)
	end
end

return M
