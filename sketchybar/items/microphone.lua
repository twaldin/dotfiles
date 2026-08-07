local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local current = { level = 0, device = "—" }
local last_nonzero = 50
local refresh_generation = 0
local active = nil
local loop_in_flight = nil

local item = sbar.add("item", "microphone", {
  position = "right",
  drawing = true,
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  icon = { string = "󰍬", color = colors.muted, width = settings.icon_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 14.0 } },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 9 },
})

local function update_popup()
  if not active or not popup.is_current(item, active.token) then return end
  active.heading:set({ label = { string = string.format("INPUT  %d%%", current.level), color = colors.primary } })
  active.mute:set({ label = { string = current.level > 0 and "Mute input" or ("Restore input to " .. last_nonzero .. "%"), color = colors.muted } })
  active.level:set({ slider = { percentage = current.level } })
  active.device:set({ label = { string = "Current    " .. current.device, color = colors.muted } })
end

local function render()
  if current.level > 0 then last_nonzero = current.level end
  item:set({ width = settings.control_width, icon = { string = current.level > 0 and "󰍬" or "󰍭", color = current.level > 0 and colors.primary or colors.muted } })
  update_popup()
end

local function refresh(callback)
  refresh_generation = refresh_generation + 1
  local token = refresh_generation
  shell.exec({ settings.config_dir .. "/scripts/audio-state.sh", "input" }, function(output, exit_code)
    if token == refresh_generation then
      local level, device = output:match("^(%d+)\t([^\r\n]*)")
      if exit_code == 0 and level then
        current = { level = tonumber(level), device = shell.display(device ~= "" and device or "—") }
        render()
      end
    end
    if type(callback) == "function" then callback(exit_code) end
  end)
end

item:subscribe({ "routine", "system_woke" }, function() refresh() end)
hover.bind(item, { idle_color = function() return current.level > 0 and colors.primary or colors.muted end })

local function refresh_open(token)
  if loop_in_flight ~= nil or not active or active.token ~= token or not popup.is_current(item, token) then return end
  loop_in_flight = token
  refresh(function()
    if loop_in_flight ~= token then return end
    loop_in_flight = nil
    if active and active.token == token and popup.is_current(item, token) then
      sbar.delay(5, function() refresh_open(token) end)
    elseif active and popup.is_current(item, active.token) then
      local next_token = active.token
      sbar.delay(0.1, function() refresh_open(next_token) end)
    end
  end)
end

popup.bind(item, {
  align = "right",
  right_click = function() shell.open("x-apple.systempreferences:com.apple.Sound-Settings.extension") end,
  on_close = function() active = nil end,
  build = function(token)
    active = { token = token }
    active.heading = popup.row(item, token, "heading", {})
    active.mute = popup.row(item, token, "mute", {})
    active.level = popup.slider(item, token, "level", current.level, function(env)
      local level = math.max(0, math.min(100, tonumber(env.PERCENTAGE) or current.level))
      shell.exec({ "/usr/bin/osascript", "-e", "set volume input volume " .. tostring(math.floor(level + 0.5)) }, function() refresh() end)
    end)
    active.device = popup.row(item, token, "device", {})
    popup.action(active.mute, { idle_color = colors.muted })
    active.mute:subscribe("mouse.clicked", function()
      if popup.is_current(item, token) then
        local target = current.level > 0 and 0 or last_nonzero
        shell.exec({ "/usr/bin/osascript", "-e", "set volume input volume " .. tostring(target) }, function() refresh() end)
      end
    end)
    shell.exec({ settings.paths.switch_audio, "-t", "input", "-a" }, function(output, exit_code)
      if not active or active.token ~= token or not popup.is_current(item, token) or exit_code ~= 0 then return end
      for index, device in ipairs(shell.lines(output)) do
        local row = popup.row(item, token, "input" .. index, { label = { string = "○ " .. shell.display(device) } })
        if row then
          popup.action(row, { idle_color = colors.muted })
          row:subscribe("mouse.clicked", function()
          if popup.is_current(item, token) then
            shell.exec({ settings.paths.switch_audio, "-t", "input", "-s", device }, function() refresh() end)
            popup.close()
          end
        end)
        end
      end
    end)
    update_popup()
    refresh_open(token)
  end,
})
refresh()
return item
