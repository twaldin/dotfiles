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
  position = "left",
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = {
    string = "󰖁", color = colors.muted, width = settings.control_width,
    align = "center", padding_left = 0, padding_right = 0,
    font = settings.type.bar_control,
  },
  label = { drawing = false, string = "Audio, state unavailable" },
  background = {
    drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0,
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

local function output_icon(level, muted, resolved)
  if not resolved then return "󰖁" end
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
    icon = { drawing = true, string = selected and "✓" or "", width = 24, color = selected and colors.green or state.busy and colors.muted or colors.blue, padding_left = 8, padding_right = 0 },
    label = { string = shell.ellipsis(label, 30), color = selected and colors.primary or colors.muted },
    background = { drawing = selected, color = colors.surface2 },
  })
  if not row then return row end
  if not state.busy then
    popup.action(row, { selected = selected, idle_color = selected and colors.primary or colors.muted, idle_icon_color = selected and colors.green or colors.blue })
    if not selected then popup.on_click(row, function(env)
      if left_click(env) and popup.is_current(item, token) then callback() end
    end) end
  end
  return row
end

build_rows = function(token)
  if not popup.is_current(item, token) then return end
  local device, direction = role_state(state, "output")
  local controls = audio.controls("output")
  local level = direction and percentage(direction.volume) or nil
  local mute = direction and direction.mute or nil
  local muted = boolean_value(mute)
  local heading = "SOUND OUTPUT"
  if level then heading = heading .. "  ·  " .. tostring(level) .. "%" end
  if muted == true then heading = heading .. "  ·  MUTED" end
  popup.row(item, token, "heading", { label = { string = heading, align = "center", color = colors.primary } })

  if state.busy then
    popup.row(item, token, "working", {
      label = { string = "WORKING  ·  " .. (state.pending_label or "Changing audio…"), color = colors.warning },
    })
  elseif action_error or state.error then
    popup.row(item, token, "error", {
      label = { string = action_error or state.error, color = colors.warning },
    })
  end

  if state.confirmed and type(state.warning_count) == "number" and state.warning_count > 0 then
    popup.note(item, token, "state_incomplete", "Some audio state could not be read", {
      color = colors.warning, max_chars = 40,
    })
  end

  if not state.busy and controls and direction and direction.volume.available
     and direction.volume.settable and level then
    popup.slider(item, token, "level", level, function(env)
      local value = tonumber(env and env.PERCENTAGE)
      if left_click(env) and value and value == value and value >= 0 and value <= 100 then
        invoke(function(done) return controls.set_volume(value, done) end)
      end
    end)
  else
    local reason = not state.confirmed and "Audio state is unavailable"
      or not direction and "Current sound output is unavailable"
      or not controls and "Audio controls are unavailable"
      or state.busy and "Level control is inactive while audio controls are busy"
      or "Level is controlled by the device"
    popup.row(item, token, "level_unavailable", {
      label = { string = reason, color = colors.muted },
    })
  end

  if controls and mute and mute.available and mute.settable
     and type(mute.value) == "boolean" then
    local target = not mute.value
    action_row(token, "mute", target and "Turn output mute on" or "Turn output mute off", false, function()
      invoke(function(done) return controls and controls.set_mute(target, done) or false end)
    end)
  else
    local reason = not state.confirmed and "Audio state is unavailable"
      or not direction and "Current sound output is unavailable"
      or not controls and "Audio controls are unavailable"
      or "Output mute is not supported by this device"
    popup.row(item, token, "mute_unavailable", {
      label = { string = reason, color = colors.muted },
    })
  end

  popup.section(item, token, "output_heading", "Output devices")
  local output_choices = audio.choices("output")
  if not state.confirmed then
    popup.row(item, token, "output_state_unavailable", {
      label = { string = "Audio state is unavailable", color = colors.muted },
    })
  elseif not state.defaults.output then
    popup.row(item, token, "output_default_unavailable", {
      label = { string = "Current sound output is unavailable", color = colors.muted },
    })
  elseif not state.actions_available then
    popup.row(item, token, "output_controls_unavailable", {
      label = { string = "Audio controls are unavailable", color = colors.muted },
    })
  elseif not audio.role_settable("output") then
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
    if type(choice.invoke) == "function" then
      action_row(token, "output_choice_" .. index,
        choice.name, selected, function()
          invoke(function(done) return captured.invoke(done) end)
        end)
    else
      popup.row(item, token, "output_choice_disabled_" .. index, {
        label = { string = shell.ellipsis("Disabled: " .. choice.reason .. " · " .. choice.name, 80), color = colors.muted },
      })
    end
  end

  popup.section(item, token, "alerts_heading", "System alerts")
  local alert_choices = audio.choices("system_output")
  if not state.confirmed then
    popup.row(item, token, "alerts_state_unavailable", {
      label = { string = "Audio state is unavailable", color = colors.muted },
    })
  elseif not state.defaults.system_output then
    popup.row(item, token, "alerts_default_unavailable", {
      label = { string = "Current system alert device is unavailable", color = colors.muted },
    })
  elseif not state.actions_available then
    popup.row(item, token, "alerts_controls_unavailable", {
      label = { string = "Audio controls are unavailable", color = colors.muted },
    })
  elseif not audio.role_settable("system_output") then
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
    if type(choice.invoke) == "function" then
      action_row(token, "alert_choice_" .. index,
        choice.name, selected, function()
          invoke(function(done) return captured.invoke(done) end)
        end)
    else
      popup.row(item, token, "alert_choice_disabled_" .. index, {
        label = { string = shell.ellipsis("Disabled: " .. choice.reason .. " · " .. choice.name, 80), color = colors.muted },
      })
    end
  end
  popup.section(item, token, "settings_heading", "Open")
  popup.link(item, token, "settings", "Open System Settings · select Sound", function()
    shell.open(settings.links.sound)
  end)
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
  align = "left",
  right_click = function()
    shell.open(settings.links.sound)
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
  local resolved = view.confirmed and direction ~= nil
  local idle_color = resolved and muted ~= nil
    and (muted and colors.muted or colors.primary) or colors.muted
  local active_color = hover.foreground(item, idle_color)
  item:set({
    width = settings.control_width,
    icon = { string = output_icon(level, muted, resolved), color = active_color },
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
    local resolved = state.confirmed and direction ~= nil
    return resolved and muted ~= nil
      and (muted and colors.muted or colors.primary) or colors.muted
  end,
})
audio.refresh()

return item
