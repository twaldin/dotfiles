local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local current = { level = 0, muted = false, device = "—" }
local input = { level = 0, device = "—" }
local refresh_generation = 0
local active = nil
local input_in_flight = nil

local item = sbar.add("item", "audio", {
  position = "right",
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  icon = { string = "󰕾", color = colors.normal, width = settings.icon_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 15.0 } },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 9 },
})

local function icon(level, muted)
  if muted or level <= 0 then return "󰝟" end
  if level < 34 then return "󰕿" end
  if level < 67 then return "󰖀" end
  return "󰕾"
end

local function effective_level()
  return current.muted and 0 or current.level
end

local function update_output_popup()
  if not active or not popup.is_current(item, active.token) then return end
  local shown = effective_level()
  active.heading:set({ label = { string = current.muted and "OUTPUT  0%  ·  MUTED" or string.format("OUTPUT  %d%%", shown), color = colors.primary } })
  active.level:set({ slider = { percentage = shown } })
  active.mute:set({ label = { string = "Mute       " .. (current.muted and "on" or "off"), color = current.muted and colors.primary or colors.muted } })
  active.device:set({ label = { string = "Current    " .. current.device, color = colors.muted } })
end

local function render()
  item:set({
    width = settings.control_width,
    icon = { string = icon(current.level, current.muted), color = (current.muted or current.level == 0) and colors.muted or colors.primary },
  })
  update_output_popup()
end

local function refresh(callback)
  refresh_generation = refresh_generation + 1
  local token = refresh_generation
  shell.exec({ settings.config_dir .. "/scripts/audio-state.sh", "output" }, function(output, exit_code)
    if token == refresh_generation then
      local level, muted, device = output:match("^(%d+)\t([a-z]+)\t([^\r\n]*)")
      if exit_code == 0 and level then
        current = { level = tonumber(level), muted = muted == "true", device = shell.display(device ~= "" and device or "—") }
        render()
      end
    end
    if type(callback) == "function" then callback(exit_code) end
  end)
end

local function write_output(level)
  local rounded = math.max(0, math.min(100, math.floor((tonumber(level) or current.level) + 0.5)))
  if rounded == current.level then return end
  local mute_clause = current.muted and " with output muted" or " without output muted"
  shell.exec({ "/usr/bin/osascript", "-e", "set volume output volume " .. tostring(rounded) .. mute_clause }, function() refresh() end)
end

item:subscribe("volume_change", function(env)
  local level = tonumber(env.INFO)
  if level then current.level = math.max(0, math.min(100, level)); render() end
  refresh()
end)
item:subscribe({ "system_woke", "routine" }, function() refresh() end)
item:subscribe("mouse.scrolled", function(env)
  local delta = tonumber(env.SCROLL_DELTA) or tonumber(env.DELTA) or 0
  if delta ~= 0 then write_output(current.level + (delta > 0 and 2 or -2)) end
end)

hover.bind(item, { idle_color = function() return (current.muted or current.level == 0) and colors.muted or colors.primary end })

local function update_input_popup()
  if not active or not popup.is_current(item, active.token) or not active.input_heading then return end
  active.input_heading:set({ label = { string = string.format("MICROPHONE  %d%%", input.level), color = colors.primary } })
  active.input_level:set({ slider = { percentage = input.level } })
  active.input_device:set({ label = { string = "Current    " .. input.device, color = colors.muted } })
end

local function refresh_input(token)
  if input_in_flight ~= nil or not active or active.token ~= token or not popup.is_current(item, token) then return end
  input_in_flight = token
  shell.exec({ settings.config_dir .. "/scripts/audio-state.sh", "input" }, function(output, exit_code)
    if input_in_flight ~= token then return end
    input_in_flight = nil
    local level, device = output:match("^(%d+)	([^\r\n]*)")
    if exit_code == 0 and level then
      input = { level = tonumber(level), device = shell.display(device ~= "" and device or "—") }
      update_input_popup()
    end
    if active and active.token == token and popup.is_current(item, token) then
      sbar.delay(5, function() refresh_input(token) end)
    elseif active and popup.is_current(item, active.token) then
      local next_token = active.token
      sbar.delay(0.1, function() refresh_input(next_token) end)
    end
  end)
end

popup.bind(item, {
  align = "right",
  right_click = function() shell.open("x-apple.systempreferences:com.apple.Sound-Settings.extension") end,
  on_close = function() active = nil end,
  build = function(token)
    active = { token = token }
    active.heading = popup.row(item, token, "heading", { label = { string = "OUTPUT", color = colors.primary } })
    active.level = popup.slider(item, token, "level", effective_level(), function(env) write_output(env.PERCENTAGE) end)
    active.mute = popup.row(item, token, "mute", { label = { string = "Mute       …", color = colors.muted } })
    popup.action(active.mute, { idle_color = function() return current.muted and colors.primary or colors.muted end })
    active.mute:subscribe("mouse.clicked", function()
      if popup.is_current(item, token) then
        shell.exec({ "/usr/bin/osascript", "-e", current.muted and "set volume without output muted" or "set volume with output muted" }, function() refresh() end)
      end
    end)
    active.device = popup.row(item, token, "device", { label = { string = "Current    " .. current.device, color = colors.muted } })
    shell.exec({ settings.paths.switch_audio, "-t", "output", "-a" }, function(output, exit_code)
      if not active or active.token ~= token or not popup.is_current(item, token) or exit_code ~= 0 then return end
      for index, device in ipairs(shell.lines(output)) do
        local row = popup.row(item, token, "output" .. index, { label = { string = "○ " .. shell.display(device) } })
        if row then
          popup.action(row, { idle_color = colors.muted })
          row:subscribe("mouse.clicked", function()
          if popup.is_current(item, token) then
            shell.exec({ settings.paths.switch_audio, "-t", "output", "-s", device }, function() refresh() end)
            popup.close()
          end
        end)
        end
      end
      if not active or active.token ~= token or not popup.is_current(item, token) then return end
      active.input_heading = popup.row(item, token, "input_heading", { label = { string = "MICROPHONE", color = colors.primary } })
      active.input_level = popup.slider(item, token, "input_level", input.level, function(env)
        local level = math.max(0, math.min(100, tonumber(env.PERCENTAGE) or input.level))
        shell.exec({ "/usr/bin/osascript", "-e", "set volume input volume " .. tostring(math.floor(level + 0.5)) }, function() refresh_input(token) end)
      end)
      active.input_device = popup.row(item, token, "input_device", { label = { string = "Current    " .. input.device, color = colors.muted } })
      shell.exec({ settings.paths.switch_audio, "-t", "input", "-a" }, function(devices, device_exit)
        if not active or active.token ~= token or not popup.is_current(item, token) or device_exit ~= 0 then return end
        for index, device in ipairs(shell.lines(devices)) do
          local row = popup.row(item, token, "input" .. index, { label = { string = "○ " .. shell.display(device) } })
          if row then
          popup.action(row, { idle_color = colors.muted })
          row:subscribe("mouse.clicked", function()
            if popup.is_current(item, token) then
              shell.exec({ settings.paths.switch_audio, "-t", "input", "-s", device })
              popup.close()
            end
          end)
          end
        end
      end)
      update_input_popup()
      refresh_input(token)
    end)
    update_output_popup()
    refresh()
  end,
})

refresh()
return item
