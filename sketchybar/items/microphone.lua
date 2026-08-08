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
  position = "right",
  drawing = true,
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  icon = {
    string = "󰍬", color = colors.muted, width = settings.control_width,
    align = "center", padding_left = 0, padding_right = 0,
    font = { family = settings.font, style = "Regular", size = 14.0 },
  },
  label = { drawing = false, string = "Microphone, state unavailable" },
  background = {
    drawing = false, color = colors.surface2, height = 26, corner_radius = 0,
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
    label = { string = label, color = selected and colors.primary or colors.muted },
  })
  if not row or selected or state.busy then return row end
  popup.action(row, { selected = false, idle_color = colors.muted })
  popup.on_click(row, function(env)
    if left_click(env) and popup.is_current(item, token) then callback() end
  end)
  return row
end

build_rows = function(token)
  if not popup.is_current(item, token) then return end
  local _, direction = input_state(state)
  local level = direction and percentage(direction.volume) or nil
  local mute = direction and direction.mute or nil
  local heading = "MICROPHONE"
  if level then heading = heading .. "  ·  " .. tostring(level) .. "%" end
  if mute and mute.available and mute.value == true then heading = heading .. "  ·  MUTED" end
  popup.row(item, token, "heading", { label = { string = heading, color = colors.primary } })

  if state.busy then
    popup.row(item, token, "working", {
      label = { string = "WORKING  ·  " .. (state.pending_label or "Changing microphone…"), color = colors.warning },
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
        invoke(function(done) return audio.set_volume("input", value, done) end)
      end
    end)
  else
    popup.row(item, token, "level_unavailable", {
      label = { string = "Level is controlled by the device", color = colors.muted },
    })
  end

  if mute and mute.available and mute.settable and type(mute.value) == "boolean" then
    local target = not mute.value
    action_row(token, "mute", target and "Turn microphone mute on" or "Turn microphone mute off", false, function()
      invoke(function(done) return audio.set_mute("input", target, done) end)
    end)
  else
    popup.row(item, token, "mute_unavailable", {
      label = { string = "Microphone mute is not supported by this device", color = colors.muted },
    })
  end

  popup.row(item, token, "input_heading", {
    label = { string = "MICROPHONE DEVICES", color = colors.primary },
  })
  local choices = audio.choices("input")
  if not audio.role_settable("input") then
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
    action_row(token, "input_choice_" .. index,
      "Use " .. choice.name .. " as microphone", selected, function()
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
  local _, direction = input_state(view)
  local mute = direction and direction.mute or nil
  local muted = boolean_value(mute)
  item:set({
    width = settings.control_width,
    icon = {
      string = muted == true and "󰍭" or "󰍬",
      color = hover.foreground(item,
        view.confirmed and muted ~= nil and (muted and colors.muted or colors.primary) or colors.muted),
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
    return state.confirmed and muted ~= nil and (muted and colors.muted or colors.primary) or colors.muted
  end,
})
audio.refresh()

return item
