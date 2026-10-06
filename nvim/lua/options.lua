--tabs
vim.o.smarttab = true
vim.o.tabstop = 2
vim.o.shiftwidth = 2

--normal
vim.o.swapfile = false
vim.o.wrap = false
vim.o.clipboard = "unnamedplus"
-- Over SSH the machine's own clipboard (pbcopy) is the remote one. Yank through OSC 52 so the
-- terminal you sit at (Ghostty, or herdr's client, which forwards it) sets your local clipboard.
-- Paste from nvim's own register: OSC 52 reads would make the terminal prompt or hang.
if vim.env.SSH_TTY or vim.env.SSH_CONNECTION then
  local osc52 = require "vim.ui.clipboard.osc52"
  local function paste()
    return { vim.fn.split(vim.fn.getreg "", "\n"), vim.fn.getregtype "" }
  end
  vim.g.clipboard = {
    name = "OSC 52",
    copy = { ["+"] = osc52.copy "+", ["*"] = osc52.copy "*" },
    paste = { ["+"] = paste, ["*"] = paste },
  }
end
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
vim.o.shortmess = vim.o.shortmess .. "S"

--winbar
local winbar = require "winbar"
_G.get_winbar = winbar.get_winbar
_G.get_search_count = winbar.get_search_count
vim.o.winbar = "%{%v:lua.get_winbar()%}"

--cursor
vim.o.guicursor = ""

--folding (treesitter-driven, start fully open)
vim.o.foldmethod = "expr"
vim.o.foldexpr = "v:lua.vim.treesitter.foldexpr()"
vim.o.foldenable = true
vim.o.foldlevel = 99
vim.o.foldlevelstart = 99
