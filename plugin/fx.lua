if vim.g.loaded_fx then
	return
end
vim.g.loaded_fx = true

vim.api.nvim_create_user_command("Fx", function(o)
	require("fx").main(o)
end, {
	range = true,
	nargs = "*",
	complete = function()
		return { "ask", "stop", "restart", "rewind", "history" }
	end,
})
