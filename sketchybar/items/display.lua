local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")

local state = nil
local token = nil
local read_in_flight = false
local read_invalidated = false
local refresh_pending = false
local busy = false
local action_error = nil
local pending_label = nil
local popup_confirmation_pending = false
local read_generation = 0
local CONFIRMATION_TIMEOUT_SECONDS = 15
local rebuild
local refresh

local item = sbar.add("item", "display", {
  position = "left", drawing = true, updates = true,
  width = settings.control_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = {
    string = "󰍹", color = colors.muted, width = settings.control_width,
    align = "center", padding_left = 0, padding_right = 0,
    font = settings.type.bar_control,
  },
  label = { drawing = false, string = "Display state unavailable" },
  background = { drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0 },
})

local function helper(arguments, callback)
  local argv = { settings.config_dir .. "/scripts/display-state.py" }
  for _, value in ipairs(arguments) do argv[#argv + 1] = value end
  shell.exec(argv, callback)
end

local function finite_number(value, minimum, maximum, integer)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
  if value < minimum or value > maximum or (integer and value ~= math.floor(value)) then return nil end
  return value
end

local VARIABLE_REFRESH_RATES = { ProMotion = true, Variable = true, Adaptive = true }

local function refresh_decimal(value)
  if type(value) ~= "string"
     or not (value:match("^[0-9]+$") or value:match("^[0-9]+%.[0-9]$")
       or value:match("^[0-9]+%.[0-9][0-9]$")) then return nil end
  return finite_number(tonumber(value), 1, 1000, false)
end

local function refresh_value(value)
  local numeric = finite_number(value, 1, 1000, false)
  if numeric then return numeric end
  if type(value) ~= "string" then return nil end
  if VARIABLE_REFRESH_RATES[value] then return value end
  local low_text, high_text = value:match("^([0-9]+%.?[0-9]*)%-([0-9]+%.?[0-9]*)Hz$")
  local low, high = refresh_decimal(low_text), refresh_decimal(high_text)
  if not low or not high or low >= high then return nil end
  return value
end

local function valid_handle(value)
  if type(value) ~= "string" or #value ~= 100 then return false end
  local nonce, digest = value:match("^v1_([0-9a-f]+)_([0-9a-f]+)$")
  return nonce ~= nil and #nonce == 32 and #digest == 64
end

local STATE_KEYS = {
  schema = true, ok = true, brightness = true, volume = true, contrast = true,
  mute = true, resolution = true, refresh_rate = true, hi_dpi = true, main = true,
  color_depth = true, mode_number = true, modes = true,
  target_handle = true, controls = true, status = true,
}
local MODE_KEYS = {
  number = true, resolution = true, width = true, height = true, hi_dpi = true,
  refresh_rate = true, color_depth = true, current = true, default = true, native = true,
}
local CONTROL_KEYS = { brightness = true, hardware_contrast = true, volume = true, mute = true }

local function allowed_keys(value, allowed)
  for key in pairs(value) do if not allowed[key] then return false end end
  return true
end

local function dense_array(value, maximum)
  if type(value) ~= "table" then return false end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key ~= math.floor(key) or key < 1 then return false end
    count = count + 1
  end
  return count == #value and count <= maximum
end

local function sanitize_mode(value)
  if type(value) ~= "table" or not allowed_keys(value, MODE_KEYS) then return nil end
  local number = finite_number(value.number, 0, 4096, true)
  local width = finite_number(value.width, 320, 32768, true)
  local height = finite_number(value.height, 200, 32768, true)
  local refresh = refresh_value(value.refresh_rate)
  local depth = finite_number(value.color_depth, 1, 64, true)
  if not number or not width or not height or not refresh or not depth
     or type(value.resolution) ~= "string" or #value.resolution > 11
     or value.resolution ~= tostring(width) .. "x" .. tostring(height)
     or type(value.hi_dpi) ~= "boolean" or type(value.current) ~= "boolean"
     or type(value.default) ~= "boolean" or type(value.native) ~= "boolean" then return nil end
  return {
    number = number, resolution = value.resolution, width = width, height = height,
    hi_dpi = value.hi_dpi, refresh_rate = refresh, color_depth = depth,
    current = value.current, default = value.default, native = value.native,
  }
end

local function sanitize_state(value, require_applied)
  if type(value) ~= "table" or not allowed_keys(value, STATE_KEYS)
     or value.schema ~= 3 or value.ok ~= true then return nil end
  if require_applied then
    if value.status ~= "applied" then return nil end
  elseif value.status ~= nil then
    return nil
  end
  local brightness = finite_number(value.brightness, 0, 100, true)
  local refresh = refresh_value(value.refresh_rate)
  local mode_number = finite_number(value.mode_number, 0, 4096, true)
  local resolution_width, resolution_height
  if type(value.resolution) == "string" then
    resolution_width, resolution_height = value.resolution:match("^([0-9]+)x([0-9]+)$")
    resolution_width, resolution_height = tonumber(resolution_width), tonumber(resolution_height)
  end
  if not brightness or not refresh or not mode_number
     or type(value.resolution) ~= "string" or #value.resolution > 11
     or not finite_number(resolution_width, 320, 32768, true)
     or not finite_number(resolution_height, 200, 32768, true)
     or not dense_array(value.modes, 10) then return nil end
  local contrast = value.contrast == nil and nil or finite_number(value.contrast, 0, 100, true)
  local volume = value.volume == nil and nil or finite_number(value.volume, 0, 100, true)
  local depth = value.color_depth == nil and nil or finite_number(value.color_depth, 1, 64, true)
  if value.contrast ~= nil and contrast == nil or value.volume ~= nil and volume == nil
     or value.color_depth ~= nil and depth == nil then return nil end
  if value.mute ~= nil and type(value.mute) ~= "boolean" then return nil end
  if value.hi_dpi ~= nil and type(value.hi_dpi) ~= "boolean" then return nil end
  if value.main ~= nil and type(value.main) ~= "boolean" then return nil end
  local modes = {}
  for index, raw in ipairs(value.modes) do
    local mode = sanitize_mode(raw)
    if not mode then return nil end
    modes[index] = mode
  end
  local handle = value.target_handle
  local controls = value.controls
  if handle ~= nil or controls ~= nil then
    if not valid_handle(handle) or type(controls) ~= "table" or not allowed_keys(controls, CONTROL_KEYS) then return nil end
    for key in pairs(CONTROL_KEYS) do if type(controls[key]) ~= "boolean" then return nil end end
  end
  return {
    schema = 3, ok = true, brightness = brightness, volume = volume, contrast = contrast,
    mute = value.mute, resolution = value.resolution, refresh_rate = refresh,
    hi_dpi = value.hi_dpi, main = value.main, color_depth = depth,
    mode_number = mode_number, modes = modes,
    target_handle = handle, controls = controls, status = value.status,
  }
end

local FIXED_ERRORS = {
  artifact_rejected = "The display control helper rejected the installed BetterDisplay app.",
  conflict = "Display state changed before the action. Try again.",
  control_unavailable = "Display controls are unavailable.",
  invalid_request = "The display action was rejected.",
  native_invalid = "The display control response was invalid.",
  out_of_range = "The display rejected that value.",
  post_write_unavailable = "The change applied, but refreshed display state was not confirmed.",
  recovery_failed = "The change failed and display recovery was not confirmed.",
  restored = "The change failed. The prior display value was restored.",
  unavailable = "BetterDisplay did not confirm the display action.",
}

local function action_status(output)
  if type(output) ~= "table" or output.schema ~= 3 or output.ok ~= false
     or type(output.status) ~= "string" then return nil end
  local count = 0
  for key in pairs(output) do
    if key ~= "schema" and key ~= "ok" and key ~= "status" then return nil end
    count = count + 1
  end
  if count ~= 3 or not FIXED_ERRORS[output.status] then return nil end
  return output.status
end

local function percent(value)
  value = tonumber(value)
  return value and string.format("%.0f%%", value) or "—"
end

local function normalized_percent(value)
  value = finite_number(value, 0, 100, false)
  if not value then return nil end
  local text = string.format("%.6f", value / 100):gsub("0+$", ""):gsub("%.$", "")
  return text == "" and "0" or text
end

local function rate(value)
  value = refresh_value(value)
  if type(value) == "string" then return value end
  if not value then return "—" end
  return string.format(value == math.floor(value) and "%.0f Hz" or "%.2f Hz", value)
end

local function mode_identity(mode, role)
  if type(mode) ~= "table" then return role .. " · —" end
  return role .. " · " .. tostring(mode.resolution or "—"):gsub("x", "×")
    .. (mode.hi_dpi and " · HiDPI" or "")
end

local function left_click(env)
  return not env or env.BUTTON == nil or env.BUTTON == "left"
end

local function control_ready(operation, value, value_type)
  return not busy and state and valid_handle(state.target_handle)
    and type(state.controls) == "table" and state.controls[operation] == true
    and type(value) == value_type
end

local function start_action(operation, expected, desired, handle, label)
  if busy or not state or state.target_handle ~= handle or not valid_handle(handle) then return false end
  if read_in_flight then
    read_invalidated = true
    refresh_pending = true
  end
  local expected_text, desired_text
  if operation == "mute" then
    if type(expected) ~= "boolean" or type(desired) ~= "boolean" then return false end
    expected_text, desired_text = expected and "on" or "off", desired and "on" or "off"
  else
    expected_text, desired_text = normalized_percent(expected), normalized_percent(desired)
    if not expected_text or not desired_text then return false end
  end
  busy = true
  pending_label = label
  action_error = nil
  rebuild()
  helper({ "action", operation, expected_text, desired_text, handle }, function(output, code)
    busy = false
    pending_label = nil
    local refreshed = code == 0 and sanitize_state(output, true) or nil
    if refreshed then
      state = refreshed
      action_error = nil
      rebuild()
      local available = state ~= nil
      item:set({
        icon = { color = hover.foreground(item, available and colors.domain.display or colors.muted) },
        label = { string = available and "Display confirmed" or "Display state unavailable" },
      })
      if refresh_pending then refresh() end
      return
    end
    local status = action_status(output)
    action_error = FIXED_ERRORS[status] or "Display controls did not return a valid result."
    rebuild()
    refresh()
  end)
  return true
end

local function numeric_slider(token_value, suffix, operation, value, color, label)
  local captured_expected, captured_handle = value, state.target_handle
  popup.slider(item, token_value, suffix, value, function(env)
    local desired = tonumber(env and env.PERCENTAGE)
    if left_click(env) and finite_number(desired, 0, 100, false) then
      start_action(operation, captured_expected, desired, captured_handle, label)
    end
  end, { color = color })
end

local function mute_action(token_value)
  local current, handle = state.mute, state.target_handle
  local desired = not current
  local label = desired and "Turn display mute on" or "Turn display mute off"
  local row = popup.row(item, token_value, "mute_action", {
    icon = { drawing = true, string = desired and "󰝟" or "󰕾", width = 24,
      color = colors.cyan, padding_left = 8, padding_right = 0 },
    label = { string = label, color = colors.primary },
  })
  if not row then return end
  popup.action(row, { idle_color = colors.primary, idle_icon_color = colors.cyan })
  popup.on_click(row, function(env)
    if left_click(env) and popup.is_current(item, token_value) then
      start_action("mute", current, desired, handle, label)
    end
  end)
end

local function build(token_value)
  if not popup.is_current(item, token_value) then return end
  popup.header(item, token_value, "DISPLAY",
    popup_confirmation_pending and "—" or (state and state.resolution or "—"))
  if popup_confirmation_pending then
    popup.note(item, token_value, "confirming_target",
      "Confirming the display under the pointer…", { align = "center", color = colors.warning })
    for index = 1, 11 do
      popup.note(item, token_value, "confirming_space_" .. index, " ", { color = colors.transparent })
    end
  elseif not state then
    popup.note(item, token_value, "unavailable", "BetterDisplay state unavailable", { align = "center", color = colors.state.actionable })
  else
    if busy then
      popup.note(item, token_value, "working", "WORKING  ·  " .. (pending_label or "Changing display…"), { color = colors.warning })
    elseif action_error then
      popup.note(item, token_value, "action_error", action_error, { color = colors.warning, max_chars = 72 })
    end

    popup.section(item, token_value, "brightness_heading", "Brightness")
    popup.field(item, token_value, "brightness_value", "Brightness", percent(state.brightness))
    if control_ready("brightness", state.brightness, "number") then
      numeric_slider(token_value, "brightness_slider", "brightness", state.brightness, colors.domain.display, "Changing brightness…")
    else
      popup.note(item, token_value, "brightness_inactive",
        busy and "Brightness control is inactive while an action is busy"
          or "Brightness control is unavailable",
        { color = colors.muted })
    end

    popup.section(item, token_value, "screen_heading", "Screen")
    popup.field(item, token_value, "resolution", "Resolution", tostring(state.resolution or "—"))
    popup.field(item, token_value, "refresh", "Refresh rate", rate(state.refresh_rate))
    popup.field(item, token_value, "color_depth", "Color depth", state.color_depth and (tostring(state.color_depth) .. " bpc") or "—")
    popup.field(item, token_value, "quality", "High Resolution", state.hi_dpi == true and "On" or state.hi_dpi == false and "Off" or "—")
    popup.field(item, token_value, "main", "Role", state.main == true and "Main display" or state.main == false and "Extended display" or "—")

    local modes = state.modes or {}
    if #modes > 0 then
      popup.section(item, token_value, "modes_heading", "Useful modes · read only")
      local rendered = 0
      for _, mode in ipairs(modes) do
        if mode.current or mode.default or mode.native then
          rendered = rendered + 1
          local role = mode.current and "Current" or mode.default and "Default" or "Native"
          popup.field(item, token_value, "mode_" .. rendered,
            mode_identity(mode, role), rate(mode.refresh_rate),
            { label_max_chars = 28, value_max_chars = 16 })
        end
      end
    end

    if state.contrast ~= nil then
      popup.section(item, token_value, "image_heading", "Image")
      popup.field(item, token_value, "contrast_value", "Hardware contrast", percent(state.contrast))
      if control_ready("hardware_contrast", state.contrast, "number") then
        numeric_slider(token_value, "contrast_slider", "hardware_contrast", state.contrast, colors.purple, "Changing hardware contrast…")
      else
        popup.note(item, token_value, "contrast_inactive",
          busy and "Contrast control is inactive while an action is busy"
            or "Hardware contrast control is unavailable",
          { color = colors.muted })
      end
    end

    if state.volume ~= nil or state.mute ~= nil then
      popup.section(item, token_value, "sound_heading", "Display audio")
      if state.volume ~= nil then
        popup.field(item, token_value, "volume_value", "Volume", percent(state.volume))
        if control_ready("volume", state.volume, "number") then
          numeric_slider(token_value, "volume_slider", "volume", state.volume, colors.cyan, "Changing display volume…")
        else
          popup.note(item, token_value, "volume_inactive",
            busy and "Volume control is inactive while an action is busy"
              or "Display volume control is unavailable",
            { color = colors.muted })
        end
      end
      if state.mute ~= nil then
        popup.field(item, token_value, "mute", "Mute", state.mute and "On" or "Off")
        if control_ready("mute", state.mute, "boolean") then
          mute_action(token_value)
        else
          popup.note(item, token_value, "mute_inactive",
            busy and "Mute control is inactive while an action is busy"
              or "Display mute control is unavailable",
            { color = colors.muted })
        end
      end
    end
  end

  popup.section(item, token_value, "open_heading", "Open")
  popup.link(item, token_value, "betterdisplay", "Open BetterDisplay", function()
    shell.exec({ "/usr/bin/open", "-a", "BetterDisplay" })
  end)
  popup.link(item, token_value, "settings", "Open System Settings · select Displays", function()
    shell.open(settings.links.displays)
  end)
end

rebuild = function()
  if token and popup.is_current(item, token) then popup.rebuild(item, token, build) end
end

local function render()
  local available = state ~= nil
  local idle = available and colors.domain.display or colors.muted
  item:set({
    icon = { color = hover.foreground(item, idle) },
    label = { string = available and "Display confirmed" or "Display state unavailable" },
  })
  rebuild()
end

refresh = function()
  if read_in_flight or busy then
    refresh_pending = true
    return
  end
  refresh_pending = false
  read_in_flight = true
  read_generation = read_generation + 1
  local generation = read_generation
  sbar.delay(CONFIRMATION_TIMEOUT_SECONDS, function()
    if read_generation ~= generation or not read_in_flight then return end
    local discard = read_invalidated
    read_generation = generation + 1
    read_in_flight = false
    read_invalidated = false
    if discard then
      refresh_pending = true
      refresh()
    else
      refresh_pending = false
      state = nil
      popup_confirmation_pending = false
      render()
    end
  end)
  helper({ "state" }, function(output, code)
    if read_generation ~= generation then return end
    local discard = read_invalidated
    read_invalidated = false
    read_in_flight = false
    if discard then
      refresh_pending = true
    else
      state = code == 0 and sanitize_state(output, false) or nil
      popup_confirmation_pending = refresh_pending
      render()
    end
    if refresh_pending then refresh() end
  end)
end

hover.bind(item, { idle_background = false, idle_color = function()
  return state and colors.domain.display or colors.muted
end })
popup.bind(item, {
  align = "left", idle_background = false,
  right_click = function() shell.exec({ "/usr/bin/open", "-a", "BetterDisplay" }) end,
  on_close = function() token = nil; action_error = nil; popup_confirmation_pending = false end,
  build = function(current_token)
    token = current_token
    action_error = nil
    popup_confirmation_pending = true
    build(current_token)
    refresh()
  end,
})
item:subscribe({ "system_woke", "display_change" }, refresh)
refresh()
return item
