local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local network = require("lib.network")
local hover = require("lib.hover")
local active_wifi = nil
local wifi_vpn_in_flight = nil

local wifi = sbar.add("item", "wifi", {
  position = "right",
  updates = true,
  update_freq = 5,
  width = settings.control_width,
  icon = { string = "󰤨", color = colors.normal, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 12.0 } },
  label = { drawing = false, color = colors.muted, width = 94, max_chars = 15 },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 0 },
})

local function update_wifi_popup(state)
  if not active_wifi or not popup.is_current(wifi, active_wifi.token) then return end
  local name = state.ssid ~= "—" and state.ssid or (state.state == "connected" and "Connected" or "Offline")
  active_wifi.link:set({ label = { string = state.state:upper() .. "  ·  " .. name, color = state.state == "connected" and colors.primary or colors.warning } })
  active_wifi.address:set({ label = { string = state.interface .. "  ·  " .. state.ip, color = colors.muted } })
  active_wifi.gateway:set({ label = { string = "GATEWAY  " .. state.router, color = colors.muted } })
  active_wifi.traffic:set({ label = { string = "↓ " .. network.format_rate(state.rx_rate) .. "    ↑ " .. network.format_rate(state.tx_rate) } })
end

local function update_wifi()
  network.sample(function(state)
    local detail = state.state == "connected" and (state.ssid ~= "—" and state.ssid or "Connected") or "Offline"
    local idle_color = state.state == "connected" and colors.primary or colors.warning
    wifi:set({
      width = settings.control_width,
      icon = { string = state.state == "connected" and "󰤨" or "󰤭", color = hover.foreground(wifi, idle_color) },
      label = { string = detail, drawing = false },
    })
    update_wifi_popup(state)
  end)
end
wifi:subscribe({ "routine", "system_woke", "network_connect" }, update_wifi)
hover.bind(wifi, { idle_color = function() return network.current.state == "connected" and colors.primary or colors.warning end })

local function refresh_wifi_vpn(token)
  if wifi_vpn_in_flight ~= nil or not active_wifi or active_wifi.token ~= token or not popup.is_current(wifi, token) then return end
  wifi_vpn_in_flight = token
  shell.exec({ settings.config_dir .. "/scripts/vpn-state.sh" }, function(output, exit_code)
    if wifi_vpn_in_flight ~= token then return end
    wifi_vpn_in_flight = nil
    if active_wifi and active_wifi.token == token and popup.is_current(wifi, token) then
      local value = exit_code == 0 and shell.display(output) or "—"
      active_wifi.vpn:set({ label = { string = "VPN  " .. value, color = (value == "—" or value:lower() == "off") and colors.muted or colors.primary } })
      sbar.delay(8, function() refresh_wifi_vpn(token) end)
    elseif active_wifi and popup.is_current(wifi, active_wifi.token) then
      local next_token = active_wifi.token
      sbar.delay(0.1, function() refresh_wifi_vpn(next_token) end)
    end
  end)
end

popup.bind(wifi, {
  align = "right",
  right_click = function() shell.open("x-apple.systempreferences:com.apple.wifi-settings-extension") end,
  on_close = function() active_wifi = nil end,
  build = function(token)
    popup.row(wifi, token, "heading", { label = { string = "NETWORK", color = colors.primary } })
    active_wifi = {
      token = token,
      link = popup.row(wifi, token, "link", {}),
      address = popup.row(wifi, token, "address", {}),
      gateway = popup.row(wifi, token, "gateway", {}),
      traffic = popup.row(wifi, token, "traffic", {}),
      connection = popup.row(wifi, token, "connection_heading", { label = { string = "CONNECTION", color = colors.primary } }),
      vpn = popup.row(wifi, token, "vpn", { label = { string = "VPN        …", color = colors.muted } }),
    }
    update_wifi_popup(network.current)
    update_wifi()
    refresh_wifi_vpn(token)
  end,
})

