local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local audio = require("lib.audio")

local state = audio.view()
local active = nil
local action_error = nil

local item = sbar.add("item", "microphone", {
  position = "left",
  drawing = true,
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = {
    string = "󰍮", color = colors.muted, width = settings.control_width,
    align = "center", padding_left = 0, padding_right = 0,
    font = settings.type.bar_control,
  },
  label = { drawing = false, string = "Microphone, state unavailable" },
  background = {
    drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0,
  },
})

local function left_click(env)
  return not env or env.BUTTON == nil or env.BUTTON == "left"
end

local function input_state(view)
  local reference = view.defaults and view.defaults.input
  local device = reference and view.devices and view.devices[reference.ordinal] or nil
  return device, device and device.input or nil
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

local function semantic_label(view)
  if not view.confirmed then return "Microphone, state unavailable" end
  local device, direction = input_state(view)
  if not device or not direction then return "Microphone, input unavailable" end
  local level = percentage(direction.volume)
  local mute = direction.mute
  local parts = { "Microphone" }
  if level then parts[#parts + 1] = tostring(level) .. " percent" else parts[#parts + 1] = "level unavailable" end
  if mute and mute.available and mute.value == true then parts[#parts + 1] = "muted"
  elseif mute and mute.available and mute.value == false then parts[#parts + 1] = "not muted"
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
    icon = { drawing = true, string = selected and "✓" or "", width = 24, color = selected and colors.green or colors.blue, padding_left = 8, padding_right = 0 },
    label = { string = shell.ellipsis(label, 30), color = selected and colors.primary or colors.muted },
    background = { drawing = selected, color = colors.surface2 },
  })
  if not row then return row end
  popup.action(row, { selected = selected, idle_color = selected and colors.primary or colors.muted, idle_icon_color = selected and colors.green or colors.blue })
  if not selected and not state.busy then popup.on_click(row, function(env)
    if left_click(env) and popup.is_current(item, token) then callback() end
  end) end
  return row
end

build_rows = function(token)
  if not popup.is_current(item, token) then return end
  local _, direction = input_state(state)
  local controls = audio.controls("input")
  local level = direction and percentage(direction.volume) or nil
  local mute = direction and direction.mute or nil
  local heading = "MICROPHONE"
  if level then heading = heading .. "  ·  " .. tostring(level) .. "%" end
  if mute and mute.available and mute.value == true then heading = heading .. "  ·  MUTED" end
  popup.row(item, token, "heading", { label = { string = heading, align = "center", color = colors.primary } })

  if state.busy then
    popup.row(item, token, "working", {
      label = { string = "WORKING  ·  " .. (state.pending_label or "Changing microphone…"), color = colors.warning },
    })
  elseif action_error or state.error then
    popup.row(item, token, "error", {
      label = { string = action_error or state.error, color = colors.warning },
    })
  end

  if controls and direction and direction.volume.available
     and direction.volume.settable and level then
    popup.slider(item, token, "level", level, function(env)
      local value = tonumber(env and env.PERCENTAGE)
      if left_click(env) and value and value == value and value >= 0 and value <= 100 then
        invoke(function(done) return controls.set_volume(value, done) end)
      end
    end)
  else
    local reason = not state.confirmed and "Microphone state is unavailable"
      or not direction and "Current microphone is unavailable"
      or not controls and "Microphone controls are unavailable"
      or "Level is controlled by the device"
    popup.row(item, token, "level_unavailable", {
      label = { string = reason, color = colors.muted },
    })
  end

  if controls and mute and mute.available and mute.settable
     and type(mute.value) == "boolean" then
    local target = not mute.value
    action_row(token, "mute", target and "Turn microphone mute on" or "Turn microphone mute off", false, function()
      invoke(function(done) return controls and controls.set_mute(target, done) or false end)
    end)
  else
    local reason = not state.confirmed and "Microphone state is unavailable"
      or not direction and "Current microphone is unavailable"
      or not controls and "Microphone controls are unavailable"
      or "Microphone mute is not supported by this device"
    popup.row(item, token, "mute_unavailable", {
      label = { string = reason, color = colors.muted },
    })
  end

  popup.section(item, token, "input_heading", "Input devices")
  local choices = audio.choices("input")
  if not state.confirmed then
    popup.row(item, token, "input_state_unavailable", {
      label = { string = "Microphone state is unavailable", color = colors.muted },
    })
  elseif not state.defaults.input then
    popup.row(item, token, "input_default_unavailable", {
      label = { string = "Current microphone is unavailable", color = colors.muted },
    })
  elseif not state.actions_available then
    popup.row(item, token, "input_controls_unavailable", {
      label = { string = "Microphone controls are unavailable", color = colors.muted },
    })
  elseif not audio.role_settable("input") then
    popup.row(item, token, "input_unsettable", {
      label = { string = "Microphone switching is not supported", color = colors.muted },
    })
  elseif #choices == 0 then
    popup.row(item, token, "input_none", {
      label = { string = "No microphone devices available", color = colors.muted },
    })
  end
  for index, choice in ipairs(choices) do
    local selected = state.defaults.input and state.defaults.input.ordinal == choice.ordinal
    local captured = choice
    if type(choice.invoke) == "function" then
      action_row(token, "input_choice_" .. index,
        choice.name, selected, function()
          invoke(function(done) return captured.invoke(done) end)
        end)
    else
      popup.row(item, token, "input_choice_disabled_" .. index, {
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
  local _, direction = input_state(view)
  local mute = direction and direction.mute or nil
  local muted = boolean_value(mute)
  local resolved = view.confirmed and direction ~= nil and muted ~= nil
  item:set({
    width = settings.control_width,
    icon = {
      string = not resolved and "󰍮" or muted and "󰍭" or "󰍬",
      color = hover.foreground(item,
        resolved and (muted and colors.muted or colors.primary) or colors.muted),
    },
    label = { string = semantic_label(view), drawing = false },
  })
  rebuild()
end

audio.subscribe(render)
item:subscribe({ "routine", "system_woke" }, function() audio.refresh() end)
hover.bind(item, {
  idle_color = function()
    local _, direction = input_state(state)
    local mute = direction and direction.mute or nil
    local muted = boolean_value(mute)
    local resolved = state.confirmed and direction ~= nil and muted ~= nil
    return resolved and (muted and colors.muted or colors.primary) or colors.muted
  end,
})
audio.refresh()

return item
