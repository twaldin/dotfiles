local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local hover = require("lib.hover")
local popup = require("lib.popup")
local icons = require("lib.icons")
local spaces = {}
local selected = {}
local refresh_generation = 0
local windows_generation = 0
local apps_by_space = {}
local selected_space = nil
local focused_app = ""
local yabai_available = false
local availability_reason = "Checking Yabai query"
local refresh_apps

local function visible_apps(index)
  local result, seen = {}, {}
  for _, app in ipairs(apps_by_space[index] or {}) do
    result[#result + 1] = app
    seen[app:lower()] = true
  end
  if index == selected_space and focused_app ~= "" and icons.for_app(focused_app) and not seen[focused_app:lower()] then
    result[#result + 1] = focused_app
  end
  return result
end

local function render_apps(count)
  count = math.max(1, math.min(9, tonumber(count) or settings.space_count))
  local allocations = {}
  for index = 1, count do allocations[index] = 0 end
  local available = math.max(0, settings.spaces_width_limit - (24 + settings.spacing.item) * count)
  local remaining = math.floor(available / 20)

  -- Give the selected workspace enough context first, then distribute the
  -- remaining slots across the other workspaces. The old round-robin rule
  -- capped every workspace at one icon on the shipped nine-space layout.
  if selected_space and selected_space >= 1 and selected_space <= count then
    local selected_apps = visible_apps(selected_space)
    allocations[selected_space] = math.min(2, #selected_apps, remaining)
    remaining = remaining - allocations[selected_space]
  end
  local progress = true
  while remaining > 0 and progress do
    progress = false
    for index = 1, count do
      local apps = visible_apps(index)
      if remaining > 0 and allocations[index] < #apps then
        allocations[index] = allocations[index] + 1
        remaining = remaining - 1
        progress = true
      end
    end
  end

  for index, item in ipairs(spaces) do
    local apps = visible_apps(index)
    local ligatures = {}
    for app_index = 1, math.min(#apps, allocations[index] or 0) do
      ligatures[#ligatures + 1] = icons.for_app(apps[app_index])
    end
    local app_width = #ligatures * 20
    item:set({
      width = 24 + app_width,
      label = {
        string = table.concat(ligatures, " "),
        drawing = #ligatures > 0,
        width = app_width,
        color = colors.primary,
      },
    })
  end
end

local function configured_space_ids()
  local count = math.max(1, math.min(9, tonumber(settings.space_count) or 1))
  local ids = {}
  for index = 1, count do ids[index] = index end
  return ids
end

local function valid_space_id(value)
  return type(value) == "number" and value >= 1 and value <= 9
    and value == math.floor(value) and value or nil
end

local function apply_space_ids(ids)
  if type(ids) ~= "table" or #ids < 1 or #ids > 9 then ids = configured_space_ids() end
  settings.set_space_count(#ids)
  for index, item in ipairs(spaces) do
    item:set({ drawing = index <= #ids, associated_space = ids[index] or index })
  end
  render_apps(#ids)
end



local function render_availability(available)
  if available and spaces[1] and popup.is_open(spaces[1]) then popup.close() end
  if not available then
    for _, item in ipairs(spaces) do
      if hover.is_active(item) then hover.clear(); break end
    end
  end
  for index, item in ipairs(spaces) do
    item:set({
      icon = { color = available and (selected[index] and colors.accent or colors.muted)
        or colors.state.actionable },
      label = { color = colors.primary },
      background = { drawing = available and selected[index] == true },
    })
  end
end

local function refresh_availability()
  refresh_generation = refresh_generation + 1
  local token = refresh_generation
  shell.exec_quiet({ settings.paths.yabai, "-m", "query", "--spaces" }, function(yabai_spaces, yabai_exit)
    if token ~= refresh_generation then return end
    local failure_reason = "Yabai topology does not match"
    if yabai_exit ~= 0 then
      failure_reason = "Yabai query failed"
    elseif type(yabai_spaces) ~= "table" then
      failure_reason = "Yabai query response is invalid"
    elseif #yabai_spaces == 0 then
      failure_reason = "Yabai query returned no Spaces"
    end
    if yabai_exit == 0 and type(yabai_spaces) == "table" and #yabai_spaces > 0 then
      local ids, seen, valid = {}, {}, true
      for _, space in ipairs(yabai_spaces) do
        if type(space) == "table" and space.display == 1 then
          local id = valid_space_id(space.index)
          if not id or seen[id] or #ids >= 9 then valid = false; break end
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
      table.sort(ids)
      if valid and #ids == 9 then
        for index = 1, 9 do
          if ids[index] ~= index then valid = false; break end
        end
      else
        valid = false
      end
      if valid then
        yabai_available = true
        availability_reason = "Yabai query and topology are healthy"
        apply_space_ids(ids)
        render_availability(true)
        refresh_apps(token)
        return
      end
    end
    yabai_available = false
    availability_reason = failure_reason
    windows_generation = windows_generation + 1
    apps_by_space = {}
    selected_space = nil
    focused_app = ""
    apply_space_ids(configured_space_ids())
    render_availability(false)
  end)
end

refresh_apps = function(availability_token)
  windows_generation = windows_generation + 1
  local token = windows_generation
  shell.exec_quiet({ settings.config_dir .. "/scripts/yabai-windows.sh", "all" }, function(windows, exit_code)
    if token ~= windows_generation or availability_token ~= refresh_generation or not yabai_available then return end
    local next_apps = {}
    local next_selected_space = nil
    local next_focused_app = ""
    if exit_code == 0 and type(windows) == "table" then
      local seen = {}
      for _, window in ipairs(windows) do
        local index = tonumber(window.space)
        if window["has-focus"] == true then
          next_selected_space = index
          next_focused_app = type(window.app) == "string" and shell.display(window.app) or ""
        end
        local app = type(window.app) == "string" and shell.display(window.app) or ""
        local real_window = window.role == nil or window.role == "AXWindow"
        if real_window and index and index >= 1 and index <= 9 and app ~= "" and app:lower() ~= "superwhisper" and icons.for_app(app) then
          next_apps[index] = next_apps[index] or {}
          seen[index] = seen[index] or {}
          if not seen[index][app] then
            seen[index][app] = true
            next_apps[index][#next_apps[index] + 1] = app
          end
        end
      end
      for _, apps in pairs(next_apps) do table.sort(apps) end
    end
    apps_by_space = next_apps
    selected_space = next_selected_space
    focused_app = next_focused_app
    render_apps(settings.space_count)
  end)
end

local function refresh_all()
  refresh_availability()
end

local recovery_popup_options = {
  align = "left",
  idle_background = false,
  build = function(token)
    local host = spaces[1]
    popup.header(host, token, "SPACES", "YABAI UNAVAILABLE", { color = colors.state.actionable })
    popup.note(host, token, "reason", availability_reason, {
      align = "center", color = colors.state.actionable, max_chars = 48,
    })
    popup.section(host, token, "requirements_heading", "Required setup")
    popup.note(host, token, "version", "Signed Yabai app version: 7.1.25")
    popup.note(host, token, "path", "App path: $HOME/Applications/Yabai.app")
    popup.note(host, token, "topology", "Spaces: exactly 9 global indices 1–9")
    popup.note(host, token, "display", "Display: all nine Spaces on display 1")
    popup.section(host, token, "open_heading", "Open")
    popup.link(host, token, "setup_guide", "Open official Yabai setup guide", function()
      shell.open("https://github.com/asmvik/yabai/wiki/Installing-yabai-(latest-release)")
    end)
  end,
}

-- Standard left-position ordering keeps Space 1 at the outside edge.
for index = 1, 9 do
  local item = sbar.add("space", "space." .. index, {
    position = "left",
    associated_space = index,
    width = 24,
    padding_left = settings.spacing.item / 2,
    padding_right = settings.spacing.item / 2,
    icon = {
      string = tostring(index),
      color = colors.muted,
      highlight_color = colors.active,
      width = 24,
      align = "center",
      padding_left = 0,
      padding_right = 0,
      font = settings.type.bar_space,
    },
    label = {
      drawing = false,
      color = colors.normal,
      padding_left = 0,
      padding_right = 0,
      font = settings.type.bar_space_app,
    },
    background = { drawing = false, color = colors.surface, height = settings.surface_height, corner_radius = 0 },
    popup = index == 1 and {
      align = "left",
      topmost = true,
      blur_radius = 0,
      background = {
        color = colors.popup,
        border_width = 1,
        border_color = colors.border,
        corner_radius = 0,
      },
    } or nil,
  })
  spaces[index] = item
  item:set({ background = { drawing = false } })
  item:subscribe("space_change", function(env)
    selected[index] = env.SELECTED == true or env.SELECTED == "true"
    if selected[index] then selected_space = index; render_apps(settings.space_count) end
    local idle_color = not yabai_available and colors.state.actionable
      or selected[index] and colors.accent or colors.muted
    if hover.is_active(item) then
      item:set({ icon = { color = hover.foreground(item, idle_color) }, label = { color = colors.primary }, background = { color = colors.hover } })
      item:set({ background = { drawing = true } })
    else
      item:set({ icon = { color = idle_color }, label = { color = colors.primary }, background = { color = colors.surface } })
      item:set({ background = { drawing = yabai_available and selected[index] == true } })
    end
  end)
  hover.bind(item, {
    idle_background = function() return yabai_available and selected[index] == true end,
    idle_color = function()
      if not yabai_available then return colors.state.actionable end
      return selected[index] and colors.accent or colors.muted
    end,
    on_change = function(active)
      if active and not yabai_available then hover.clear() end
    end,
  })
  item:subscribe("mouse.clicked", function()
    if yabai_available then
      shell.exec({ settings.config_dir .. "/scripts/focus-space.sh", tostring(index) })
    else
      popup.open(spaces[1], recovery_popup_options)
      hover.set_popup_open(spaces[1], false)
    end
  end)
  item:subscribe("mouse.scrolled", function(env)
    if not yabai_available then return end
    local delta = tonumber(env.SCROLL_DELTA) or tonumber(env.DELTA) or 0
    if delta ~= 0 then
      shell.exec({ settings.config_dir .. "/scripts/focus-space.sh", delta > 0 and "prev" or "next" })
    end
  end)
end

local refresh_scheduled = false
local function schedule_refresh()
  if refresh_scheduled then return end
  refresh_scheduled = true
  sbar.delay(0.1, function()
    refresh_scheduled = false
    refresh_all()
  end)
end

local observer = spaces[1]
observer:subscribe({ "display_change", "system_woke", "space_windows_change", "routine" }, schedule_refresh)
observer:subscribe("front_app_switched", function()
  windows_generation = windows_generation + 1
  schedule_refresh()
end)
observer:set({ updates = true, update_freq = 15 })
refresh_all()

return {}
