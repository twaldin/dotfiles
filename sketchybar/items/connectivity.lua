local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")

local wifi_state, bluetooth_state = nil, nil
local wifi_token, bluetooth_token = nil, nil
local wifi_busy, bluetooth_busy = false, false
local wifi_error, bluetooth_error = nil, nil

local wifi = sbar.add("item", "wifi", {
  position = "left", drawing = true, updates = true, update_freq = 30,
  width = settings.control_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = { string = "󰤭", color = colors.muted, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0 },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0 },
})
local bluetooth = sbar.add("item", "bluetooth", {
  position = "left", drawing = true, updates = true, update_freq = 30,
  width = settings.control_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = { string = "󰂲", color = colors.muted, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0 },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0 },
})

local function action(host, token, suffix, label, selected, callback, options)
  options = options or {}
  local icon = options.icon or (selected and "✓" or "")
  local icon_color = options.icon_color or (selected and colors.green or colors.blue)
  local row = popup.row(host, token, suffix, {
    icon = { drawing = true, string = icon, width = 24, color = icon_color, padding_left = 8, padding_right = 0 },
    label = { string = shell.ellipsis(label, 30), color = selected and colors.primary or colors.muted },
    background = { drawing = selected and options.highlight ~= false, color = colors.surface2 },
  })
  if row then
    popup.action(row, { selected = selected and options.highlight ~= false, idle_color = selected and colors.primary or colors.muted, idle_icon_color = icon_color })
    if not options.disabled then popup.on_click(row, function(env)
      if (not env.BUTTON or env.BUTTON == "left") and popup.is_current(host, token) then callback() end
    end) end
  end
end

local wifi_association_text = {
  associated = "Associated",
  link_unverified = "Association unverified",
  not_associated = "Not associated",
  ibss = "IBSS association",
  host_ap = "Host access point",
  radio_off = "Radio off",
  unknown = "Association not reported",
}
local wifi_network_text = {
  associated = "Associated network",
  link_unverified = "Association unverified",
  not_associated = "Not connected",
  ibss = "IBSS association",
  host_ap = "Host access point",
  radio_off = "Radio off",
  unknown = "Association not reported",
}
local function wifi_text(values, association)
  return values[association] or "Association not reported"
end

local function reported_text(value)
  local text = tostring(value or ""):gsub("_", " ")
  if text == "" or text == "unknown" then return "Not reported" end
  return text
end

