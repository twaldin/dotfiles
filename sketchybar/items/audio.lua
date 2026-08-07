local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local audio = require("lib.audio")

local state = audio.view()
local active = nil
local action_error = nil

local item = sbar.add("item", "audio", {
  position = "right",
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  icon = {
    string = "󰕾", color = colors.muted, width = settings.icon_width,
    align = "center", padding_left = 0, padding_right = 0,
    font = { family = settings.font, style = "Regular", size = 15.0 },
  },
  label = { drawing = false, string = "Audio, state unavailable" },
  background = {
    drawing = false, color = colors.surface2, height = 26, corner_radius = 9,
  },
})

local function left_click(env)
  return not env or env.BUTTON == nil or env.BUTTON == "left"
end

local function role_state(view, role)
  local reference = view.defaults and view.defaults[role]
  local device = reference and view.devices and view.devices[reference.ordinal] or nil
  if not device then return nil, nil end
  return device, role == "input" and device.input or device.output
end

local function percentage(capability)
  if not capability or not capability.available or type(capability.value) ~= "number" then return nil end
  return math.max(0, math.min(100, math.floor(capability.value + 0.5)))
end

local function boolean_value(capability)
  if capability and capability.available and type(capability.value) == "boolean" then
    return capability.value
  end
  return nil
end

local function output_icon(level, muted)
  if muted == true then return "󰝟" end
  if level == nil then return "󰕾" end
  if level <= 0 then return "󰝟" end
  if level < 34 then return "󰕿" end
  if level < 67 then return "󰖀" end
  return "󰕾"
end

