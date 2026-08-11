local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")

local state = nil
local active = nil

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
  ambiguous = "Ambiguous",
  malformed = "Malformed data",
  unavailable = "Unavailable",
  unsupported_type_present = "Unsupported source type",
}
local source_labels = { ac = "AC", battery = "Battery", ups = "UPS", unknown = "Unknown" }
local charge_labels = {
  finishing_charge = "Finishing charge",
  charging = "Charging",
  charged = "Charged",
  empty = "Empty",
  discharging = "Discharging",
  not_charging = "Not charging",
  offline = "Offline",
  unknown = "Unknown",
  unavailable = "Unavailable",
}
local health_labels = { good = "Good", fair = "Fair", poor = "Poor", unknown = "Unknown", unavailable = "Unavailable" }
local condition_labels = {
  check_battery = "Check battery",
  permanent_battery_failure = "Permanent battery failure",
  no_reported_condition = "No reported condition",
  unknown = "Unknown",
  unavailable = "Unavailable",
}
local low_power_labels = { on = "On", off_or_unsupported = "Off or unsupported" }

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

local function duration(value)
  if type(value) ~= "table" then return "Unavailable" end
  if value.state == "calculating" then return "Calculating…" end
  if value.state == "not_applicable" then return "Not applicable" end
  if value.state ~= "minutes" then return "Unavailable" end
  local minutes = tonumber(value.minutes)
  if not minutes then return "Unavailable" end
  return string.format("%dh %02dm", math.floor(minutes / 60), minutes % 60)
end

local function cycles(value)
  local count = closed_number(value)
  return count and string.format("%.0f", count) or "Unavailable"
end

local function open_system_settings()
  shell.exec({ "/usr/bin/open", "/System/Applications/System Settings.app" })
end

local function build(token)
  if not state then
    popup.header(item, token, "BATTERY")
    popup.note(item, token, "unavailable", "Battery data unavailable", { align = "center" })
    return
  end

  local percent = percent_value()
  local header_value = percent and string.format("%.0f%%", percent) or inventory_labels[state.inventory] or "Unavailable"
  local accent = percent and (percent <= 15 and colors.red or colors.primary) or colors.muted
  popup.header(item, token, "BATTERY", header_value, { color = accent })
  if percent then
    popup.meter(item, token, "charge_meter", percent, percent <= 15 and colors.red or ((state.charge == "charging" or state.charge == "finishing_charge") and colors.green or colors.blue))
  end

  popup.section(item, token, "status_heading", "Status")
  popup.field(item, token, "inventory", "Internal battery", inventory_labels[state.inventory] or "Unavailable")
  popup.field(item, token, "charge", "Charge", charge_labels[state.charge] or "Unavailable")
  popup.field(item, token, "source", "Source", source_labels[state.source] or "Unknown")
  popup.field(item, token, "remaining", (state.charge == "charging" or state.charge == "finishing_charge") and "Until full" or "Remaining", duration(state.time))
  popup.field(item, token, "low_power", "Low Power Mode", low_power_labels[state.low_power] or "Unavailable")

  popup.section(item, token, "health_heading", "Health")
  popup.field(item, token, "health", "Health", health_labels[state.health] or "Unavailable")
  popup.field(item, token, "condition", "Condition", condition_labels[state.condition] or "Unavailable")
  popup.field(item, token, "cycles", "Cycles", cycles(state.cycles))

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

local in_flight = false
local function refresh()
  if in_flight then return end
  in_flight = true
  shell.exec({ settings.config_dir .. "/scripts/battery-state.py" }, function(output, exit_code)
    in_flight = false
    if exit_code == 0 and type(output) == "table" and output.schema == "battery_state_v1" then
      state = output
    else
      state = nil
    end
    render()
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
  on_close = function() active = nil end,
  build = function(token) active = token; build(token); refresh() end,
})
item:subscribe("routine", refresh)
item:subscribe("system_woke", refresh)
item:subscribe("power_source_change", refresh)
refresh()
return item
