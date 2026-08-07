local colors = require("colors")
local settings = require("settings")
local M = { open_host = nil, generation = 0, dynamic = {}, close_ticket = 0, test_hold = false, active_action = nil }

local function remove_dynamic()
  for index = #M.dynamic, 1, -1 do sbar.remove(M.dynamic[index]) end
  M.dynamic = {}
end

function M.close()
  M.generation = M.generation + 1
  M.close_ticket = M.close_ticket + 1
  if M.open_host then
    local idle_background = M.open_options and M.open_options.idle_background or nil
    M.open_host:set({ popup = { drawing = false }, background = { color = idle_background or colors.transparent } })
    M.open_host:set({ background = { drawing = idle_background ~= nil } })
    if M.open_options and M.open_options.on_close then M.open_options.on_close() end
  end
  remove_dynamic()
  M.open_host = nil
  M.open_options = nil
  M.test_hold = false
  M.active_action = nil
end

function M.is_open(host)
  return M.open_host == host
end

function M.is_current(host, token)
  return M.open_host == host and M.generation == token
end

function M.cancel_close()
  M.close_ticket = M.close_ticket + 1
end

function M.schedule_close()
  if M.test_hold or not M.open_host then return end
  M.close_ticket = M.close_ticket + 1
  local ticket = M.close_ticket
  sbar.delay(0.13, function()
    if ticket == M.close_ticket and M.open_host and not M.test_hold then M.close() end
  end)
end

function M.track(item)
  M.dynamic[#M.dynamic + 1] = item
  item:subscribe("mouse.entered", M.cancel_close)
  item:subscribe("mouse.exited", M.schedule_close)
  return item
end

local function action_value(value)
  return type(value) == "function" and value() or value
end

local function restore_action(entry)
  if not entry then return end
  entry.row:set({
    background = { drawing = false, color = colors.transparent },
    label = { color = action_value(entry.idle_color) },
    icon = { color = action_value(entry.idle_icon_color) },
  })
end

function M.action(row, options)
  if not row then return nil end
  options = options or {}
  local entry = {
    row = row,
    generation = M.generation,
    selected = options.selected == true,
    selected_color = options.selected_color or colors.surface,
    idle_color = options.idle_color or (options.selected and colors.primary or colors.muted),
    idle_icon_color = options.idle_icon_color or (options.selected and colors.primary or colors.muted),
  }
  row:subscribe("mouse.entered", function()
    if entry.generation ~= M.generation then return end
    if M.active_action and M.active_action.row ~= row then restore_action(M.active_action) end
    M.active_action = entry
    row:set({ background = { drawing = true, color = colors.surface2 }, label = { color = colors.primary }, icon = { color = colors.primary } })
  end)
  local function exit()
    if entry.generation ~= M.generation then return end
    if M.active_action and M.active_action.row == row then M.active_action = nil end
    restore_action(entry)
  end
  row:subscribe({ "mouse.exited", "mouse.exited.global" }, exit)
  restore_action(entry)
  sbar.delay(0.05, function()
    if entry.generation == M.generation and (not M.active_action or M.active_action.row ~= row) then restore_action(entry) end
  end)
  return row
end

local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" and type(target[key]) == "table" then merge(target[key], value)
    else target[key] = value end
  end
  return target
end

function M.row(host, token, suffix, properties)
  if not M.is_current(host, token) then return nil end
  local name = string.format("popup.%s.%s", host.name, suffix)
  local base = {
    position = "popup." .. host.name,
    associated_display = "active",
    width = settings.popup_width,
    padding_left = 0,
    padding_right = 0,
    background = { drawing = false, color = colors.transparent, height = 30, corner_radius = 0 },
    icon = { drawing = false, width = 0, padding_left = 0, padding_right = 0 },
    label = {
      string = "—",
      color = colors.normal,
      width = settings.popup_width - 20,
      align = "left",
      padding_left = 10,
      padding_right = 10,
      max_chars = 38,
    },
  }
  if suffix == "heading" then
    base.background = { drawing = true, color = colors.surface2, height = 32, corner_radius = 8 }
    base.label.color = colors.primary
    base.label.font = settings.font .. ":Bold:11.0"
  elseif suffix:match("_heading$") then
    base.background = { drawing = false, color = colors.transparent, height = 30, corner_radius = 0 }
    base.label.color = colors.primary
    base.label.font = settings.font .. ":Bold:11.0"
  end
  merge(base, properties)
  local row = M.track(sbar.add("item", name, base))
  row:set({ background = { drawing = base.background.drawing == true } })
  return row
end

function M.rebuild(host, token, builder)
  if not M.is_current(host, token) then return false end
  remove_dynamic()
  M.active_action = nil
  builder(token)
  return true
end

function M.slider(host, token, suffix, percentage, on_click)
  if not M.is_current(host, token) then return nil end
  local name = string.format("popup.%s.%s", host.name, suffix)
  local slider = sbar.add("slider", name, settings.popup_width - 16, {
    position = "popup." .. host.name,
    associated_display = "active",
    padding_left = 8,
    padding_right = 8,
    background = { drawing = false, color = colors.transparent, height = 30, corner_radius = 0 },
    icon = { drawing = false, width = 0, padding_left = 0, padding_right = 0 },
    label = { drawing = false },
    slider = {
      percentage = percentage,
      width = settings.popup_width - 16,
      highlight_color = colors.accent,
      background = {
        color = colors.surface2,
        height = 4,
        corner_radius = 2,
        border_width = 0,
        border_color = colors.transparent,
      },
      knob = {
        drawing = true,
        string = "●",
        color = colors.active,
        highlight_color = colors.active,
        font = { family = settings.font, style = "Regular", size = 13.0 },
        background = { drawing = false },
      },
    },
  })
  slider:set({ background = { drawing = false, color = colors.transparent } })
  slider:subscribe("mouse.clicked", function(env)
    if M.is_current(host, token) then on_click(env) end
  end)
  return M.track(slider)
end

function M.open(host, options)
  if M.open_host then M.close() end
  M.open_host = host
  M.open_options = options
  M.test_hold = false
  M.close_ticket = M.close_ticket + 1
  M.generation = M.generation + 1
  local token = M.generation
  host:set({
    popup = { drawing = true, align = options.align or "left", topmost = true },
    background = { drawing = true, color = colors.surface2 },
  })
  if options.build then options.build(token) end
end

function M.toggle(host, options)
  if M.open_host == host then M.close() else M.open(host, options) end
end

function M.bind(host, options)
  host:set({
    popup = {
      align = options.align or "left",
      topmost = true,
      blur_radius = 0,
      background = {
        color = colors.popup,
        border_width = 1,
        border_color = colors.border,
        corner_radius = 12,
      },
    },
  })
  host:subscribe("mouse.clicked", function(env)
    if env.BUTTON == "right" and options.right_click then
      options.right_click()
    elseif env.BUTTON == "middle" and options.middle_click then
      options.middle_click()
    elseif env.BUTTON == "left" or not env.BUTTON then
      M.toggle(host, options)
    end
  end)
  host:subscribe("sketchybar_test_popup", function(env)
    if env.TARGET == host.name then
      M.toggle(host, options)
      if M.open_host == host then M.test_hold = true; M.cancel_close() end
    end
  end)
end

local watcher = sbar.add("item", "popup.controller", {
  drawing = false,
  updates = true,
  associated_display = "active",
})
watcher:subscribe({ "display_change", "system_woke", "reload" }, function()
  M.close()
end)
watcher:subscribe("sketchybar_test_popup_exit", function()
  M.test_hold = false
  M.schedule_close()
end)

return M
