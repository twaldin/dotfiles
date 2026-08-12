local colors = require("colors")
local M = {
  active = nil,
  reset = nil,
  bindings = setmetatable({}, { __mode = "k" }),
}

local function value(option, default)
  if type(option) == "function" then return option() end
  if option == nil then return default end
  return option
end

function M.is_active(item)
  return M.active == item
end

-- Routine/provider renders call this so a live update cannot erase the active
-- hover cue. Semantic safety colors remain visible while hovered.
function M.foreground(item, idle_color, preserve_hover_color)
  if not M.is_active(item) then return idle_color end
  if preserve_hover_color == true
     or idle_color == colors.warning
     or idle_color == colors.critical
     or idle_color == colors.state.actionable
     or idle_color == colors.state.recording
     or idle_color == colors.red then return idle_color end
  return colors.primary
end

local function repaint(item)
  local state = M.bindings[item]
  if not state then return false end
  local idle_color = value(state.options.idle_color, colors.primary)
  local hovered = M.active == item
  local preserve_hover_color = value(
    state.options.preserve_hover_color, false) == true
  local background_color
  if state.popup_open then
    background_color = colors.right_hover
  elseif hovered then
    background_color = colors.hover
  else
    background_color = colors.surface
  end
  item:set({
    background = {
      drawing = state.popup_open or hovered or value(state.options.idle_background, false),
      color = background_color,
    },
    icon = { color = hovered and M.foreground(
      item, idle_color, preserve_hover_color) or idle_color },
  })
  return true
end

function M.repaint(item)
  return repaint(item)
end

function M.set_popup_open(item, is_open)
  local state = M.bindings[item]
  if not state then return false end
  state.popup_open = is_open == true
  repaint(item)
  return true
end

function M.clear(except)
  if M.active and M.active ~= except and M.reset then M.reset() end
end

function M.bind(item, options)
  options = options or {}
  local state = { options = options, popup_open = false }
  M.bindings[item] = state

  local function reset()
    if M.active == item then M.active = nil; M.reset = nil end
    if options.on_change then options.on_change(false) end
    repaint(item)
  end

  local function enter()
    M.clear(item)
    M.active = item
    M.reset = reset
    if options.on_change then options.on_change(true) end
    repaint(item)
  end

  item:subscribe("mouse.entered", enter)
  item:subscribe("sketchybar_test_hover", function(env) if env.TARGET == item.name then enter() end end)
  item:subscribe("sketchybar_test_hover_exit", function() if M.active == item then reset() end end)
  item:subscribe("mouse.exited", function()
    if M.active == item then reset() end
  end)
  item:subscribe("mouse.exited.global", function()
    if M.active == item then reset() end
  end)
  repaint(item)
end

-- Bind one hit item to a separate, persistent bracket surface. The logical
-- hover owner stays the item so existing is_active/clear callers keep working.
function M.bind_surface(item, surface, options)
  options = options or {}
  local leave_generation = 0

  local function paint(active)
    surface:set({
      background = {
        drawing = true,
        color = active and value(options.hover_surface, colors.hover)
          or value(options.idle_surface, colors.surface),
        border_color = active and value(options.hover_border, value(options.idle_border, colors.border))
          or value(options.idle_border, colors.border),
      },
    })
    if options.on_change then options.on_change(active) end
  end

  local function reset()
    leave_generation = leave_generation + 1
    if M.active == item then M.active = nil; M.reset = nil end
    paint(false)
  end

  local function enter()
    leave_generation = leave_generation + 1
    if M.active == item then return end
    M.clear(item)
    M.active = item
    M.reset = reset
    paint(true)
  end

  local function leave()
    if M.active ~= item then return end
    leave_generation = leave_generation + 1
    local token = leave_generation
    sbar.delay(0.05, function()
      if token == leave_generation and M.active == item then reset() end
    end)
  end

  item:subscribe("mouse.entered", enter)
  item:subscribe("mouse.exited", leave)
  item:subscribe("sketchybar_test_hover", function(env)
    if env.TARGET == item.name then enter() end
  end)
  item:subscribe("sketchybar_test_hover_exit", function(env)
    if (not env.TARGET or env.TARGET == item.name) and M.active == item then reset() end
  end)
  item:subscribe("mouse.exited.global", function()
    if M.active == item then reset() end
  end)
  paint(false)
end

return M
