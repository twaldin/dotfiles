local colors = require("colors")
local settings = require("settings")
local hover = require("lib.hover")

local M = {
  open_host = nil,
  generation = 0,
  render_revision = 0,
  dynamic = {},
  entries = {},
  row_entries = setmetatable({}, { __mode = "k" }),
  close_ticket = 0,
  test_hold = false,
  active_action = nil,
  pointer_entry = nil,
  host_inside = false,
  popup_inside = false,
  render_hold = false,
  reconcile_seen = nil,
}

local function action_value(value)
  return type(value) == "function" and value() or value
end

local function checked_options(value)
  return type(value) == "table" and value or {}
end

local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" and type(target[key]) == "table" then
      merge(target[key], value)
    else
      target[key] = value
    end
  end
  return target
end

local function host_visual(host, is_open, options)
  if hover.set_popup_open(host, is_open) then return end
  local idle_background = options and options.idle_background or nil
  host:set({
    background = {
      drawing = is_open or idle_background ~= nil,
      color = is_open and colors.right_hover or (idle_background or colors.transparent),
    },
  })
end

local function remove_entry(entry)
  if not entry or entry.removed then return end
  entry.removed = true
  M.row_entries[entry.item] = nil
  sbar.remove(entry.item)
end

local function remove_dynamic()
  for index = #M.dynamic, 1, -1 do remove_entry(M.dynamic[index]) end
  M.dynamic = {}
  M.entries = {}
  M.row_entries = setmetatable({}, { __mode = "k" })
end

local function restore_action(entry)
  if not entry or entry.removed or not entry.action_enabled then return end
  local selected = entry.selected == true
  entry.item:set({
    background = {
      drawing = selected,
      color = selected and entry.selected_color or colors.transparent,
    },
    label = { color = action_value(entry.idle_color) },
    icon = { color = action_value(entry.idle_icon_color) },
  })
end

local function current_entry(entry)
  return entry
    and not entry.removed
    and entry.generation == M.generation
    and M.entries[entry.key] == entry
    and M.open_host ~= nil
end

local function interactive_entry(entry)
  return current_entry(entry) and entry.visible == true
end

local function cancel_action(entry)
  if M.active_action == entry then M.active_action = nil end
  if current_entry(entry) and entry.action_enabled then restore_action(entry) end
end

local function bind_entry(entry)
  entry.item:subscribe("mouse.entered", function()
    if not interactive_entry(entry) then return end
    M.pointer_entry = entry
    M.popup_inside = true
    M.host_inside = false
    M.cancel_close()
    if not entry.action_enabled then return end
    if M.active_action and M.active_action ~= entry then restore_action(M.active_action) end
    M.active_action = entry
    entry.item:set({
      background = { drawing = true, color = colors.surface2 },
      label = { color = colors.primary },
      icon = { color = colors.primary },
    })
  end)
  entry.item:subscribe("mouse.exited", function()
    if M.pointer_entry == entry then M.pointer_entry = nil end
    cancel_action(entry)
  end)
  entry.item:subscribe("mouse.exited.global", function()
    cancel_action(entry)
    if not current_entry(entry) then return end
    local was_inside = M.host_inside or M.popup_inside
    M.pointer_entry = nil
    M.host_inside = false
    M.popup_inside = false
    if was_inside then M.schedule_close() end
  end)
  entry.item:subscribe("mouse.clicked", function(env)
    if not interactive_entry(entry) then return end
    local callback = entry.click_callback
    if callback then callback(env or {}) end
  end)
end

