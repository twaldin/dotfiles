require "gruvbox".setup({
		contrast = 'hard',
})

vim.cmd('colorscheme gruvbox')

local gruvbox = require("gruvbox").palette
vim.cmd(":hi Normal guibg=none")
vim.cmd("hi signcolumn guibg=none")
vim.cmd("hi winbar guibg=none")
vim.cmd(":hi BlinkCmpMenu guibg=none")
vim.cmd(":hi BlinkCmpMenuBorder guibg=none")
vim.cmd(":hi BlinkCmpMenuSelection guibg=" .. gruvbox.dark1)
vim.cmd(":hi BlinkCmpScrollBarThumb guibg=" .. gruvbox.light4 .. " guifg=" .. gruvbox.light4)
vim.cmd(":hi BlinkCmpScrollBarGutter guibg=" .. gruvbox.dark3 .. " guifg=" .. gruvbox.dark3)
vim.cmd(":hi BlinkCmpDoc guibg=none")
vim.cmd(":hi BlinkCmpDocBorder guibg=none")
vim.cmd(":hi BlinkCmpDocSeparator guibg=none")
vim.cmd(":hi BlinkCmpSignatureHelp guibg=none")
vim.cmd(":hi BlinkCmpSignatureHelpBorder guibg=none")
vim.cmd(":hi BlinkCmpSignatureHelpActiveParameter guibg=none")
vim.cmd(":hi statusline guibg=none")
vim.cmd(":hi NormalFloat guibg=none")
vim.cmd(":hi FloatBorder guibg=none")
vim.cmd(":hi Pmenu guibg=none")
vim.cmd(":hi PmenuSel guibg=none")
vim.cmd(":hi PmenuSbar guibg=none")
vim.cmd(":hi PmenuThumb guibg=none")
