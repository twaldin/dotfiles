local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")

local state = nil
local state_loading = true
local hardware = nil
local hardware_loading = false
local active = nil
local hardware_routine_ticks = 0
local hardware_requests = {}
local hardware_request_versions = {}
local hardware_refresh_routines = 4
local request_timeout_seconds = 70

local item = sbar.add("item", "battery", {
  position = "left", updates = true, update_freq = 30,
  width = settings.battery_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = { string = "󰁹", color = colors.muted, width = 25, align = "center", padding_left = 3, padding_right = 0, font = settings.type.bar_control },
  label = { string = "—", drawing = true, color = colors.muted, width = 31, align = "left", padding_left = 0, padding_right = 3, font = settings.type.bar_battery },
  background = { drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0 },
})

local inventory_labels = {
  present = "Present",
  absent = "No internal battery",
  ambiguous = "Multiple internal batteries",
  malformed = "Invalid inventory data",
  unavailable = "Inventory read failed",
  unsupported_type_present = "Unsupported source type",
}
local source_labels = { ac = "AC", battery = "Battery", ups = "UPS", offline = "Offline" }
local charge_labels = {
  finishing_charge = "Finishing charge",
  charging = "Charging",
  charged = "Charged",
  empty = "Empty",
  discharging = "Discharging",
  not_charging = "Not charging",
  offline = "Offline",
}
local condition_labels = {
  check_battery = "Check battery",
  permanent_battery_failure = "Permanent battery failure",
  no_reported_condition = "No reported condition",
}
local low_power_labels = { on = "On", off_or_unsupported = "Off or unsupported" }

local function allowed_keys(value, keys)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do if not keys[key] then return false end end
  return true
end

local function finite(value, minimum, maximum)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return false end
  return value >= minimum and value <= maximum
end

local function integer_or_nil(value, minimum, maximum)
  return value == nil or (finite(value, minimum, maximum) and value % 1 == 0)
end

local function number_or_nil(value, minimum, maximum)
  return value == nil or finite(value, minimum, maximum)
end

local function valid_hardware(value)
  if not allowed_keys(value, {
    schema = true, capacities = true, cycle_count = true, electrical = true, adapter = true,
  }) or value.schema ~= "battery_hardware_v1"
    or type(value.capacities) ~= "table" or type(value.electrical) ~= "table"
    or type(value.adapter) ~= "table" then return false end
  local capacities, electrical, adapter = value.capacities, value.electrical, value.adapter
  if not allowed_keys(capacities, {
    raw_current_mah = true, raw_maximum_mah = true, maximum_mah = true,
    design_mah = true, nominal_mah = true, maximum_to_design_ratio = true,
  }) or not allowed_keys(electrical, {
    signed_current_ma = true, voltage_v = true, temperature_c = true,
  }) or not allowed_keys(adapter, {
    watts = true, current_ma = true,
  }) then return false end
  if not integer_or_nil(capacities.raw_current_mah, 0, 1000000)
    or not integer_or_nil(capacities.raw_maximum_mah, 1, 1000000)
    or not integer_or_nil(capacities.maximum_mah, 1, 1000000)
    or not integer_or_nil(capacities.design_mah, 1, 1000000)
    or not integer_or_nil(capacities.nominal_mah, 1, 1000000)
    or not integer_or_nil(value.cycle_count, 0, 10000000)
    or not integer_or_nil(electrical.signed_current_ma, -1000000, 1000000)
    or not number_or_nil(electrical.voltage_v, 1, 100)
    or not number_or_nil(electrical.temperature_c, -50, 150)
    or not integer_or_nil(adapter.watts, 1, 1000)
    or not integer_or_nil(adapter.current_ma, 1, 100000) then return false end
  local ratio, maximum, design = capacities.maximum_to_design_ratio,
    capacities.maximum_mah, capacities.design_mah
  if maximum ~= nil and design ~= nil then
    local expected = maximum / design
    if not finite(ratio, 0, 4) or math.abs(ratio - expected) > 0.000000000001 then return false end
  elseif ratio ~= nil then
    return false
  end
  return true
