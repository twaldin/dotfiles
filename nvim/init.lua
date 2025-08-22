--no more lazy.nvim ever agin
vim.pack.add({
	{ src = "https://github.com/ellisonleao/gruvbox.nvim" },
	{ src = "https://github.com/stevearc/oil.nvim" },
	{ src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" },
	{ src = "https://github.com/ibhagwan/fzf-lua" },
	{ src = "https://github.com/mason-org/mason.nvim" },
	{ src = "https://github.com/Saghen/blink.cmp" },
})

vim.lsp.enable('lua_ls')
vim.lsp.enable('ts_ls')

require "mason".setup()
require "oil".setup()
require "nvim-treesitter".setup({ highlight = { enable = true, }, auto_install = true })
require "fzf-lua".setup()
require "blink.cmp".setup({
	keymap = {
		preset = 'super-tab',
	},
	appearance = {
		nerd_font_variant = 'mono'
	},
	completion = {
		documentation = { auto_show = false, },
	},
	sources = {
		default = { 'lsp', 'path', 'snippets', 'buffer' },
	},
	fuzzy = { implementation = "lua" },
})
_G.lasso = require "lasso"
_G.lasso.setup()
--load other files
require "theme"
require "autocmds"
require "options"
require "keybinds"
