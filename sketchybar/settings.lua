local M = {
  config_dir = assert(os.getenv("SKETCHYBAR_CONFIG_DIR")),
  font = "JetBrainsMono Nerd Font",
  app_font = "sketchybar-app-font",
  app_icon_map = os.getenv("HOME") .. "/.local/share/sketchybar-app-font/icon_map.lua",
  bar_height = 36,
  surface_height = 28,
  popup_width = 340,
  icon_width = 24,
  spacing = {
    item = 4, group = 4, segment = 4, edge = 8, icon_label = 2,
  },
  popup_layout = {
    gutter = 12, value_width = 96, column_gap = 8,
    heading_height = 34, section_height = 28, row_height = 30, axis_height = 18,
  },
  right_layout = {
    stat_width = 48, stat_count = 6,
    calendar_event_width = 188, calendar_date_width = 148,
    notch_reserve = 200, minimum_notched_width = 1512,
  },
  release_fingerprint = "8767c07aff9c158caa7a0e0f7ab1682f3c8026dab27e560b2262aafd928e1829",
  calendar_show_titles = true,
  left_layout = {
    -- 640 points plus the bar's 8-point edge padding equals the same
    -- 648-point notch-safe edge budget used by the right cluster.
    limit = 640, front_width = 100,
    control_width = 28, control_count = 5, battery_width = 58,
  },
  space_count = 9,
  links = {
    -- Public handoff: open the fixed main app and name the manual section.
    wifi = "/System/Applications/System Settings.app",
    network = "/System/Applications/System Settings.app",
    bluetooth = "/System/Applications/System Settings.app",
    sound = "/System/Applications/System Settings.app",
    displays = "/System/Applications/System Settings.app",
    battery = "/System/Applications/System Settings.app",
    storage = "/System/Applications/System Settings.app",
  },
  bundles = {
    activity_monitor = "com.apple.ActivityMonitor",
    calendar = "com.apple.iCal",
    disk_utility = "com.apple.DiskUtility",
    stats = "eu.exelban.Stats",
  },
  paths = {
    audio_state = assert(os.getenv("SKETCHYBAR_CONFIG_DIR")) .. "/scripts/audio-state.py",
    betterdisplay = "/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay",
    icalbuddy = "/opt/homebrew/bin/icalBuddy",
    lua = "/opt/homebrew/bin/lua",
    stats = os.getenv("HOME") .. "/.local/share/sketchybar-provider/sketchybar-public-stats",
    system_controls = os.getenv("HOME") .. "/.local/share/sketchybar-controls/system-controls",
    yabai = os.getenv("HOME") .. "/Applications/Yabai.app/Contents/MacOS/yabai",
  },
}

M.control_width = M.left_layout.control_width
M.battery_width = M.left_layout.battery_width
M.right_layout.calendar_limit = M.right_layout.calendar_event_width
  + M.right_layout.calendar_date_width

-- Keep every face proportional to the bar instead of maintaining unrelated
-- point sizes. macOS logical points already normalize Retina pixel density.
M.type_scale = M.bar_height / 32
local function face(family, style, base_size)
  local size = math.floor(base_size * M.type_scale * 2 + 0.5) / 2
  return { family = family, style = style, size = size }
end
M.type = {
  bar_icon = face(M.font, "Regular", 13.0),
  bar_value = face(M.font, "Medium", 10.5),
  bar_meta = face(M.font, "Regular", 10.0),
  bar_event = face(M.font, "SemiBold", 10.0),
  bar_event_detail = face(M.font, "Medium", 9.0),
  bar_control = face(M.font, "Regular", 14.0),
  bar_battery = face(M.font, "SemiBold", 10.0),
  bar_app = face(M.app_font, "Regular", 14.0),
  bar_space = face(M.font, "Bold", 11.0),
  bar_space_app = face(M.app_font, "Regular", 13.0),
  popup_head = face(M.font, "Bold", 11.0),
  popup_row = face(M.font, "Regular", 11.0),
  popup_section = face(M.font, "SemiBold", 9.5),
  popup_axis = face(M.font, "Medium", 9.0),
  popup_action_icon = face(M.font, "Regular", 13.0),
}

M.spaces_width_limit = M.left_layout.limit
  - M.left_layout.front_width - M.spacing.group
  - ((M.left_layout.control_width + M.spacing.item) * M.left_layout.control_count)
  - M.left_layout.battery_width - M.spacing.item

local overflow_callbacks = {}
function M.on_space_count(callback)
  overflow_callbacks[#overflow_callbacks + 1] = callback
  callback(M.space_count)
end

function M.set_space_count(count)
  count = math.max(1, math.min(9, tonumber(count) or 1))
  if count == M.space_count then return end
  M.space_count = count
  for _, callback in ipairs(overflow_callbacks) do callback(count) end
end

return M