local function output_summary(view)
  if not view.confirmed then return "Audio, state unavailable" end
  local device, direction = role_state(view, "output")
  if not device or not direction then return "Audio, output unavailable" end
  local level = percentage(direction.volume)
  local muted = boolean_value(direction.mute)
  local parts = { "Audio" }
  if level then parts[#parts + 1] = tostring(level) .. " percent" else parts[#parts + 1] = "level unavailable" end
  if muted == true then parts[#parts + 1] = "muted"
  elseif muted == false then parts[#parts + 1] = "not muted"
  else parts[#parts + 1] = "mute unavailable" end
  parts[#parts + 1] = device.name
  return table.concat(parts, ", ")
end

local build_rows

local function rebuild()
  if active and popup.is_current(item, active.token) then
    popup.rebuild(item, active.token, build_rows)
  end
end

local function invoke(invoker)
  action_error = nil
  local started = invoker(function(ok, reason)
    action_error = ok and nil or reason
    rebuild()
  end)
  if not started then rebuild() end
end

local function action_row(token, suffix, label, selected, callback)
  local row = popup.row(item, token, suffix, {
    label = { string = label, color = selected and colors.primary or colors.muted },
  })
  if not row or selected or state.busy then return row end
  popup.action(row, { selected = false, idle_color = colors.muted })
  row:subscribe("mouse.clicked", function(env)
    if left_click(env) and popup.is_current(item, token) then callback() end
  end)
  return row
end

build_rows = function(token)
  if not popup.is_current(item, token) then return end
  local device, direction = role_state(state, "output")
  local level = direction and percentage(direction.volume) or nil
  local mute = direction and direction.mute or nil
  local muted = boolean_value(mute)
  local heading = "SOUND OUTPUT"
  if level then heading = heading .. "  ·  " .. tostring(level) .. "%" end
  if muted == true then heading = heading .. "  ·  MUTED" end
  popup.row(item, token, "heading", { label = { string = heading, color = colors.primary } })

  if state.busy then
    popup.row(item, token, "working", {
      label = { string = "WORKING  ·  " .. (state.pending_label or "Changing audio…"), color = colors.warning },
    })
  elseif action_error or state.error then
    popup.row(item, token, "error", {
      label = { string = action_error or state.error, color = colors.warning },
    })
  end

  if direction and direction.volume.available and direction.volume.settable and level then
    popup.slider(item, token, "level", level, function(env)
      local value = tonumber(env and env.PERCENTAGE)
      if left_click(env) and value and value == value and value >= 0 and value <= 100 then
        invoke(function(done) return audio.set_volume("output", value, done) end)
      end
    end)
  else
    popup.row(item, token, "level_unavailable", {
      label = { string = "Level is controlled by the device", color = colors.muted },
    })
  end

  if mute and mute.available and mute.settable and type(mute.value) == "boolean" then
    local target = not mute.value
    action_row(token, "mute", target and "Turn output mute on" or "Turn output mute off", false, function()
      invoke(function(done) return audio.set_mute("output", target, done) end)
    end)
  else
    popup.row(item, token, "mute_unavailable", {
      label = { string = "Output mute is not supported by this device", color = colors.muted },
    })
  end

  popup.row(item, token, "output_heading", {
    label = { string = "SOUND OUTPUT DEVICES", color = colors.primary },
  })
  local output_choices = audio.choices("output")
  if not audio.role_settable("output") then
    popup.row(item, token, "output_unsettable", {
      label = { string = "Sound output switching is not supported", color = colors.muted },
    })
  elseif #output_choices == 0 then
    popup.row(item, token, "output_none", {
      label = { string = "No sound output devices available", color = colors.muted },
    })
  end
  for index, choice in ipairs(output_choices) do
    local selected = state.defaults.output and state.defaults.output.ordinal == choice.ordinal
    local captured = choice
    action_row(token, "output_choice_" .. index,
      "Use " .. choice.name .. " for sound output", selected, function()
        invoke(function(done) return captured.invoke(done) end)
      end)
  end

  popup.row(item, token, "alerts_heading", {
    label = { string = "SYSTEM ALERTS", color = colors.primary },
  })
  local alert_choices = audio.choices("system_output")
  if not audio.role_settable("system_output") then
    popup.row(item, token, "alerts_unsettable", {
      label = { string = "System alert switching is not supported", color = colors.muted },
    })
  elseif #alert_choices == 0 then
    popup.row(item, token, "alerts_none", {
      label = { string = "No system alert devices available", color = colors.muted },
    })
  end
  for index, choice in ipairs(alert_choices) do
    local selected = state.defaults.system_output and state.defaults.system_output.ordinal == choice.ordinal
    local captured = choice
    action_row(token, "alert_choice_" .. index,
      "Use " .. choice.name .. " for system alerts", selected, function()
        invoke(function(done) return captured.invoke(done) end)
      end)
  end
end

local function schedule_open_refresh(token)
  sbar.delay(5, function()
    if not active or active.token ~= token or not popup.is_current(item, token) then return end
    audio.refresh(function()
      if active and active.token == token and popup.is_current(item, token) then
        schedule_open_refresh(token)
      end
    end)
  end)
end

popup.bind(item, {
  align = "right",
  right_click = function()
    shell.open("x-apple.systempreferences:com.apple.Sound-Settings.extension")
  end,
  on_close = function() active = nil; action_error = nil end,
  build = function(token)
    active = { token = token }
    action_error = nil
    build_rows(token)
    audio.refresh()
    schedule_open_refresh(token)
  end,
})

local function render(view)
  state = view
  local _, direction = role_state(view, "output")
  local level = direction and percentage(direction.volume) or nil
  local muted = direction and boolean_value(direction.mute)
  local active_color = view.confirmed and (muted == true and colors.muted or colors.primary) or colors.muted
  item:set({
    width = settings.control_width,
    icon = { string = output_icon(level, muted), color = active_color },
    label = { string = output_summary(view), drawing = false },
  })
  rebuild()
end

audio.subscribe(render)
item:subscribe({ "routine", "system_woke", "volume_change" }, function() audio.refresh() end)
hover.bind(item, {
  idle_color = function()
    local _, direction = role_state(state, "output")
    local muted = direction and boolean_value(direction.mute)
    return state.confirmed and (muted == true and colors.muted or colors.primary) or colors.muted
  end,
})
audio.refresh()

return item