local rebuild_wifi
local function build_wifi(token)
  if not popup.is_current(wifi, token) then return end
  popup.header(wifi, token, "WI-FI", wifi_state and (wifi_state.power and "On" or "Off") or "—")
  if not wifi_state then
    popup.note(wifi, token, "unavailable", "Wi-Fi state unavailable", { align = "center", color = colors.state.actionable })
  else
    popup.section(wifi, token, "current_heading", "Connection")
    local association = wifi_state.association or "unknown"
    local network = wifi_state.ssid or wifi_text(wifi_network_text, association)
    local rssi, noise, rate = tonumber(wifi_state.rssi), tonumber(wifi_state.noise), tonumber(wifi_state.rate)
    local service = type(wifi_state.service_active) == "boolean"
      and (wifi_state.service_active and "Active" or "Inactive") or "Not reported"
    local mode = reported_text(wifi_state.mode)
    popup.field(wifi, token, "network", "Network", shell.ellipsis(network, 19), { value_color = wifi_state.ssid and colors.primary or colors.muted })
    popup.field(wifi, token, "association", "Status", wifi_text(wifi_association_text, association))
    popup.field(wifi, token, "service", "Service", service)
    popup.field(wifi, token, "mode", "Mode", mode)
    popup.field(wifi, token, "phy", "PHY", reported_text(wifi_state.phy))
    popup.field(wifi, token, "channel", "Channel", wifi_state.channel
      and table.concat({ tostring(wifi_state.channel), reported_text(wifi_state.band),
        reported_text(wifi_state.channel_width) }, " · ") or "Not reported")
    popup.field(wifi, token, "mcs", "MCS", type(wifi_state.mcs) == "number"
      and string.format("%.0f", wifi_state.mcs) or "Not reported")
    popup.field(wifi, token, "signal", "Signal", rssi and string.format("%.0f dBm", rssi) or "Not reported")
    popup.field(wifi, token, "noise", "Noise", noise and string.format("%.0f dBm", noise) or "Not reported")
    popup.field(wifi, token, "rate", "Transmit rate", rate and string.format("%.0f Mb/s", rate) or "Not reported")
    popup.field(wifi, token, "security", "Security", reported_text(wifi_state.security))
    local permission = wifi_state.name_permission
    if association == "associated" and not wifi_state.name_available then
      if permission == "not_determined" or permission == "denied"
        or permission == "restricted" or permission == "services_disabled" then
        popup.section(wifi, token, "name_permission_heading", "Network name")
        local label = permission == "not_determined" and "Allow network name · Location"
          or "Open System Settings · Location Services"
        action(wifi, token, "name_permission", label, false, function()
          if wifi_busy then return end
          wifi_busy = true
          wifi_error = nil
          rebuild_wifi()
          shell.exec({ settings.config_dir .. "/scripts/connectivity-state.py", "wifi", "authorize-name" }, function(output, code)
            wifi_busy = false
            if code == 0 and type(output) == "table" then
              wifi_state = output
            else
              wifi_error = "Network-name permission was not read back"
            end
            rebuild_wifi()
          end)
        end, { icon = "󰌆", icon_color = colors.state.actionable, highlight = false, disabled = wifi_busy })
      elseif permission == "authorized" then
        popup.note(wifi, token, "name_note", "macOS did not report the associated network name", { color = colors.muted })
      else
        popup.note(wifi, token, "name_note", "Network-name access could not be checked", { color = colors.muted })
      end
    end
    if wifi_error then popup.note(wifi, token, "action_error", wifi_error, { align = "center", color = colors.state.actionable }) end
    popup.section(wifi, token, "radio_heading", "Radio")
    if wifi_busy then
      popup.note(wifi, token, "working", "WORKING · Wi-Fi change", { align = "center", color = colors.state.busy })
    else
      local captured_power = wifi_state.power
      local captured_interface = wifi_state.interface_key
      action(wifi, token, "toggle", captured_power and "Turn Wi-Fi off" or "Turn Wi-Fi on", false, function()
        if wifi_busy then return end
        wifi_busy = true
        wifi_error = nil
        rebuild_wifi()
        local desired = captured_power and "off" or "on"
        local expected = captured_power and "on" or "off"
        shell.exec({ settings.config_dir .. "/scripts/connectivity-state.py", "wifi", "set", desired, expected, captured_interface }, function(output, code)
          wifi_busy = false
          if code == 0 and type(output) == "table" then
            wifi_state = output
          else
            wifi_error = "Wi-Fi change was not confirmed"
          end
          rebuild_wifi()
        end)
      end, { icon = "⏻", icon_color = captured_power and colors.green or colors.muted, highlight = false })
    end
  end
  popup.section(wifi, token, "settings_heading", "Open")
  popup.link(wifi, token, "settings", "Open System Settings · select Wi-Fi", function() shell.open(settings.links.wifi) end)
end

rebuild_wifi = function()
  if wifi_token and popup.is_current(wifi, wifi_token) then
    popup.rebuild(wifi, wifi_token, build_wifi)
  end
end

local function proved_bluetooth_total(state, device_count)
  if not state or state.inventory_available ~= true
    or type(state.total_count) ~= "number" or state.total_count < 0
    or state.total_count % 1 ~= 0 or state.total_count < device_count
    or type(state.truncated) ~= "boolean"
    or state.truncated ~= (state.total_count > device_count) then return nil end
  return state.total_count
end

