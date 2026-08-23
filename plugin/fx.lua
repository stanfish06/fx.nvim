if vim.g.loaded_fx then
	return
end
vim.g.loaded_fx = true

vim.api.nvim_create_user_command("Fx", function(o)
	require("fx").main(o)
end, {
	range = true,
	nargs = "*",
	complete = function(arglead, cmdline, pos)
		-- subcommands complete only in first-argument position
		if cmdline:sub(1, pos):match("Fx%s+%S+%s") then
			return {}
		end
		return vim.tbl_filter(function(c)
			return vim.startswith(c, arglead)
		end, { "ask", "list", "model", "stop", "restart", "rewind", "history" })
	end,
})
