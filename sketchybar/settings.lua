local M = {
  config_dir = assert(os.getenv("SKETCHYBAR_CONFIG_DIR")),
  font = "JetBrainsMono Nerd Font",
  app_font = "sketchybar-app-font",
  app_icon_map = os.getenv("HOME") .. "/.local/share/sketchybar-app-font/icon_map.lua",
  bar_height = 32,
  popup_width = 280,
  icon_width = 24,
  control_width = 28,
  calendar_show_titles = true,
  left_island_limit = 560,
  spaces_width_limit = 340,
  space_count = 9,
  paths = {
    blueutil = "/opt/homebrew/bin/blueutil",
    calendar_panel = os.getenv("HOME") .. "/.local/share/sketchybar-calendar/calendar-panel",
    icalbuddy = "/opt/homebrew/bin/icalBuddy",
    lua = "/opt/homebrew/bin/lua",
    media = "/opt/homebrew/bin/media-control",
    stats = "/opt/homebrew/bin/stats_provider",
    system_controls = os.getenv("HOME") .. "/.local/share/sketchybar-controls/system-controls",
    switch_audio = "/opt/homebrew/bin/SwitchAudioSource",
    yabai = "/opt/homebrew/bin/yabai",
  },
}

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

local q_layout_callbacks = {}
M.q_layout = { front = "full", media_text = false }
function M.on_q_layout(callback)
  q_layout_callbacks[#q_layout_callbacks + 1] = callback
  callback(M.q_layout)
end

function M.set_q_layout(front, media_text)
  if M.q_layout.front == front and M.q_layout.media_text == media_text then return end
  M.q_layout = { front = front, media_text = media_text }
  for _, callback in ipairs(q_layout_callbacks) do callback(M.q_layout) end
end

return M