local function new_entry(kind, host, suffix, properties, width)
  local name = string.format("popup.%s.%s", host.name, suffix)
  local item
  if kind == "slider" or kind == "graph" then
    item = sbar.add(kind, name, width, properties)
  else
    item = sbar.add("item", name, properties)
  end
  local entry = {
    key = suffix,
    kind = kind,
    item = item,
    generation = M.generation,
    revision = M.render_revision,
    removed = false,
    action_enabled = false,
    click_callback = nil,
    visible = true,
  }
  M.entries[suffix] = entry
  M.dynamic[#M.dynamic + 1] = entry
  M.row_entries[item] = entry
  bind_entry(entry)
  return entry
end

local function existing_entry(kind, suffix)
  local entry = M.entries[suffix]
  if not entry or entry.removed or entry.kind ~= kind or entry.generation ~= M.generation then return nil end
  entry.revision = M.render_revision
  entry.visible = true
  entry.action_enabled = false
  entry.click_callback = nil
  if M.reconcile_seen then M.reconcile_seen[suffix] = true end
  return entry
end

local function remember_entry(entry)
  if M.reconcile_seen then M.reconcile_seen[entry.key] = true end
  return entry.item
end

function M.close()
  M.generation = M.generation + 1
  M.close_ticket = M.close_ticket + 1
  local host, options = M.open_host, M.open_options
  if host then
    host:set({ popup = { drawing = false } })
    host_visual(host, false, options)
    if hover.is_active(host) then hover.clear() end
    if options and options.on_close then options.on_close() end
  end
  remove_dynamic()
  M.open_host = nil
  M.open_options = nil
  M.test_hold = false
  M.active_action = nil
  M.pointer_entry = nil
  M.host_inside = false
  M.popup_inside = false
  M.render_hold = false
  M.reconcile_seen = nil
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
  if M.test_hold or M.render_hold or not M.open_host then return end
  M.close_ticket = M.close_ticket + 1
  local ticket = M.close_ticket
  local generation = M.generation
  sbar.delay(0.13, function()
    if ticket ~= M.close_ticket or generation ~= M.generation then return end
    if M.test_hold or M.render_hold or M.host_inside or M.popup_inside or not M.open_host then return end
    M.close()
  end)
end

function M.action(row, options)
  local entry = M.row_entries[row]
  if not interactive_entry(entry) then return nil end
  options = checked_options(options)
  entry.action_enabled = true
  entry.selected = options.selected == true
  entry.selected_color = options.selected_color or colors.surface
  entry.idle_color = options.idle_color or (entry.selected and colors.primary or colors.muted)
  entry.idle_icon_color = options.idle_icon_color or (entry.selected and colors.primary or colors.muted)
  restore_action(entry)
  return row
end

function M.on_click(row, callback)
  local entry = M.row_entries[row]
  if not interactive_entry(entry) then return nil end
  entry.click_callback = callback
  return row
end

local function row_properties(host, suffix, properties)
  local base = {
    drawing = true,
    position = "popup." .. host.name,
    display = "active",
    width = settings.popup_width,
    padding_left = 0,
    padding_right = 0,
    background = { drawing = false, color = colors.transparent, height = settings.popup_layout.row_height, corner_radius = 0 },
    icon = { drawing = false, width = 0, padding_left = 0, padding_right = 0 },
    label = {
      string = "—",
      color = colors.normal,
      width = settings.popup_width - (2 * settings.popup_layout.gutter),
      align = "left",
      padding_left = settings.popup_layout.gutter,
      padding_right = settings.popup_layout.gutter,
      font = settings.type.popup_row,
    },
  }
  if suffix == "heading" then
    base.background = { drawing = true, color = colors.surface2, height = settings.popup_layout.heading_height, corner_radius = 0 }
    base.label.color = colors.primary
    base.label.font = settings.type.popup_head
  elseif suffix:match("_heading$") then
    base.label.color = colors.primary
    base.label.font = settings.type.popup_head
  end
  local result = merge(base, properties)
  if not (properties and properties.label and properties.label.width ~= nil) then
    local icon_width = result.icon and result.icon.drawing ~= false and tonumber(result.icon.width) or 0
    result.label.width = math.max(0, settings.popup_width - 20 - (icon_width or 0))
  end
  return result
end

function M.row(host, token, suffix, properties)
  if not M.is_current(host, token) then return nil end
  local base = row_properties(host, suffix, properties)
  local entry = existing_entry("item", suffix)
  if entry then
    entry.item:set(base)
  else
    local obsolete = M.entries[suffix]
    if obsolete then remove_entry(obsolete) end
    entry = new_entry("item", host, suffix, base)
  end
  entry.item:set({ background = { drawing = base.background.drawing == true } })
  return remember_entry(entry)
end

function M.header(host, token, title, chip, options)
  options = checked_options(options)
  local text = tostring(title or "")
  if chip and tostring(chip) ~= "" then text = text .. "  ·  " .. tostring(chip) end
  return M.row(host, token, "heading", {
    background = { drawing = true, color = colors.surface2, height = settings.popup_layout.heading_height },
    label = {
      string = text, align = "center", color = options.color or colors.primary,
      font = settings.type.popup_head, max_chars = 44,
    },
  })
end

function M.field(host, token, suffix, label, value, options)
  options = checked_options(options)
  local layout = settings.popup_layout
  local left_width = settings.popup_width - (2 * layout.gutter) - layout.column_gap - layout.value_width
  return M.row(host, token, suffix, {
    background = { drawing = options.selected == true, color = options.background or colors.surface2, height = options.height or layout.row_height },
    icon = {
      drawing = true, string = tostring(label or ""), color = options.label_color or colors.primary,
      width = left_width, align = "left", padding_left = layout.gutter, padding_right = 0,
      font = options.font or settings.type.popup_row, max_chars = options.label_max_chars or 28,
    },
    label = {
      drawing = true, string = tostring(value == nil and "—" or value), color = options.value_color or options.color or colors.primary,
      width = layout.value_width, align = "right", padding_left = layout.column_gap,
      padding_right = layout.gutter, font = options.font or settings.type.popup_row,
      max_chars = options.value_max_chars or 16,
    },
  })
end

function M.note(host, token, suffix, text, options)
  options = checked_options(options)
  return M.row(host, token, suffix, {
    background = { drawing = options.background ~= nil, color = options.background or colors.transparent, height = options.height or settings.popup_layout.row_height },
    label = {
      string = tostring(text or ""), color = options.color or colors.muted,
      align = options.align or "left", font = options.font or settings.type.popup_row,
      max_chars = options.max_chars or 48,
    },
  })
end

function M.axis(host, token, suffix, left, right)
  return M.field(host, token, suffix, left, right, {
    height = settings.popup_layout.axis_height, font = settings.type.popup_axis,
    label_color = colors.muted, value_color = colors.muted,
  })
end

function M.section(host, token, suffix, title)
  return M.row(host, token, suffix, {
    background = { drawing = true, color = colors.surface, height = settings.popup_layout.section_height },
    icon = {
      drawing = true, string = "▎", width = 20, color = colors.blue,
      padding_left = 8, padding_right = 0,
    },
    label = {
      string = tostring(title or ""), color = colors.muted, align = "left",
      padding_left = 4, padding_right = 10,
      font = settings.type.popup_section,
    },
  })
end

local function left_click(env)
  return not env.BUTTON or env.BUTTON == "left"
end

function M.choice(host, token, suffix, label, selected, callback, options)
  options = checked_options(options)
  local row = M.row(host, token, suffix, {
    icon = {
      drawing = true, string = options.icon or (selected and "✓" or ""), width = 24,
      color = options.color or colors.green, padding_left = 8, padding_right = 0,
    },
    label = { string = label, color = selected and colors.primary or colors.muted },
    background = { drawing = selected, color = colors.surface2 },
  })
  if not row then return nil end
  M.action(row, {
    selected = selected, idle_color = selected and colors.primary or colors.muted,
    idle_icon_color = selected and (options.color or colors.green) or colors.muted,
  })
  if type(callback) == "function" and (options.allow_selected or not selected) then
    M.on_click(row, function(env)
      if left_click(env or {}) and M.is_current(host, token) then callback() end
    end)
  end
  return row
end

function M.link(host, token, suffix, label, callback, options)
  options = checked_options(options)
  local row = M.row(host, token, suffix, {
    icon = {
      drawing = true, string = options.icon or "↗", width = 24,
      color = options.color or colors.blue, padding_left = 8, padding_right = 0,
    },
    label = { string = label, color = colors.primary },
  })
  if not row then return nil end
  M.action(row, { idle_color = colors.primary, idle_icon_color = options.color or colors.blue })
  M.on_click(row, function(env)
    if not left_click(env or {}) or not M.is_current(host, token) then return end
    M.close()
    callback()
  end)
  return row
end

function M.rebuild(host, token, builder)
  if not M.is_current(host, token) then return false end
  M.render_revision = M.render_revision + 1
  M.render_hold = true
  M.cancel_close()
  local seen = {}
  M.reconcile_seen = seen
  for _, entry in ipairs(M.dynamic) do
    if current_entry(entry) then
      entry.action_enabled = false
      entry.click_callback = nil
    end
  end
  local ok, message = xpcall(function() builder(token) end, debug.traceback)
  M.reconcile_seen = nil
  if not ok then
    M.render_hold = false
    error(message)
  end
  for _, entry in ipairs(M.dynamic) do
    if current_entry(entry) and not seen[entry.key] then
      if M.active_action == entry then M.active_action = nil end
      if M.pointer_entry == entry then M.pointer_entry = nil end
      entry.visible = false
      entry.action_enabled = false
      entry.click_callback = nil
      entry.item:set({ drawing = false })
    end
  end
  M.render_hold = false
  if not M.host_inside and not M.popup_inside then M.schedule_close() end
  return next(seen) ~= nil
end

function M.slider(host, token, suffix, percentage, on_click, options)
  if not M.is_current(host, token) then return nil end
  options = checked_options(options)
  local width = settings.popup_width - 16
  local properties = {
    drawing = true,
    position = "popup." .. host.name,
    display = "active",
    padding_left = 8,
    padding_right = 8,
    background = { drawing = false, color = colors.transparent, height = 30, corner_radius = 0 },
    icon = { drawing = false, width = 0, padding_left = 0, padding_right = 0 },
    label = { drawing = false },
    slider = {
      percentage = percentage,
      width = width,
      highlight_color = options.color or colors.accent,
      background = {
        color = colors.surface2,
        height = 4,
        corner_radius = 0,
        border_width = 0,
        border_color = colors.transparent,
      },
      knob = {
        drawing = options.knob ~= false,
        string = "●",
        color = colors.active,
        highlight_color = colors.active,
        font = settings.type.popup_action_icon,
        background = { drawing = false },
      },
    },
  }
  local entry = existing_entry("slider", suffix)
  if entry then
    entry.item:set(properties)
  else
    local obsolete = M.entries[suffix]
    if obsolete then remove_entry(obsolete) end
    entry = new_entry("slider", host, suffix, properties, width)
  end
  if type(on_click) == "function" then
    entry.click_callback = function(env)
      if M.is_current(host, token) then on_click(env) end
    end
  else
    entry.click_callback = nil
  end
  entry.item:set({ background = { drawing = false, color = colors.transparent } })
  return remember_entry(entry)
end

function M.meter(host, token, suffix, percentage, color)
  return M.slider(host, token, suffix, percentage, nil, { knob = false, color = color })
end

function M.graph(host, token, suffix, values, current, options)
  if not M.is_current(host, token) then return nil end
  options = checked_options(options)
  local width = settings.popup_width - 16
  local properties = {
    drawing = true,
    position = "popup." .. host.name,
    display = "active",
    padding_left = 8,
    padding_right = 8,
    background = {
      drawing = true,
      color = options.background or colors.surface2,
      height = options.height or 76,
      corner_radius = 0,
    },
    icon = { drawing = false },
    label = { drawing = false },
    graph = {
      color = options.color or colors.blue,
      fill_color = options.fill_color or colors.transparent,
      line_width = options.line_width or 1,
    },
  }
  local entry = existing_entry("graph", suffix)
  local created = false
  if entry then
    entry.item:set(properties)
  else
    local obsolete = M.entries[suffix]
    if obsolete then remove_entry(obsolete) end
    entry = new_entry("graph", host, suffix, properties, width)
    created = true
  end
  local function normalized(value)
    value = tonumber(value)
    return value and (math.max(0, math.min(100, value)) / 100) or nil
  end
  local reset = not created and options.reset_id ~= nil and options.reset_id ~= entry.reset_id
  if created or reset then
    local source = values or {}
    if #source == 0 and tonumber(current) then source = { current } end
    local points = {}
    if #source > 0 then
      for index = 1, width do
        local source_index = #source == 1 and 1 or math.floor((index - 1) * (#source - 1) / (width - 1)) + 1
        points[#points + 1] = normalized(source[source_index]) or 0
      end
      entry.item:push(points)
    end
    entry.last_sample_id = options.sample_id
    entry.reset_id = options.reset_id
  elseif tonumber(current) and (options.sample_id == nil or options.sample_id ~= entry.last_sample_id) then
    entry.item:push({ normalized(current) })
    entry.last_sample_id = options.sample_id
  end
  return remember_entry(entry)
end

function M.open(host, options)
  options = checked_options(options)
  if M.open_host then M.close() end
  M.open_host = host
  M.open_options = options
  M.test_hold = false
  M.generation = M.generation + 1
  M.pointer_entry = nil
  M.host_inside = true
  M.popup_inside = false
  M.cancel_close()
  local token = M.generation
  host:set({ popup = { drawing = true, align = options.align or "left", topmost = true } })
  host_visual(host, true, options)
  if options.build then M.rebuild(host, token, options.build) end
  return token
end

function M.toggle(host, options)
  if M.open_host == host then M.close() else M.open(host, options) end
end

function M.bind(host, options)
  options = checked_options(options)
  host:set({
    popup = {
      align = options.align or "left",
      topmost = true,
      blur_radius = 0,
      background = {
        color = colors.popup,
        border_width = 1,
        border_color = colors.border,
        corner_radius = 0,
      },
    },
  })
  host:subscribe("mouse.entered", function()
    if M.open_host ~= host then return end
    M.pointer_entry = nil
    M.host_inside = true
    M.popup_inside = false
    M.cancel_close()
  end)
  local function leave_host()
    if M.open_host ~= host then return end
    local was_inside = M.host_inside or M.popup_inside
    M.host_inside = false
    if current_entry(M.pointer_entry) then return end
    M.popup_inside = false
    if was_inside then M.schedule_close() end
  end
  host:subscribe("mouse.exited", leave_host)
  host:subscribe("mouse.exited.global", leave_host)
  host:subscribe("mouse.clicked", function(env)
    env = env or {}
    if env.BUTTON == "right" and options.right_click then
      if M.open_host then M.close() end
      options.right_click()
    elseif env.BUTTON == "other" and options.middle_click then
      if M.open_host then M.close() end
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

function M.debug_state()
  return {
    generation = M.generation,
    render_revision = M.render_revision,
    close_ticket = M.close_ticket,
    host_inside = M.host_inside,
    popup_inside = M.popup_inside,
    pointer_inside_row = not not current_entry(M.pointer_entry),
    render_hold = M.render_hold,
    dynamic_count = #M.dynamic,
  }
end

local watcher = sbar.add("item", "popup.controller", {
  drawing = false,
  updates = true,
  display = "active",
})
watcher:subscribe({ "display_change", "system_woke", "reload" }, function()
  M.close()
end)
watcher:subscribe("sketchybar_test_popup_exit", function()
  M.test_hold = false
  M.pointer_entry = nil
  M.host_inside = false
  M.popup_inside = false
  M.schedule_close()
end)

return M