end

local function closed_number(field)
  if type(field) == "table" and field.state == "value" then return tonumber(field.value) end
  return nil
end

local function percent_value()
  return state and closed_number(state.percent) or nil
end

local function icon()
  if not state then return "󰂑" end
  if state.charge == "charging" or state.charge == "finishing_charge" then return "󰂄" end
  local level = percent_value()
  if not level then return "󰂑" end
  if level >= 95 then return "󰁹" end
  if level >= 80 then return "󰂂" end
  if level >= 60 then return "󰂀" end
  if level >= 40 then return "󰁾" end
  if level >= 20 then return "󰁼" end
  return "󰂎"
end

local function time_fact()
  if not state or type(state.time) ~= "table" then return nil, nil end
  local charging = state.charge == "charging" or state.charge == "finishing_charge"
  local discharging = state.charge == "discharging" or state.charge == "empty"
  if not charging and not discharging then return nil, nil end
  local label = charging and "Until full" or "Remaining"
  if state.time.state == "calculating" then return label, "Calculating…" end
  if state.time.state ~= "minutes" then return nil, nil end
  local minutes = tonumber(state.time.minutes)
  if not minutes or minutes < 0 or minutes % 1 ~= 0 then return nil, nil end
  return label, string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

local function cycle_count()
  if state_loading or hardware_loading then return nil end
  local public_count = state and closed_number(state.cycles) or nil
  local hardware_count = hardware and hardware.cycle_count or nil
  if public_count ~= nil and hardware_count ~= nil and public_count ~= hardware_count then return nil end
  return public_count ~= nil and public_count or hardware_count
end

local function integer_reading(value, suffix)
  return string.format("%.0f%s", value, suffix or "")
end

local function decimal_reading(value, pattern)
  return string.format(pattern, value)
end

local function signed_current(value)
  return string.format("%+.0f mA", value)
end

local function has_hardware_readings()
  if not hardware then return false end
  local capacities, electrical, adapter = hardware.capacities, hardware.electrical, hardware.adapter
  return capacities.raw_current_mah ~= nil or capacities.raw_maximum_mah ~= nil
    or capacities.design_mah ~= nil or capacities.nominal_mah ~= nil
    or (capacities.maximum_to_design_ratio ~= nil
      and capacities.raw_maximum_mah == capacities.maximum_mah)
    or electrical.signed_current_ma ~= nil or electrical.voltage_v ~= nil
    or electrical.temperature_c ~= nil or adapter.watts ~= nil or adapter.current_ma ~= nil
end

local function build_health(token)
  local condition = state and condition_labels[state.condition] or nil
  local count = cycle_count()
  if not condition and count == nil then return end
  popup.section(item, token, "health_heading", "Health")
  if condition then
    local condition_color = state.condition == "permanent_battery_failure" and colors.red
      or state.condition == "check_battery" and colors.warning or colors.primary
    popup.field(item, token, "condition", "Condition", condition, { value_color = condition_color })
  end
  if count ~= nil then popup.field(item, token, "cycles", "Cycles", integer_reading(count)) end
end

