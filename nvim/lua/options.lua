--tabs
vim.o.smarttab = true
vim.o.tabstop = 2
vim.o.shiftwidth = 2

--normal
vim.o.swapfile = false
vim.o.wrap = false
vim.o.clipboard = "unnamedplus"
vim.o.relativenumber = true
vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.scrolloff = 10

--theming
vim.o.winborder = "rounded"
vim.o.cmdheight = 1
vim.o.showmode = false
vim.o.ruler = false
vim.o.laststatus = 0

--winbar
local winbar = require "winbar"
_G.get_winbar = winbar.get_winbar
_G.get_search_count = winbar.get_search_count
vim.o.winbar = "%{%v:lua.get_winbar()%}"