local bluetooth_cache = { time = 0, data = nil, profile_fingerprint = "", connected_fingerprint = "" }
local bluetooth_connected = 0
local bluetooth_generation = 0
local bluetooth = sbar.add("item", "bluetooth", {
  position = "right",
  drawing = true,
  updates = true,
  update_freq = 30,
  width = settings.control_width,
  icon = { string = "󰂯", color = colors.dim, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0 },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 0 },
})

local function update_bluetooth()
  bluetooth_generation = bluetooth_generation + 1
  local token = bluetooth_generation
  shell.exec({ settings.paths.blueutil, "--connected", "--format", "json" }, function(devices, exit_code)
    if token ~= bluetooth_generation then return end
    local connected = exit_code == 0 and type(devices) == "table" and #devices or 0
    local names = {}
    if type(devices) == "table" then
      for _, device in ipairs(devices) do names[#names + 1] = tostring(device.name or device.address or device) end
      table.sort(names)
    end
    local fingerprint = table.concat(names, "|")
    if bluetooth_cache.connected_fingerprint ~= fingerprint then
      bluetooth_cache = { time = 0, data = nil, profile_fingerprint = "", connected_fingerprint = fingerprint }
    end
    bluetooth_connected = connected
    local idle_color = connected > 0 and colors.primary or colors.muted
    bluetooth:set({ icon = { string = connected > 0 and "󰂱" or "󰂯", color = hover.foreground(bluetooth, idle_color) } })
  end)
end

bluetooth:subscribe({ "routine", "system_woke" }, update_bluetooth)
hover.bind(bluetooth, { idle_color = function() return bluetooth_connected > 0 and colors.primary or colors.muted end })

local function bluetooth_rows(token, profile)
  if not popup.is_current(bluetooth, token) or type(profile) ~= "table" then return end
  local root = profile.SPBluetoothDataType and profile.SPBluetoothDataType[1] or {}
  local controller = root.controller_properties or {}
  local connected = root.device_connected or {}
  local names = {}
  for _, wrapper in ipairs(connected) do
    for name in pairs(wrapper) do names[#names + 1] = name end
  end
  table.sort(names)
  local fingerprint = tostring(controller.controller_state or "") .. "|" .. table.concat(names, "|")
  bluetooth_cache.profile_fingerprint = fingerprint
  popup.row(bluetooth, token, "controller", { label = { string = "Controller  " .. (controller.controller_state == "attrib_on" and "on" or "off"), color = colors.active } })
  if #names == 0 then
    popup.row(bluetooth, token, "none", { label = { string = "No connected devices", color = colors.dim } })
  else
    for index, name in ipairs(names) do popup.row(bluetooth, token, "device" .. index, { label = { string = "Connected   " .. shell.display(name), color = colors.soft } }) end
  end
end

popup.bind(bluetooth, {
  align = "right",
  right_click = function() shell.open("x-apple.systempreferences:com.apple.BluetoothSettings") end,
  build = function(token)
    popup.row(bluetooth, token, "heading", { label = { string = "BLUETOOTH", color = colors.primary } })
    if bluetooth_cache.data and os.time() - bluetooth_cache.time < 60 then
      bluetooth_rows(token, bluetooth_cache.data)
      return
    end
    local loading = popup.row(bluetooth, token, "loading", { label = { string = "Bluetooth  …", color = colors.dim } })
    shell.exec({ "/usr/sbin/system_profiler", "SPBluetoothDataType", "-json", "-detailLevel", "mini" }, function(profile, exit_code)
      if not popup.is_current(bluetooth, token) then return end
      if exit_code ~= 0 or type(profile) ~= "table" then
        if loading then loading:set({ drawing = false }) end
        popup.row(bluetooth, token, "unavailable", { label = { string = "Bluetooth unavailable", color = colors.dim } })
        return
      end
      if loading then loading:set({ drawing = false }) end
      bluetooth_cache = { time = os.time(), data = profile, profile_fingerprint = bluetooth_cache.profile_fingerprint, connected_fingerprint = bluetooth_cache.connected_fingerprint }
      bluetooth_rows(token, profile)
    end)
  end,
})

update_wifi()
update_bluetooth()
return { wifi = wifi, bluetooth = bluetooth }