local function build_hardware(token)
  if hardware_loading and not hardware then return end
  if not hardware then
    popup.section(item, token, "hardware_heading", "Hardware readings")
    popup.note(item, token, "hardware_failure", "Hardware read failed. Retrying automatically; reopen to retry now.", { align = "center" })
    return
  end
  if not has_hardware_readings() then
    popup.section(item, token, "hardware_heading", "Hardware readings")
    popup.note(item, token, "hardware_empty", "No battery hardware readings were reported.", { align = "center" })
    return
  end
  popup.section(item, token, "hardware_heading", "Hardware readings")
  local capacities, electrical, adapter = hardware.capacities, hardware.electrical, hardware.adapter
  if capacities.raw_current_mah ~= nil then
    popup.field(item, token, "raw_current_capacity", "Raw current capacity", integer_reading(capacities.raw_current_mah, " mAh"))
  end
  if capacities.raw_maximum_mah ~= nil then
    popup.field(item, token, "raw_maximum_capacity", "Raw maximum capacity", integer_reading(capacities.raw_maximum_mah, " mAh"))
  end
  if capacities.design_mah ~= nil then
    popup.field(item, token, "design_capacity", "Raw design capacity", integer_reading(capacities.design_mah, " mAh"))
  end
  if capacities.nominal_mah ~= nil then
    popup.field(item, token, "nominal_capacity", "Nominal capacity", integer_reading(capacities.nominal_mah, " mAh"))
  end
  if capacities.maximum_to_design_ratio ~= nil
    and capacities.raw_maximum_mah == capacities.maximum_mah then
    popup.field(item, token, "maximum_design_ratio", "Raw maximum / design", decimal_reading(capacities.maximum_to_design_ratio * 100, "%.1f%%"))
  end
  if electrical.signed_current_ma ~= nil then
    popup.field(item, token, "signed_current", "Signed battery current", signed_current(electrical.signed_current_ma))
  end
  if electrical.voltage_v ~= nil then
    popup.field(item, token, "battery_voltage", "Battery voltage", decimal_reading(electrical.voltage_v, "%.3f V"))
  end
  if electrical.temperature_c ~= nil then
    popup.field(item, token, "battery_temperature", "Battery temperature", decimal_reading(electrical.temperature_c, "%.1f °C"))
  end
  if adapter.watts ~= nil then
    popup.field(item, token, "adapter_watts", "Adapter watts", integer_reading(adapter.watts, " W"))
  end
  if adapter.current_ma ~= nil then
    popup.field(item, token, "adapter_current", "Adapter current", integer_reading(adapter.current_ma, " mA"))
  end
end

local function open_system_settings()
  shell.exec({ "/usr/bin/open", "/System/Applications/System Settings.app" })
end

local function build(token)
  if not state then
    popup.header(item, token, "BATTERY")
    if state_loading then
      popup.note(item, token, "status_loading", "Reading battery status…", { align = "center" })
    else
      popup.note(item, token, "status_failure", "Status read failed. Retrying automatically; reopen to retry now.", { align = "center" })
    end
    build_health(token)
    build_hardware(token)
    popup.section(item, token, "settings_heading", "Open")
    popup.link(item, token, "settings", "Open System Settings · select Battery", open_system_settings)
    return
  end

  local percent = percent_value()
  local header_value = percent and string.format("%.0f%%", percent) or inventory_labels[state.inventory]
  local accent = percent and (percent <= 15 and colors.red or colors.primary) or colors.muted
  popup.header(item, token, "BATTERY", header_value, { color = accent })
  if percent then
    popup.meter(item, token, "charge_meter", percent, percent <= 15 and colors.red or ((state.charge == "charging" or state.charge == "finishing_charge") and colors.green or colors.blue))
  end

  popup.section(item, token, "status_heading", "Status")
  local inventory = inventory_labels[state.inventory]
  if inventory then popup.field(item, token, "inventory", "Internal battery", inventory) end
  local charge = charge_labels[state.charge]
  if charge then popup.field(item, token, "charge", "Charge", charge) end
  local source = source_labels[state.source]
  if source then popup.field(item, token, "source", "Source", source) end
  local time_label, time_value = time_fact()
  if time_value then popup.field(item, token, "remaining", time_label, time_value) end
  local low_power = low_power_labels[state.low_power]
  if low_power then popup.field(item, token, "low_power", "Low Power Mode", low_power) end

  build_health(token)
  build_hardware(token)
  popup.section(item, token, "settings_heading", "Open")
  popup.link(item, token, "settings", "Open System Settings · select Battery", open_system_settings)
end

local function rebuild()
  if active and popup.is_current(item, active) then popup.rebuild(item, active, build) end
end

