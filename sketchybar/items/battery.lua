local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local current = { percentage = 0, state = "unknown", remaining = "—", full = "—" }
local details_cache = { time = 0, data = nil }
local hovered = false
local active = nil

local function display_or(value, fallback)
  local cleaned = shell.display(value)
  return cleaned ~= "" and cleaned or fallback
end

local item = sbar.add("item", "battery", {
  position = "right",
  updates = true,
  width = settings.control_width,
  icon = { string = "", color = colors.normal, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 15.0 } },
  label = { drawing = false, color = colors.muted, width = 46, max_chars = 7 },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 0 },
})

local function battery_icon(value)
  if value >= 88 then return "" elseif value >= 63 then return "" elseif value >= 38 then return "" elseif value >= 13 then return "" else return "" end
end

local function update_popup()
  if not active or not popup.is_current(item, active.token) then return end
  active.heading:set({ label = { string = string.format("BATTERY  %.0f%%", current.percentage), color = colors.primary } })
  active.state:set({ label = { string = "State      " .. current.state } })
  active.remaining:set({ label = { string = "Remaining  " .. current.remaining .. (tonumber(current.remaining) and " min" or "") } })
  active.full:set({ label = { string = "To full    " .. current.full .. (tonumber(current.full) and " min" or "") } })
end

local function update(env)
  local value = tonumber(env.BATTERY_PERCENTAGE)
  if value then current.percentage = math.max(0, math.min(100, value)) end
  if env.BATTERY_STATE ~= nil then current.state = display_or(env.BATTERY_STATE, "unknown") end
  if env.BATTERY_REMAINING ~= nil then current.remaining = display_or(env.BATTERY_REMAINING, "—") end
  if env.BATTERY_TIME_TO_FULL ~= nil then current.full = display_or(env.BATTERY_TIME_TO_FULL, "—") end
  local charging = tostring(current.state):lower():find("charg") ~= nil
  local idle_color = charging and colors.accent or (current.percentage < 10 and colors.critical or (current.percentage < 30 and colors.warning or colors.primary))
  local color = hover.foreground(item, idle_color)
  item:set({
    width = settings.control_width,
    icon = { string = battery_icon(current.percentage, current.state), color = color },
    label = { string = string.format("%.0f%%", current.percentage), drawing = false, color = color },
  })
  update_popup()
end
item:subscribe({ "system_stats", "power_source_change" }, update)

local function render_details(token, profile)
  if not popup.is_current(item, token) or type(profile) ~= "table" then return end
  local battery, charger = {}, {}
  for _, section in ipairs(profile.SPPowerDataType or {}) do
    if section.sppower_battery_health_info then battery = section.sppower_battery_health_info end
    if section._name == "sppower_ac_charger_information" then charger = section end
  end
  local cycle = display_or(battery.sppower_battery_cycle_count, "—")
  local health = display_or(battery.sppower_battery_health, "—")
  local capacity = display_or(battery.sppower_battery_health_maximum_capacity, "—")
  local watts = display_or(charger.sppower_ac_charger_watts, "—")
  popup.row(item, token, "cycle", { label = { string = "Cycles     " .. cycle } })
  popup.row(item, token, "health", { label = { string = "Health     " .. health } })
  popup.row(item, token, "capacity", { label = { string = "Capacity   " .. capacity } })
  popup.row(item, token, "watts", { label = { string = "Adapter    " .. watts .. (tonumber(watts) and " W" or "") } })
end

hover.bind(item, {
  on_change = function(value) hovered = value; update({}) end,
  idle_color = function()
    local charging = tostring(current.state):lower():find("charg") ~= nil
    return charging and colors.accent or (current.percentage < 10 and colors.critical or (current.percentage < 30 and colors.warning or colors.primary))
  end,
})

popup.bind(item, {
  align = "right",
  right_click = function() shell.open("x-apple.systempreferences:com.apple.Battery-Settings.extension") end,
  on_close = function() active = nil end,
  build = function(token)
    active = {
      token = token,
      heading = popup.row(item, token, "heading", {}),
      state = popup.row(item, token, "state", {}),
      remaining = popup.row(item, token, "remaining", {}),
      full = popup.row(item, token, "full", {}),
    }
    update_popup()
    if details_cache.data and os.time() - details_cache.time < 300 then render_details(token, details_cache.data); return end
    shell.exec({ "/usr/sbin/system_profiler", "SPPowerDataType", "-json", "-detailLevel", "mini" }, function(profile, exit_code)
      if not popup.is_current(item, token) then return end
      if exit_code ~= 0 or type(profile) ~= "table" then
        popup.row(item, token, "unavailable", { label = { string = "Power details unavailable", color = colors.dim } })
        return
      end
      details_cache = { time = os.time(), data = profile }
      render_details(token, profile)
    end)
  end,
})
return item
