require "gruvbox".setup({
		contrast = 'hard',
})

vim.cmd('colorscheme gruvbox')

local gruvbox = require("gruvbox").palette
vim.cmd(":hi statusline guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi NormalFloat guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi FloatBorder guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi BlinkCmpMenu guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi BlinkCmpMenuBorder guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi BlinkCmpDoc guibg=" .. gruvbox.dark0_hard)
vim.cmd(":hi BlinkCmpDocBorder guibg=" .. gruvbox.dark0_hard)
