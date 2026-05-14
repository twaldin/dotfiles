-- disable unused providers (silences checkhealth noise)
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0

-- treesitter parser dir lives in site/, make sure it's on rtp
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/site")

--plugins
vim.pack.add({
	{ src = "https://github.com/RRethy/base16-nvim" },
	{ src = "https://github.com/stevearc/oil.nvim" },
	{ src = "https://github.com/echasnovski/mini.icons" },
	{ src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" },
	{ src = "https://github.com/ibhagwan/fzf-lua" },
	{ src = "https://github.com/echasnovski/mini.icons" },
	{ src = "https://github.com/mason-org/mason.nvim" },
	{ src = "https://github.com/Saghen/blink.cmp" },
	{ src = "https://github.com/L3MON4D3/LuaSnip" },
	{ src = "https://github.com/jbyuki/nabla.nvim", ft = "markdown" },
	{ src = "https://github.com/chomosuke/typst-preview.nvim" },
	{ src = "https://github.com/lewis6991/gitsigns.nvim"},
	{ src = "https://github.com/juacker/git-link.nvim" },
})

require "mason".setup()
require "typst-preview".setup()
require "mini.icons".setup()
require "oil".setup()
require "mini.icons".setup()
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
	fuzzy = {
		implementation = "lua",
		prebuilt_binaries = { download = false },
	},
})
require('gitsigns').setup {
  signs = {
    add          = { text = '┃' },
    change       = { text = '┃' },
    delete       = { text = '_' },
    topdelete    = { text = '‾' },
    changedelete = { text = '~' },
    untracked    = { text = '┆' },
  },
  signs_staged = {
    add          = { text = '┃' },
    change       = { text = '┃' },
    delete       = { text = '_' },
    topdelete    = { text = '‾' },
    changedelete = { text = '~' },
    untracked    = { text = '┆' },
  },
  signs_staged_enable = true,
  signcolumn = true,  -- Toggle with `:Gitsigns toggle_signs`
  numhl      = false, -- Toggle with `:Gitsigns toggle_numhl`
  linehl     = false, -- Toggle with `:Gitsigns toggle_linehl`
  word_diff  = false, -- Toggle with `:Gitsigns toggle_word_diff`
  watch_gitdir = {
    follow_files = true
  },
  auto_attach = true,
  attach_to_untracked = false,
  current_line_blame = false, -- Toggle with `:Gitsigns toggle_current_line_blame`
  current_line_blame_opts = {
    virt_text = true,
    virt_text_pos = 'eol', -- 'eol' | 'overlay' | 'right_align'
    delay = 1000,
    ignore_whitespace = false,
    virt_text_priority = 100,
    use_focus = true,
  },
  current_line_blame_formatter = '<author>, <author_time:%R> - <summary>',
  blame_formatter = nil, -- Use default
  sign_priority = 6,
  update_debounce = 100,
  status_formatter = nil, -- Use default
  max_file_length = 40000, -- Disable if file is longer than this (in lines)
  preview_config = {
    -- Options passed to nvim_open_win
    style = 'minimal',
    relative = 'cursor',
    row = 0,
    col = 1
  },
}

--load other files
_G.lasso = require "lasso"
_G.lasso.setup()
require "theme"
require "autocmds"
require "options"
require "keybinds"
