local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local network = require("lib.network")
local latest = { cpu = 0, ram = 0, disk = 0, battery = 0, uptime = "—" }
local active = nil
local slow_in_flight = nil
local disk_in_flight = false

local item = sbar.add("item", "status", {
  position = "right",
  updates = true,
  update_freq = 300,
  width = settings.control_width,
  icon = { string = "󰄨", color = colors.muted, width = settings.icon_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 15.0 } },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 9 },
})

local function percent(value)
  value = tonumber(value)
  return value and math.max(0, math.min(100, value)) or nil
end

local function update_popup()
  if not active or not popup.is_current(item, active.token) then return end
  active.resources:set({ label = { string = string.format("CPU %5.1f%%    RAM %5.1f%%", latest.cpu, latest.ram), color = latest.cpu >= 90 and colors.warning or colors.primary } })
  active.capacity:set({ label = { string = string.format("DISK %4.1f%%    BAT %3.0f%%", latest.disk, latest.battery) } })
  active.network:set({ label = { string = "↓ " .. network.format_rate(network.current.rx_rate) .. "    ↑ " .. network.format_rate(network.current.tx_rate) } })
  active.uptime:set({ label = { string = "UP  " .. latest.uptime, color = colors.muted } })
end

local function render()
  item:set({ width = settings.control_width, icon = { color = latest.cpu >= 90 and colors.warning or colors.muted } })
  update_popup()
end

local function sample_data_disk()
  if disk_in_flight then return end
  disk_in_flight = true
  shell.exec({ settings.config_dir .. "/scripts/data-disk.sh" }, function(output, exit_code)
    disk_in_flight = false
    local value = exit_code == 0 and percent(shell.trim(output)) or nil
    if value then latest.disk = value; render() end
  end)
end

item:subscribe("system_stats", function(env)
  latest.cpu = percent(env.CPU_USAGE) or latest.cpu
  latest.ram = percent(env.RAM_USAGE) or latest.ram
  latest.disk = percent(env.DISK_USAGE) or latest.disk
  latest.battery = percent(env.BATTERY_PERCENTAGE) or latest.battery
  if env.UPTIME and env.UPTIME ~= "" then latest.uptime = shell.display(env.UPTIME) end
  render()
end)

item:subscribe({ "routine", "system_woke" }, sample_data_disk)
sample_data_disk()

hover.bind(item, { idle_color = function() return latest.cpu >= 90 and colors.warning or colors.muted end })

local function refresh_slow(token)
  if slow_in_flight ~= nil or not active or active.token ~= token or not popup.is_current(item, token) then return end
  slow_in_flight = token
  local pending = 2
  local function done()
    if slow_in_flight ~= token then return end
    pending = pending - 1
    if pending > 0 then return end
    slow_in_flight = nil
    if active and popup.is_current(item, active.token) then
      local next_token = active.token
      sbar.delay(next_token == token and 8 or 0.1, function() refresh_slow(next_token) end)
    end
  end
  shell.exec({ settings.config_dir .. "/scripts/top-processes.sh" }, function(output, exit_code)
    if active and active.token == token and popup.is_current(item, token) and exit_code == 0 then
      local lines = shell.lines(output)
      for index, row in ipairs(active.processes) do
        row:set({ label = { string = shell.ellipsis(lines[index] or "—", 29), color = colors.muted } })
      end
    end
    done()
  end)
  shell.exec({ settings.config_dir .. "/scripts/vpn-state.sh" }, function(output, exit_code)
    if active and active.token == token and popup.is_current(item, token) then
      local value = exit_code == 0 and shell.display(output) or "—"
      active.vpn:set({ label = { string = "VPN  " .. value, color = (value == "—" or value:lower() == "off") and colors.muted or colors.primary } })
    end
    done()
  end)
end

popup.bind(item, {
  align = "right",
  on_close = function() active = nil end,
  build = function(token)
    popup.row(item, token, "heading", { label = { string = "SYSTEM", color = colors.primary } })
    active = {
      token = token,
      resources = popup.row(item, token, "resources", {}),
      capacity = popup.row(item, token, "capacity", {}),
      network = popup.row(item, token, "network", {}),
      uptime = popup.row(item, token, "uptime", {}),
      processes = {},
    }
    popup.row(item, token, "process_heading", { label = { string = "TOP PROCESSES", color = colors.primary } })
    for index = 1, 4 do
      active.processes[index] = popup.row(item, token, "process" .. index, { label = { string = "…", color = colors.muted, max_chars = 38 } })
    end
    popup.row(item, token, "connection_heading", { label = { string = "CONNECTION", color = colors.primary } })
    active.vpn = popup.row(item, token, "vpn", { label = { string = "VPN        …", color = colors.muted } })
    update_popup()
    refresh_slow(token)
  end,
})
return item
