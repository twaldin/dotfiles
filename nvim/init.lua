--leader and leaving
vim.g.mapleader = " "
vim.keymap.set("n", "<leader>wq", ":write<CR> :quit<CR>")
vim.keymap.set("n", "<leader>w", ":write<CR>")
vim.keymap.set("n", "<leader>q", ":quit<CR>")

--no more lazy.nvim ever agin
vim.pack.add({
  { src = "https://github.com/ellisonleao/gruvbox.nvim" },
  { src = "https://github.com/stevearc/oil.nvim" },
  { src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" },
  { src = "https://github.com/ibhagwan/fzf-lua" },
	{ src = "https://github.com/mason-org/mason.nvim"},
})

--lsp (not using nvimlspconfig cuz i took the whole lsp/ instead)
vim.lsp.enable('lua_ls')
vim.lsp.enable('ts_ls')
vim.keymap.set("n", "<leader>F", vim.lsp.buf.format)
--mason for downloading lsp servers and such
require "mason".setup()

--oil
require "oil".setup({ columns = { "icon", } })
vim.keymap.set("n", "<leader>e", ":Oil<CR>")

--treesitter only cuz i really need the better jsx syntax highlighting
require "nvim-treesitter".setup({ highlight = { enable = true, }, auto_install = true })

--fzf glazer forever
require "fzf-lua".setup()
vim.keymap.set("n", "<leader>f", ":FzfLua files<CR>")
vim.keymap.set("n", "<leader>/", ":FzfLua live_grep<CR>")

--corporate slave colorscheme
vim.cmd("colorscheme gruvbox")
vim.cmd(":hi statusline guibg=NONE")

--normal person options
vim.o.smarttab = true
vim.o.tabstop = 2
vim.o.shiftwidth = 2
vim.o.swapfile = false
vim.o.wrap = false
vim.o.clipboard = "unnamedplus"
vim.o.relativenumber = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.winborder = "rounded"
