local function ghostty_theme()
  local f = io.open(vim.fn.expand("~/.config/ghostty/config"), "r")
  if not f then return nil end
  for line in f:lines() do
    local t = line:match("^theme%s*=%s*(.+)$")
    if t then
      f:close()
      return t:match("^%s*(.-)%s*$")
    end
  end
  f:close()
  return nil
end

-- Manual overrides for Ghostty themes that have no exact base16-nvim counterpart.
-- Keys = Ghostty theme name (exact). Values = base16-nvim scheme name.
-- Add entries here when you adopt a new Ghostty theme.
local THEME_MAP = {
  Mathias                 = "base16-classic-dark",
  LiquidCarbonTransparent = "base16-default-dark",
  LiquidCarbon            = "base16-default-dark",
}

-- "GruvboxDarkHard" → "gruvbox-dark-hard" (works for themes that follow the base16 naming convention)
local function to_kebab(s)
  return (s:gsub("(%u)", function(c) return "-" .. c:lower() end):gsub("^%-", ""))
end

local fallback = "base16-default-dark"
local ghostty = ghostty_theme()
if ghostty then
  local mapped = THEME_MAP[ghostty]
  local scheme = mapped or ("base16-" .. to_kebab(ghostty))
  local ok = pcall(function() vim.cmd("colorscheme " .. scheme) end)
  if not ok then vim.cmd("colorscheme " .. fallback) end
else
  vim.cmd("colorscheme " .. fallback)
end

vim.cmd("hi Normal guibg=none guifg=none")
vim.cmd("hi LineNr guibg=none")
vim.cmd("hi CursorLineNr guibg=none")
vim.cmd("hi SignColumn guibg=none")
vim.cmd("hi WinBar guibg=none")
vim.cmd("hi NormalFloat guibg=none")
vim.cmd("hi FloatBorder guibg=none")
vim.cmd("hi StatusLine guibg=none")

vim.cmd("hi BlinkCmpMenu guibg=none")
vim.cmd("hi BlinkCmpMenuBorder guibg=none")
vim.cmd("hi link BlinkCmpMenuSelection Visual")
vim.cmd("hi BlinkCmpScrollBarThumb guibg=none guifg=none")
vim.cmd("hi BlinkCmpScrollBarGutter guibg=none")
vim.cmd("hi BlinkCmpDoc guibg=none")
vim.cmd("hi BlinkCmpDocBorder guibg=none")
vim.cmd("hi BlinkCmpDocSeparator guibg=none")
vim.cmd("hi BlinkCmpSignatureHelp guibg=none")
vim.cmd("hi BlinkCmpSignatureHelpBorder guibg=none")
vim.cmd("hi BlinkCmpSignatureHelpActiveParameter guibg=none")
vim.cmd("hi Pmenu guibg=none")
vim.cmd("hi PmenuSel guibg=none")
vim.cmd("hi PmenuSbar guibg=none")
vim.cmd("hi PmenuThumb guibg=none")
