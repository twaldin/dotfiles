--plugins
vim.pack.add({
	{ src = "https://github.com/ellisonleao/gruvbox.nvim" },
	{ src = "https://github.com/stevearc/oil.nvim" },
	{ src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" },
	{ src = "https://github.com/ibhagwan/fzf-lua" },
	{ src = "https://github.com/mason-org/mason.nvim" },
	{ src = "https://github.com/Saghen/blink.cmp" },
	{ src = "https://github.com/L3MON4D3/LuaSnip" },
	{ src = "https://github.com/jbyuki/nabla.nvim", ft = "markdown" },
	{ src = "https://github.com/chomosuke/typst-preview.nvim" },
})

require "mason".setup()
require "typst-preview".setup()
require "oil".setup()
require "fzf-lua".setup()
require "nvim-treesitter".setup({
	highlight = {
		enable = true,
	},
	auto_install = true,
})
require "blink.cmp".setup({
	keymap = {
		preset = 'super-tab',
	},
	appearance = {
		nerd_font_variant = 'mono'
	},
	completion = {
		documentation = { auto_show = false, },
		menu = {scrollbar = false},
	},
	sources = {
		default = { 'lsp', 'path', 'snippets', 'buffer' },
	},
	snippets = {
		preset = 'default',
	},
	fuzzy = { implementation = "lua" },
})

--load other files
_G.lasso = require "lasso"
_G.lasso.setup()
require "theme"
require "autocmds"
require "options"
require "keybinds"