local battery_component_text = { main = "Battery", left = "Left", right = "Right", case = "Case" }
local function bluetooth_device_facts(device)
  local facts = { device.paired == true and "Paired" or "Not paired" }
  if type(device.type) == "string" and device.type ~= "" then facts[#facts + 1] = device.type end
  if type(device.profiles) == "table" and #device.profiles > 0 then
    local profiles = {}
    for index = 1, math.min(6, #device.profiles) do
      if type(device.profiles[index]) == "string" and device.profiles[index] ~= "" then
        profiles[#profiles + 1] = device.profiles[index]
      end
    end
    if #profiles > 0 then facts[#facts + 1] = "Profile " .. table.concat(profiles, "/") end
  end
  local rssi = tonumber(device.rssi)
  if rssi and rssi >= -127 and rssi <= -1 then
    facts[#facts + 1] = string.format("RSSI %.0f dBm", rssi)
  end
  if type(device.battery) == "table" then
    for index = 1, math.min(4, #device.battery) do
      local value = device.battery[index]
      local label = type(value) == "table" and battery_component_text[value.component] or nil
      local percent = type(value) == "table" and tonumber(value.percent) or nil
      if label and percent and percent >= 0 and percent <= 100 then
        facts[#facts + 1] = string.format("%s %.0f%%", label, percent)
      end
    end
  end
  return table.concat(facts, " · ")
end

local rebuild_bluetooth
local function build_bluetooth(token)
  if not popup.is_current(bluetooth, token) then return end
  local devices = bluetooth_state and bluetooth_state.devices or {}
  local connected_count = 0
  for _, device in ipairs(devices) do if device.connected then connected_count = connected_count + 1 end end
  local exact_total = proved_bluetooth_total(bluetooth_state, #devices)
  local chip = "—"
  if bluetooth_state then
    if bluetooth_state.inventory_available ~= true then
      chip = (bluetooth_state.power and "On" or "Off") .. " · devices unavailable"
    elseif exact_total and not bluetooth_state.truncated then
      chip = (bluetooth_state.power and "On" or "Off") .. " · " .. connected_count .. " connected"
    else
      chip = (bluetooth_state.power and "On" or "Off") .. " · partial device list"
    end
  end
  popup.header(bluetooth, token, "BLUETOOTH", chip)
  if not bluetooth_state then
    popup.note(bluetooth, token, "unavailable", "Bluetooth state unavailable", { align = "center", color = colors.state.actionable })
  else
    popup.section(bluetooth, token, "state_heading", "State")
    popup.field(bluetooth, token, "adapter_state", "Adapter", bluetooth_state.power and "On" or "Off", { value_color = bluetooth_state.power and colors.primary or colors.state.actionable })
    popup.note(bluetooth, token, "adapter_note", "Change adapter power in Bluetooth Settings", { color = colors.muted })
    if bluetooth_error then popup.note(bluetooth, token, "action_error", bluetooth_error, { align = "center", color = colors.state.actionable }) end
    if bluetooth_busy then popup.note(bluetooth, token, "working", "WORKING · Bluetooth device", { align = "center", color = colors.state.busy }) end
    popup.section(bluetooth, token, "devices_heading", "Paired devices")
    if bluetooth_state.inventory_available ~= true then
      local message = bluetooth_state.power and "Paired-device inventory unavailable"
        or "Paired-device inventory unavailable while Bluetooth is off"
      popup.note(bluetooth, token, "inventory_unavailable", message, { align = "center" })
    elseif exact_total == 0 then
      popup.note(bluetooth, token, "none", "No paired devices", { align = "center" })
    end
    if bluetooth_state.inventory_available == true then
      if not bluetooth_state.power and #devices > 0 then
        popup.note(bluetooth, token, "power_required",
          "Turn on Bluetooth in System Settings to change devices", { align = "center", color = colors.muted })
      end
      for index = 1, math.min(8, #devices) do
        local captured = devices[index]
        local label = captured.name
          .. (captured.connected and "  ·  Connected" or "  ·  Disconnected")
        if bluetooth_state.power then
          action(bluetooth, token, "device_" .. index, label, captured.connected, function()
            if bluetooth_busy then return end
            bluetooth_busy = true
            bluetooth_error = nil
            rebuild_bluetooth()
            local expected = captured.connected and "on" or "off"
            shell.exec({ settings.config_dir .. "/scripts/connectivity-state.py", "bluetooth", captured.connected and "disconnect" or "connect", captured.key, expected }, function(output, code)
              bluetooth_busy = false
              if code == 0 and type(output) == "table" then
                bluetooth_state = output
              else
                bluetooth_error = "Bluetooth change was not confirmed"
              end
              rebuild_bluetooth()
            end)
          end, { disabled = bluetooth_busy })
        else
          popup.field(bluetooth, token, "device_" .. index, label, "Read only",
            { value_color = colors.muted })
        end
        popup.note(bluetooth, token, "device_facts_" .. index,
          bluetooth_device_facts(captured), { color = colors.muted })
      end
    end
    if exact_total and exact_total > 8 then
      popup.link(bluetooth, token, "device_overflow", "… and " .. (exact_total - 8) .. " more", function() shell.open(settings.links.bluetooth) end)
    elseif #devices > 8 or bluetooth_state.truncated == true then
      popup.link(bluetooth, token, "device_overflow", "More paired devices", function() shell.open(settings.links.bluetooth) end)
    end
  end
  popup.section(bluetooth, token, "settings_heading", "Open")
  popup.link(bluetooth, token, "settings", "Open System Settings · select Bluetooth", function() shell.open(settings.links.bluetooth) end)
end

rebuild_bluetooth = function()
  if bluetooth_token and popup.is_current(bluetooth, bluetooth_token) then
    popup.rebuild(bluetooth, bluetooth_token, build_bluetooth)
  end
end

local wifi_in_flight, bluetooth_in_flight = false, false
local function bluetooth_icon_color()
  if not bluetooth_state then return colors.muted end
  if not bluetooth_state.power then return colors.state.actionable end
  for _, device in ipairs(bluetooth_state.devices or {}) do
    if device.connected then return colors.blue end
  end
  return colors.primary
end
local function refresh_wifi()
  if wifi_in_flight then return end; wifi_in_flight = true
  shell.exec({ settings.config_dir .. "/scripts/connectivity-state.py", "wifi", "state" }, function(output, code)
    wifi_in_flight = false; wifi_state = code == 0 and type(output) == "table" and output or nil
    local available = wifi_state and wifi_state.power
    local associated = available and wifi_state.association == "associated"
    wifi:set({ icon = { string = associated and "󰤨" or (available and "󰤯" or "󰤭"),
      color = hover.foreground(wifi, available and colors.primary or colors.muted) } })
    rebuild_wifi()
  end)
end
local function refresh_bluetooth()
  if bluetooth_in_flight then return end; bluetooth_in_flight = true
  shell.exec({ settings.config_dir .. "/scripts/connectivity-state.py", "bluetooth", "state" }, function(output, code)
    bluetooth_in_flight = false; bluetooth_state = code == 0 and type(output) == "table" and output or nil
    local enabled = bluetooth_state and bluetooth_state.power
    bluetooth:set({ icon = { string = enabled and "󰂯" or "󰂲",
      color = hover.foreground(bluetooth, bluetooth_icon_color()) } })
    rebuild_bluetooth()
  end)
end

hover.bind(wifi, { idle_background = false, idle_color = function() return wifi_state and wifi_state.power and colors.primary or colors.muted end })
hover.bind(bluetooth, { idle_background = false, idle_color = bluetooth_icon_color })
popup.bind(wifi, { align = "left", idle_background = false, right_click = function() shell.open(settings.links.wifi) end,
  on_close = function() wifi_token = nil end, build = function(token) wifi_token = token; build_wifi(token); refresh_wifi() end })
popup.bind(bluetooth, { align = "left", idle_background = false, right_click = function() shell.open(settings.links.bluetooth) end,
  on_close = function() bluetooth_token = nil end, build = function(token) bluetooth_token = token; build_bluetooth(token); refresh_bluetooth() end })
wifi:subscribe({ "routine", "system_woke", "network_connect" }, refresh_wifi)
bluetooth:subscribe({ "routine", "system_woke" }, refresh_bluetooth)
shell.exec({ settings.config_dir .. "/scripts/connectivity-state.py", "session", "begin" }, function(_, code)
  if code == 0 then refresh_wifi(); refresh_bluetooth() end
end)
return { wifi = wifi, bluetooth = bluetooth }
