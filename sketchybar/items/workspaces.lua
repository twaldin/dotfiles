local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local hover = require("lib.hover")
local icons = require("lib.icons")
local spaces = {}
local selected = {}
local refresh_generation = 0
local windows_generation = 0
local apps_by_space = {}
local selected_space = nil
local focused_app = ""
local yabai_available = false
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
  settings.set_q_layout("full", false)
  local allocations = {}
  for index = 1, count do allocations[index] = 0 end
  local available = math.max(0, settings.spaces_width_limit - 24 * count)
  local remaining = math.floor(available / 20)
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
  value = tonumber(value)
  return value and value >= 1 and value <= 9 and value == math.floor(value) and value or nil
end

local function apply_space_ids(ids)
  if type(ids) ~= "table" or #ids < 1 or #ids > 9 then ids = configured_space_ids() end
  settings.set_space_count(#ids)
  for index, item in ipairs(spaces) do
    item:set({ drawing = index <= #ids, associated_space = ids[index] or index })
  end
  render_apps(#ids)
end



local function refresh_availability()
  refresh_generation = refresh_generation + 1
  local token = refresh_generation
  shell.exec_quiet({ settings.paths.yabai, "-m", "query", "--spaces" }, function(yabai_spaces, yabai_exit)
    if token ~= refresh_generation then return end
    if yabai_exit == 0 and type(yabai_spaces) == "table" and #yabai_spaces > 0 then
      local ids, seen, valid = {}, {}, true
      for _, space in ipairs(yabai_spaces) do
        if type(space) == "table" and tonumber(space.display) == 1 then
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
        apply_space_ids(ids)
        refresh_apps(token)
        return
      end
    end
    yabai_available = false
    windows_generation = windows_generation + 1
    apps_by_space = {}
    selected_space = nil
    focused_app = ""
    apply_space_ids(configured_space_ids())
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
        if index and index >= 1 and index <= 9 and app ~= "" and app:lower() ~= "superwhisper" and icons.for_app(app) then
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

-- Standard left-position ordering keeps Space 1 at the outside edge.
for index = 1, 9 do
  local item = sbar.add("space", "space." .. index, {
    position = "left",
    associated_space = index,
    width = 24,
    padding_left = 0,
    padding_right = 0,
    icon = {
      string = tostring(index),
      color = colors.muted,
      highlight_color = colors.active,
      width = 24,
      align = "center",
      padding_left = 0,
      padding_right = 0,
      font = { family = settings.font, style = "Bold", size = 11.0 },
    },
    label = {
      drawing = false,
      color = colors.normal,
      padding_left = 0,
      padding_right = 0,
      font = { family = settings.app_font, style = "Regular", size = 13.0 },
    },
    background = { drawing = false, color = colors.surface, height = 26, corner_radius = 0 },
  })
  spaces[index] = item
  item:set({ background = { drawing = false } })
  item:subscribe("space_change", function(env)
    selected[index] = env.SELECTED == true or env.SELECTED == "true"
    if selected[index] then selected_space = index; render_apps(settings.space_count) end
    if hover.is_active(item) then
      item:set({ icon = { color = colors.primary }, label = { color = colors.primary }, background = { color = colors.hover } })
      item:set({ background = { drawing = true } })
    else
      item:set({ icon = { color = selected[index] and colors.accent or colors.muted }, label = { color = colors.primary }, background = { color = colors.surface } })
      item:set({ background = { drawing = selected[index] } })
    end
  end)
  hover.bind(item, {
    idle_background = function() return selected[index] == true end,
    idle_color = function() return selected[index] and colors.accent or colors.muted end,
  })
  item:subscribe("mouse.clicked", function()
    if yabai_available then shell.exec({ settings.config_dir .. "/scripts/focus-space.sh", tostring(index) }) end
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
observer:set({ updates = true, update_freq = 5 })
refresh_all()

return {}