local function render()
  local level = percent_value()
  if not level then
    item:set({ icon = { string = icon(), color = colors.muted }, label = { string = "—", color = colors.muted } })
    rebuild()
    return
  end
  local charging = state.charge == "charging" or state.charge == "finishing_charge"
  local color = level <= 15 and colors.red or (charging and colors.green or colors.primary)
  item:set({ icon = { string = icon(), color = hover.foreground(item, color) }, label = { string = string.format("%.0f%%", level), color = color } })
  rebuild()
end

local state_in_flight = false
local state_request_version = 0
local function refresh(replace_pending, suppress_rebuild)
  if state_in_flight and not replace_pending then return end
  state_request_version = state_request_version + 1
  local version = state_request_version
  state_in_flight = true
  state_loading = true
  if not suppress_rebuild then rebuild() end
  sbar.delay(request_timeout_seconds, function()
    if state_request_version ~= version or not state_in_flight then return end
    state_request_version = version + 1
    state_in_flight = false
    state_loading = false
    state = nil
    render()
  end)
  shell.exec({ settings.config_dir .. "/scripts/battery-state.py" }, function(output, exit_code)
    if state_request_version ~= version then return end
    state_in_flight = false
    state_loading = false
    if exit_code == 0 and type(output) == "table" and output.schema == "battery_state_v1" then
      state = output
    else
      state = nil
    end
    render()
  end)
end

local function refresh_hardware(token, replace_pending, suppress_rebuild)
  if not token or token ~= active or not popup.is_current(item, token) then return end
  if hardware_requests[token] and not replace_pending then return end
  local version = (hardware_request_versions[token] or 0) + 1
  hardware_request_versions[token] = version
  hardware_requests[token] = true
  hardware_loading = true
  if not suppress_rebuild then rebuild() end
  sbar.delay(request_timeout_seconds, function()
    if hardware_request_versions[token] ~= version or not hardware_requests[token] then return end
    hardware_request_versions[token] = version + 1
    hardware_requests[token] = nil
    if active == token and popup.is_current(item, token) then
      hardware_loading = false
      hardware = nil
      rebuild()
    end
  end)
  shell.exec({ settings.config_dir .. "/scripts/battery-hardware-state.py" }, function(output, exit_code)
    if hardware_request_versions[token] ~= version then return end
    hardware_requests[token] = nil
    if active == token and popup.is_current(item, token) then
      hardware_loading = false
      hardware = exit_code == 0 and valid_hardware(output) and output or nil
      rebuild()
    end
  end)
end

hover.bind(item, { idle_background = false, idle_color = function()
  local level = percent_value()
  if not level then return colors.muted end
  if level <= 15 then return colors.red end
  return (state.charge == "charging" or state.charge == "finishing_charge") and colors.green or colors.primary
end })
popup.bind(item, {
  align = "left", idle_background = false,
  right_click = open_system_settings,
  on_close = function()
    active = nil
    hardware = nil
    hardware_loading = false
    hardware_routine_ticks = 0
    hardware_requests = {}
    hardware_request_versions = {}
  end,
  build = function(token)
    active = token
    if not state then state_loading = true end
    hardware = nil
    hardware_loading = true
    hardware_routine_ticks = 0
    build(token)
    refresh(true, true)
    refresh_hardware(token, false, true)
  end,
})
item:subscribe("routine", function()
  refresh()
  if active and popup.is_current(item, active) then
    hardware_routine_ticks = hardware_routine_ticks + 1
    if hardware_routine_ticks >= hardware_refresh_routines then
      hardware_routine_ticks = 0
      hardware = nil
      hardware_loading = true
      rebuild()
      refresh_hardware(active, false, true)
    end
  end
end)
local function refresh_power_facts()
  if active and popup.is_current(item, active) then
    state = nil
    state_loading = true
    hardware = nil
    hardware_loading = true
    hardware_routine_ticks = 0
    rebuild()
    refresh(true, true)
    refresh_hardware(active, true, true)
  else
    refresh(true)
  end
end
item:subscribe("system_woke", refresh_power_facts)
item:subscribe("power_source_change", refresh_power_facts)
refresh()
return item
