--leader and leaving
vim.g.mapleader = " "
vim.keymap.set("n", "<leader>wq", ":write<CR> :quit<CR>")
vim.keymap.set("n", "<leader>w", ":write<CR>")
vim.keymap.set("n", "<leader>q", ":quit<CR>")

--centered navigation
vim.keymap.set("n", "<C-d>", "<C-d>zz")
vim.keymap.set("n", "<C-u>", "<C-u>zz")
vim.keymap.set("n", "n", "nzz")
vim.keymap.set("n", "N", "Nzz")
vim.keymap.set("n", "<Esc>", ":nohl<CR>")

--no more lazy.nvim ever agin
vim.pack.add({
	{ src = "https://github.com/ellisonleao/gruvbox.nvim" },
	{ src = "https://github.com/stevearc/oil.nvim" },
	{ src = "https://github.com/nvim-treesitter/nvim-treesitter", version = "main" },
	{ src = "https://github.com/ibhagwan/fzf-lua" },
	{ src = "https://github.com/mason-org/mason.nvim" },
	{ src = "https://github.com/Saghen/blink.cmp" },
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

require "blink.cmp".setup({
	keymap = {
		preset = 'enter',
		['<Tab>'] = {
			function(cmp)
				local line = vim.api.nvim_get_current_line()
				local col = vim.api.nvim_win_get_cursor(0)[2]
				local before_cursor = line:sub(1, col)
				if before_cursor:match('%S') then
					if cmp.is_visible() then
						return cmp.accept()
					else
						return cmp.show()
					end
				else
					return vim.api.nvim_feedkeys('\t', 'n', false)
				end
			end,
			'fallback'
		}
	},
	appearance = {
		nerd_font_variant = 'mono'
	},
	completion = {
		documentation = { auto_show = false, },
		trigger = { auto_show = false, },
	},
	sources = {
		default = { 'lsp', 'path', 'snippets', 'buffer' },
	},
	cmdline = {
		sources = {},
	},
	fuzzy = { implementation = "lua" },
})

--lasso marks
local lasso = require "lasso"
lasso.setup()
vim.keymap.set("n", "<leader>H", function() lasso.mark_file() end)
vim.keymap.set("n", "<leader>h", function() lasso.open_marks_tracker() end)
for i = 1, 9 do
	vim.keymap.set("n", "<leader>" .. tostring(i), function() lasso.open_marked_file(i) end)
end

--floating command line
local cmdline = require "cmdline"
vim.keymap.set("n", ":", function() cmdline.open_floating_cmdline() end)
--corporate slave colorscheme
require "gruvbox".setup({
		contrast = 'hard',
})
vim.cmd('colorscheme gruvbox')
local gruvbox = require("gruvbox").palette
vim.cmd(":hi statusline guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi NormalFloat guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi FloatBorder guibg=" .. gruvbox.dark0_hard)
--no status line, only winbar
vim.o.laststatus = 0

--winbar with filename and git status
local git = require "git"
_G.get_winbar = git.get_winbar
vim.o.winbar = "%{%v:lua.get_winbar()%}"

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
vim.o.cmdheight = 0
vim.o.showmode = false
vim.o.showcmd = false
vim.o.ruler = false

--load autocmds
require "autocmds"
