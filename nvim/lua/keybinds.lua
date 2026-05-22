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
vim.keymap.set("n", "gd", vim.lsp.buf.definition)
vim.keymap.set("n", "gl", function() require("git-link.main").open_line_url() end)

--oil & fzf binds
vim.keymap.set("n", "<leader>e",  ":Oil<CR>")
vim.keymap.set("n", "<leader>f",  ":FzfLua files<CR>")
vim.keymap.set("n", "<leader>/",  ":FzfLua live_grep<CR>")
vim.keymap.set("n", "<leader>b",  ":FzfLua buffers<CR>")
vim.keymap.set("n", "<leader>r",  ":FzfLua resume<CR>")
vim.keymap.set("n", "<leader>o",  ":FzfLua oldfiles<CR>")
vim.keymap.set("n", "<leader>*",  ":FzfLua grep_cword<CR>")
vim.keymap.set("n", "<leader>s",  ":FzfLua lsp_document_symbols<CR>")
vim.keymap.set("n", "<leader>S",  ":FzfLua lsp_live_workspace_symbols<CR>")
vim.keymap.set("n", "gr",         ":FzfLua lsp_references<CR>")
vim.keymap.set("n", "<leader>d",  ":FzfLua diagnostics_document<CR>")
vim.keymap.set("n", "<leader>D",  ":FzfLua diagnostics_workspace<CR>")

--git binds
vim.keymap.set("n", "<leader>gs", ":FzfLua git_status<CR>")
vim.keymap.set("n", "<leader>gc", ":FzfLua git_bcommits<CR>")
vim.keymap.set("n", "<leader>gb", ":Gitsigns toggle_current_line_blame<CR>", { silent = true })

--folding
vim.keymap.set("n", "<leader>c", "za", { silent = true })
vim.keymap.set("n", "<leader>ca", function()
	if vim.o.foldlevel > 0 then
		vim.cmd("normal! zM")
	else
		vim.cmd("normal! zR")
	end
end, { silent = true })

vim.keymap.set("n", "<leader>nv", ":RenderMarkdown toggle<CR>", { silent = true })
