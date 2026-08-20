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

vim.keymap.set("n", "<Plug>(fx-ask)", "<Cmd>Fx<CR>", { silent = true })
vim.keymap.set("x", "<Plug>(fx-ask)", ":Fx<CR>", { silent = true })

if not vim.g.fx_no_default_keymaps then
	vim.keymap.set({ "n", "x" }, "<leader>k", "<Plug>(fx-ask)", { desc = "fx: inline request" })
end
