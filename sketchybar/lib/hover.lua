local colors = require("colors")
local popup = require("lib.popup")
local M = { active = nil, reset = nil }

local function value(option, default)
  if type(option) == "function" then return option() end
  if option == nil then return default end
  return option
end

function M.is_active(item)
  return M.active == item
end

function M.clear(except)
  if M.active and M.active ~= except and M.reset then M.reset() end
end

function M.bind(item, options)
  options = options or {}
  local function reset()
    if M.active == item then M.active = nil; M.reset = nil end
    if options.on_change then options.on_change(false) end
    local idle_color = value(options.idle_color, colors.primary)
    local idle_background = popup.is_open(item) or value(options.idle_background, false)
    item:set({ background = { color = popup.is_open(item) and colors.surface2 or colors.surface }, icon = { color = idle_color } })
    item:set({ background = { drawing = idle_background } })
  end

  local function enter()
    M.clear(item)
    M.active = item
    M.reset = reset
    if options.on_change then options.on_change(true) end
    item:set({ background = { color = colors.surface2 }, icon = { color = colors.primary } })
    item:set({ background = { drawing = true } })
  end
  item:subscribe("mouse.entered", enter)
  item:subscribe("sketchybar_test_hover", function(env) if env.TARGET == item.name then enter() end end)
  item:subscribe("sketchybar_test_hover_exit", function() if M.active == item then reset() end end)
  item:subscribe("mouse.exited", function()
    if M.active == item then reset() end
  end)
  item:subscribe("mouse.exited.global", function()
    if M.active == item then reset() end
    popup.schedule_close()
  end)
  item:set({ background = { drawing = value(options.idle_background, false) } })
end

return M
