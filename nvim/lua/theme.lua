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

-- Groups whose bg we keep — selection/search indicators rely on a visible bg.
local KEEP_BG = {
  Visual = true, VisualNOS = true,
  Search = true, IncSearch = true, CurSearch = true,
  Substitute = true,
  DiffAdd = true, DiffChange = true, DiffDelete = true, DiffText = true,
  MatchParen = true,
}

local function make_transparent()
  for _, group in ipairs(vim.fn.getcompletion("", "highlight")) do
    if not KEEP_BG[group] then
      local hl = vim.api.nvim_get_hl(0, { name = group })
      if not hl.link and (hl.bg or hl.ctermbg) then
        hl.bg = nil
        hl.ctermbg = nil
        vim.api.nvim_set_hl(0, group, hl)
      end
    end
  end
end

local function apply_overrides()
  make_transparent()
  local ok, b16 = pcall(require, "base16-colorscheme")
  if ok and b16.colors then
    vim.api.nvim_set_hl(0, "RenderMarkdownCode", { bg = b16.colors.base02 })
  end
  vim.cmd("hi link BlinkCmpMenuSelection Visual")
end

vim.api.nvim_create_autocmd("ColorScheme", { callback = apply_overrides })

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

apply_overrides()
