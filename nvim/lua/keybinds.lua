vim.g.mapleader = " "

vim.keymap.set("n", "<leader>wq", ":write<CR> :quit<CR>")
vim.keymap.set("n", "<leader>w", ":write<CR>")
vim.keymap.set("n", "<leader>q", ":quit<CR>")

--centered search/nav
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")
vim.keymap.set("n", "n", "nzz")
vim.keymap.set("n", "N", "Nzz")

--clear search with esc
vim.keymap.set("n", "<Esc>", function()
	vim.cmd("nohl")
	vim.fn.setreg('/', '')
end)

--see lua/lasso.lua
vim.keymap.set("n", "<leader>H", function() lasso.mark_file() end)
vim.keymap.set("n", "<leader>h", function() lasso.open_marks_tracker() end)
for i = 1, 9 do
	vim.keymap.set("n", "<leader>" .. tostring(i), function() lasso.open_marked_file(i) end)
end

vim.keymap.set("n", "<leader>F", vim.lsp.buf.format)

--oil & fzf binds
vim.keymap.set("n", "<leader>e", ":Oil<CR>")
vim.keymap.set("n", "<leader>f", ":FzfLua files<CR>")
vim.keymap.set("n", "<leader>/", ":FzfLua live_grep<CR>")
