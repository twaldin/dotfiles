local colors = require("colors")
local hover = require("lib.hover")
local popup = require("lib.popup")
local shell = require("lib.shell")
local settings = require("settings")
local stats_contract = require("lib.stats_contract")
local hardware_contract = require("lib.hardware_contract")
local fan_power = require("lib.fan_power_control")

local definitions = {
  cpu = { icon = "󰍛", title = "CPU", color = colors.domain.cpu },
  gpu = { icon = "󰢮", title = "GPU", color = colors.domain.gpu },
  ram = { icon = "󰘚", title = "RAM", color = colors.domain.ram },
  net = { icon = "󰛳", title = "NET", color = colors.domain.net },
  ssd = { icon = "󰋊", title = "SSD", color = colors.domain.ssd },
  tmp = { icon = "󰔏", title = "TMP", color = colors.domain.tmp },
}
local order = { "cpu", "gpu", "ram", "net", "ssd", "tmp" }
local items, active = {}, {}
local histories = { cpu = {}, gpu = {}, ram = {}, net = {}, ssd = {} }
local history_reset = { cpu = 0, gpu = 0, ram = 0, net = 0, ssd = 0 }
local current = {}
local cursor = { retired = {} }
local render_all
local update_hardware_cadence
local fan_power_control

local function finite(value, minimum, maximum)
  value = tonumber(value)
  if not value or value ~= value or value == math.huge or value == -math.huge then return nil end
  if minimum and value < minimum then return nil end
  if maximum and value > maximum then return nil end
  return value
end

local function bound(value, minimum, maximum)
  value = finite(value, minimum, maximum)
  return value and math.max(minimum, math.min(maximum, value)) or nil
end

local function bytes(value)
  value = finite(value, 0)
  if not value then return "—" end
  local units = { "B", "KB", "MB", "GB", "TB" }
  local index = 1
  while value >= 1000 and index < #units do value, index = value / 1000, index + 1 end
  return string.format((value >= 100 or index == 1) and "%.0f %s" or "%.1f %s", value, units[index])
end

local function percent(value)
  value = bound(value, 0, 100)
  return value and string.format("%.0f%%", value) or "—"
end

local function temperature(value)
  value = finite(value, 0, 130)
  return value and string.format("%.0f °C", value) or "—"
end

local function watts(value)
  value = finite(value, 0, 1000)
  return value and string.format(value < 10 and "%.2f W" or "%.1f W", value) or "—"
end

local function frequency(value)
  value = finite(value, 1, 10000)
  if not value then return "—" end
  return value >= 1000 and string.format("%.2f GHz", value / 1000) or string.format("%.0f MHz", value)
end

local function rpm(value)
  value = finite(value, 0, 30000)
  return value and string.format("%.0f RPM", value) or "—"
end

local function append(name, value)
  value = finite(value, 0)
  if not value then return end
  local values = histories[name]
  values[#values + 1] = value
  while #values > 120 do table.remove(values, 1) end
end

local function reset_history(name)
  if #histories[name] > 0 then history_reset[name] = history_reset[name] + 1 end
  histories[name] = {}
end

local function clear_histories()
  for name in pairs(histories) do reset_history(name) end
end

local function warning_color(value)
  value = finite(value, 0) or 0
  if value >= 90 then return colors.red end
  if value >= 75 then return colors.warning end
  return nil
end

local function pressure_color(value)
  if value == "critical" then return colors.red end
  if value == "warning" then return colors.warning end
  return nil
end

local function thermal_color(value)
  if value == "critical" then return colors.red end
  if value == "serious" then return colors.warning end
  if value == "fair" then return colors.orange end
  return nil
end

local function title_case(value)
  value = tostring(value or "unknown"):gsub("_", " ")
  local result = value:gsub("^%l", string.upper)
  return result
end

local function yes_no(value)
  if value == nil then return "—" end
  return value and "Yes" or "No"
end

local function uptime(value)
  value = finite(value, 0, 9007199254740991)
  if not value then return "—" end
  value = math.floor(value)
  local days = math.floor(value / 86400)
  local hours = math.floor((value % 86400) / 3600)
  local minutes = math.floor((value % 3600) / 60)
  if days > 0 then return string.format("%dd %dh %dm", days, hours, minutes) end
  if hours > 0 then return string.format("%dh %dm", hours, minutes) end
  return string.format("%dm", minutes)
end

local function normalize_net(value)
  value = finite(value, 0) or 0
  return 100 * math.min(1, math.log(1 + value) / math.log(1 + 1024 * 1024 * 1024))
end

local function row(host, token, suffix, label, value, color)
  return popup.field(host, token, suffix, label, value, { value_color = color or colors.primary })
end

local function hardware_freshness(host, token)
  if current.hardware_stale then
    popup.note(host, token, "hardware_stale", "Refresh delayed · showing a recent sample", {
      align = "center", color = colors.warning,
    })
  end
end

local function gpu_headline()
  if current.gpu_activity ~= nil then return percent(current.gpu_activity) end
  if current.gpu_caps_valid ~= true then return "—" end
  if current.gpu_present ~= true then return "Not present" end
  return current.gpu_unified and "Unified" or "Present"
end

local function gpu_bar_label()
  if current.gpu_activity ~= nil then return percent(current.gpu_activity) end
  if current.gpu_caps_valid ~= true or current.gpu_present ~= true then return "—" end
  return current.gpu_unified and "UMA" or "GPU"
end

local function tool_links(host, token, name)
  popup.section(host, token, "tools_heading", "Open")
  if name == "ssd" then
    popup.link(host, token, "storage_settings", "System Settings · select General → Storage", function()
      shell.open(settings.links.storage)
    end)
    popup.link(host, token, "disk_utility", "Disk Utility", function()
      shell.exec({ "/usr/bin/open", "-b", settings.bundles.disk_utility })
    end)
  elseif name == "net" then
    popup.link(host, token, "network_settings", "System Settings · select Network", function()
      shell.open(settings.links.network)
    end)
    popup.link(host, token, "activity_monitor", "Activity Monitor", function()
      shell.exec({ "/usr/bin/open", "-b", settings.bundles.activity_monitor })
    end)
  elseif name == "tmp" then
    popup.link(host, token, "battery_settings", "System Settings · select Battery", function()
      shell.open(settings.links.battery)
    end)
    popup.link(host, token, "stats", "Stats", function()
      shell.exec({ "/usr/bin/open", "-b", settings.bundles.stats })
    end)
  else
    popup.link(host, token, "activity_monitor", "Activity Monitor", function()
      shell.exec({ "/usr/bin/open", "-b", settings.bundles.activity_monitor })
    end)
  end
end

local function graph(host, token, name, options)
  options = options or {}
  local values = histories[name]
  if name == "net" or name == "ssd" then
    values = {}
    for index, value in ipairs(histories[name]) do values[index] = normalize_net(value) end
  end
  popup.graph(host, token, "history_graph", values, values[#values] or 0, {
    color = options.color or definitions[name].color,
    fill_color = options.fill_color,
    height = 64,
    sample_id = current[name .. "_sequence"],
    reset_id = history_reset[name],
  })
end

local function percent_scale(host, token)
  popup.axis(host, token, "history_scale", "0%", "100%")
end

local core_levels = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local function core_glyph(value)
  value = bound(value, 0, 100) or 0
  return core_levels[math.min(#core_levels, math.floor(value * #core_levels / 100) + 1)]
end

local function core_rows(host, token)
  popup.section(host, token, "cores_heading", "Logical core utilization · neutral")
  local values = current.cpu_cores
  if type(values) ~= "table" or #values == 0 then
    popup.note(host, token, "cores_unavailable", "Per-core utilization unavailable")
    return
  end
  local minimum, maximum = 100, 0
  for _, value in ipairs(values) do minimum, maximum = math.min(minimum, value), math.max(maximum, value) end
  for first = 1, #values, 32 do
    local glyphs = {}
    for index = first, math.min(#values, first + 31) do glyphs[#glyphs + 1] = core_glyph(values[index]) end
    popup.note(host, token, "cores_" .. first, table.concat(glyphs), { color = colors.blue, align = "center" })
  end
  row(host, token, "core_range", "Core range", percent(minimum) .. " – " .. percent(maximum))
  row(host, token, "busiest_core", "Busiest core", percent(maximum))
end

local function build_metric(name, token)
  local host, definition = items[name], definitions[name]
  if not popup.is_current(host, token) then return end
  local heading = definition.title .. " DETAILS"
  if name == "tmp" then heading = "SYSTEM CONDITIONS" end
  local headline = name == "cpu" and percent(current.cpu_busy)
    or name == "gpu" and gpu_headline()
    or name == "ram" and percent(current.ram_percent)
    or name == "net" and ((current.net_rx and current.net_tx) and (bytes(current.net_rx + current.net_tx) .. "/s") or "—")
    or name == "ssd" and percent(current.ssd_percent)
    or (current.thermal_state and title_case(current.thermal_state) or "—")
  popup.header(host, token, heading, headline, {
    color = name == "tmp" and (thermal_color(current.thermal_state) or colors.primary) or colors.primary,
  })

  if name == "cpu" then
    popup.section(host, token, "hardware_heading", "Hardware telemetry · unsupported interfaces")
    hardware_freshness(host, token)
    row(host, token, "temperature", "Highest recognized sensor", temperature(current.cpu_temp))
    row(host, token, "frequency", "Weighted frequency", frequency(current.cpu_frequency))
    if current.cpu_efficiency_frequency ~= nil then row(host, token, "efficiency_frequency", "Efficiency cluster", frequency(current.cpu_efficiency_frequency)) end
    if current.cpu_performance_frequency ~= nil then row(host, token, "performance_frequency", "Performance cluster", frequency(current.cpu_performance_frequency)) end
    if current.cpu_super_frequency ~= nil then row(host, token, "super_frequency", "Super cluster", frequency(current.cpu_super_frequency)) end
    row(host, token, "power", "CPU power", watts(current.cpu_power))
    popup.section(host, token, "history_heading", "Recent utilization · up to 6 min")
    graph(host, token, "cpu", { color = colors.blue, fill_color = colors.blue_fill })
    percent_scale(host, token)
    popup.section(host, token, "breakdown_heading", "Breakdown")
    row(host, token, "system", "System", percent(current.cpu_system))
    row(host, token, "user", "User + nice",
      current.cpu_user ~= nil and current.cpu_nice ~= nil
        and percent(current.cpu_user + current.cpu_nice) or "—")
    row(host, token, "idle", "Idle", percent(current.cpu_idle))
    core_rows(host, token)
    popup.section(host, token, "load_heading", "Load average")
    row(host, token, "load1", "1 minute", current.cpu_load1 and string.format("%.2f", current.cpu_load1) or "—")
    row(host, token, "load5", "5 minutes", current.cpu_load5 and string.format("%.2f", current.cpu_load5) or "—")
    row(host, token, "load15", "15 minutes", current.cpu_load15 and string.format("%.2f", current.cpu_load15) or "—")
    popup.section(host, token, "detail_heading", "System")
    local processors = current.cpu_logical and current.cpu_active
      and string.format("%d / %d", current.cpu_active, current.cpu_logical) or "—"
    row(host, token, "processors", "Active / logical", processors)
    row(host, token, "uptime", "Uptime", uptime(current.uptime))
  elseif name == "gpu" then
    popup.section(host, token, "activity_heading", "Hardware telemetry · unsupported interfaces")
    hardware_freshness(host, token)
    graph(host, token, "gpu", { color = colors.domain.gpu, fill_color = colors.blue_fill })
    percent_scale(host, token)
    row(host, token, "activity", "Device utilization", percent(current.gpu_activity))
    if current.gpu_renderer ~= nil then row(host, token, "renderer", "Renderer utilization", percent(current.gpu_renderer)) end
    if current.gpu_tiler ~= nil then row(host, token, "tiler", "Tiler utilization", percent(current.gpu_tiler)) end
    row(host, token, "temperature", "Highest recognized sensor", temperature(current.gpu_temp))
    row(host, token, "power", "GPU power", watts(current.gpu_power))
    popup.section(host, token, "capabilities_heading", "Public capabilities")
    row(host, token, "present", "Metal device", current.gpu_caps_valid and yes_no(current.gpu_present) or "—")
    row(host, token, "unified", "Unified memory", yes_no(current.gpu_unified))
    row(host, token, "low_power", "Low-power", yes_no(current.gpu_low_power))
    row(host, token, "headless", "Headless", yes_no(current.gpu_headless))
    row(host, token, "removable", "Removable", yes_no(current.gpu_removable))
    row(host, token, "recommended", "Recommended working set", bytes(current.gpu_recommended))
  elseif name == "ram" then
    if current.pressure_state then
      popup.section(host, token, "pressure_heading", "Memory pressure")
      row(host, token, "pressure", "State", title_case(current.pressure_state), pressure_color(current.pressure_state))
    end
    popup.section(host, token, "history_heading", "Recent utilization · up to 6 min")
    graph(host, token, "ram", { color = colors.green, fill_color = colors.green_fill })
    percent_scale(host, token)
    popup.section(host, token, "memory_heading", "Memory")
    row(host, token, "used", "Used", bytes(current.mem_used))
    row(host, token, "available", "Available", bytes(current.mem_available))
    row(host, token, "total", "Physical", bytes(current.mem_total))
    row(host, token, "compressed", "Compressed", bytes(current.mem_compressed))
    row(host, token, "wired", "Wired", bytes(current.mem_wired))
    popup.section(host, token, "swap_heading", "Swap")
    row(host, token, "swap", "Used / total", bytes(current.swap_used) .. " / " .. bytes(current.swap_total), warning_color(current.swap_percent))
  elseif name == "net" then
    popup.section(host, token, "history_heading", "Recent combined throughput · log scale")
    graph(host, token, "net", { color = colors.cyan, fill_color = colors.cyan_fill })
    popup.axis(host, token, "history_scale", "0 B/s", "1 GB/s")
    popup.section(host, token, "traffic_heading", "Traffic")
    row(host, token, "download", "Download",
      current.net_rx ~= nil and bytes(current.net_rx) .. "/s" or "—")
    row(host, token, "upload", "Upload",
      current.net_tx ~= nil and bytes(current.net_tx) .. "/s" or "—")
    row(host, token, "combined", "Combined",
      current.net_rx ~= nil and current.net_tx ~= nil
        and bytes(current.net_rx + current.net_tx) .. "/s" or "—")
    popup.section(host, token, "session_heading", "Provider session")
    row(host, token, "session_download", "Provider session download", bytes(current.net_session_rx))
    row(host, token, "session_upload", "Provider session upload", bytes(current.net_session_tx))
    popup.note(host, token, "session_note", "Measured lower bounds · gaps are not inferred")
    popup.section(host, token, "path_heading", "Path")
    row(host, token, "route", "Connection", title_case(current.net_type) .. " · " .. title_case(current.net_state))
    row(host, token, "cost", "Cost", current.net_expensive == nil and "—" or (current.net_expensive and "Expensive" or "Standard"))
    row(host, token, "data_mode", "Data mode", current.net_constrained == nil and "—" or (current.net_constrained and "Constrained" or "Normal"))
  elseif name == "ssd" then
    local value = current.ssd_percent
    popup.meter(host, token, "meter", value or 0, warning_color(value) or colors.domain.ssd)
    popup.section(host, token, "io_heading", "Data backing device I/O")
    graph(host, token, "ssd", { color = colors.domain.ssd, fill_color = colors.blue_fill })
    popup.axis(host, token, "history_scale", "0 B/s", "1 GB/s")
    row(host, token, "read", "Read", current.ssd_read and bytes(current.ssd_read) .. "/s" or "—")
    row(host, token, "write", "Write", current.ssd_write and bytes(current.ssd_write) .. "/s" or "—")
    row(host, token, "combined", "Combined",
      current.ssd_read and current.ssd_write and bytes(current.ssd_read + current.ssd_write) .. "/s" or "—")
    popup.note(host, token, "io_note",
      "Shared APFS backing-target rates · invalid gaps are not inferred")
    popup.section(host, token, "capacity_heading", "Data volume capacity")
    row(host, token, "used", "Used", bytes(current.ssd_used), warning_color(value))
    row(host, token, "free", "Free", bytes(current.ssd_free), warning_color(value))
    row(host, token, "total", "Total", bytes(current.ssd_total))
    row(host, token, "available", "Available for use", bytes(current.ssd_important))
  else
    popup.section(host, token, "condition_heading", "System conditions")
    hardware_freshness(host, token)
    if current.thermal_state then
      row(host, token, "thermal", "Thermal state", title_case(current.thermal_state), thermal_color(current.thermal_state))
    end
    if current.pressure_state then
      row(host, token, "pressure", "Memory pressure", title_case(current.pressure_state), pressure_color(current.pressure_state))
    end
    row(host, token, "cpu_temperature", "Highest recognized CPU", temperature(current.cpu_temp))
    row(host, token, "gpu_temperature", "Highest recognized GPU", temperature(current.gpu_temp))
    popup.section(host, token, "power_heading", "Power")
    local mode = current.power_mode and title_case(current.power_mode.mode) or title_case(current.low_power_state)
    local source = current.power_mode and title_case(current.power_mode.source) or "—"
    row(host, token, "power_mode", "Mode", mode)
    row(host, token, "power_source", "Active source", source)
    row(host, token, "cpu_power", "CPU", watts(current.cpu_power))
    row(host, token, "gpu_power", "GPU", watts(current.gpu_power))
    row(host, token, "ram_power", "Memory", watts(current.ram_power))
    row(host, token, "ane_power", "Neural Engine", watts(current.ane_power))
    popup.section(host, token, "fans_heading", "Fans")
    if type(current.fans) ~= "table" or #current.fans == 0 then
      popup.note(host, token, "fans_unavailable", "Fan telemetry unavailable")
    else
      for _, fan in ipairs(current.fans) do
        row(host, token, "fan_" .. fan.index, "Fan " .. fan.index,
          rpm(fan.rpm) .. " · " .. title_case(fan.mode))
        row(host, token, "fan_" .. fan.index .. "_range", "Target / range",
          rpm(fan.target_rpm) .. " · " .. rpm(fan.min_rpm) .. "–" .. rpm(fan.max_rpm))
      end
    end
    if fan_power_control then fan_power_control:build(host, token, popup, colors) end
  end
  tool_links(host, token, name)
end

local function rebuild(name)
  local token = active[name]
  if token and popup.is_current(items[name], token) then
    popup.rebuild(items[name], token, function(current_token) build_metric(name, current_token) end)
  end
end

fan_power_control = fan_power.new({
  run = function(arguments, callback)
    local command = { settings.config_dir .. "/scripts/fan-power-client.sh" }
    for _, argument in ipairs(arguments) do command[#command + 1] = argument end
    shell.exec(command, callback)
  end,
  changed = function() rebuild("tmp") end,
  recovery = function()
    shell.open(settings.config_dir .. "/privileged/fan-power-owner/README.md")
  end,
})

local function make_item(name)
  local definition = definitions[name]
  local width = name == "tmp" and settings.right_layout.tmp_width or settings.right_layout.stat_width
  local item = sbar.add("item", name, {
    position = "right", width = width,
    padding_left = settings.spacing.item / 2,
    padding_right = settings.spacing.item / 2,
    icon = { string = definition.icon, color = definition.color, width = 18, align = "center", padding_left = 0, padding_right = settings.spacing.icon_label / 2, font = settings.type.bar_icon },
    label = { string = "—", color = colors.primary, width = width - 18, align = "center", padding_left = settings.spacing.icon_label / 2, padding_right = 0, font = settings.type.bar_value },
    background = { drawing = false },
  })
  items[name] = item
  if name == "tmp" then item:set({ updates = true, update_freq = 5 }) end
  hover.bind(item, { idle_color = definition.color })
  popup.bind(item, {
    align = "right",
    right_click = function()
      if name == "ssd" then shell.exec({ "/usr/bin/open", "-b", settings.bundles.disk_utility })
      else shell.exec({ "/usr/bin/open", "-b", settings.bundles.activity_monitor }) end
    end,
    on_close = function()
      active[name] = nil
      if name == "tmp" then fan_power_control:closed() end
      if update_hardware_cadence then update_hardware_cadence() end
    end,
    build = function(token)
      active[name] = token
      if update_hardware_cadence then update_hardware_cadence() end
      build_metric(name, token)
    end,
  })
  return item
end

for index = #order, 1, -1 do make_item(order[index]) end

local function bar_percent(value)
  value = bound(value, 0, 100)
  return value and string.format("%.0f%%", value) or "—"
end

local function compact_rate(value)
  value = finite(value, 0)
  if not value then return "—" end
  if value < 1000 then return string.format("%.0fB", value) end
  value = value / 1000
  if value < 10 then return string.format("%.1fK", value) end
  if value < 1000 then return string.format("%.0fK", value) end
  value = value / 1000
  if value < 10 then return string.format("%.1fM", value) end
  if value < 1000 then return string.format("%.0fM", value) end
  return string.format("%.1fG", value / 1000)
end

render_all = function()
  items.cpu:set({ label = { string = bar_percent(current.cpu_busy), color = warning_color(current.cpu_busy) or colors.primary } })
  items.gpu:set({ label = { string = gpu_bar_label(), color = warning_color(current.gpu_activity) or colors.primary } })
  items.ram:set({ label = { string = bar_percent(current.ram_percent), color = warning_color(current.ram_percent) or colors.primary } })
  local net_total = current.net_rx and current.net_tx and current.net_rx + current.net_tx or nil
  items.net:set({ label = { string = compact_rate(net_total), color = colors.primary } })
  items.ssd:set({ label = { string = bar_percent(current.ssd_percent), color = warning_color(current.ssd_percent) or colors.primary } })
  local cpu_temp = finite(current.cpu_temp, 0, 130)
  local gpu_temp = finite(current.gpu_temp, 0, 130)
  local thermal_label = string.format("C%s G%s",
    cpu_temp and string.format("%.0f", cpu_temp) or "—",
    gpu_temp and string.format("%.0f", gpu_temp) or "—")
  local cpu_warning = cpu_temp and warning_color(100 * cpu_temp / 105) or nil
  local gpu_warning = gpu_temp and warning_color(100 * gpu_temp / 105) or nil
  local thermal_warning = (cpu_warning == colors.red or gpu_warning == colors.red) and colors.red
    or cpu_warning or gpu_warning
  local thermal_font = ((cpu_temp and cpu_temp >= 99.5) or (gpu_temp and gpu_temp >= 99.5))
    and settings.type.bar_value_compact or settings.type.bar_value
  items.tmp:set({ label = {
    string = thermal_label, color = thermal_warning or colors.primary, font = thermal_font,
  } })
end

local hardware_state = nil
local hardware_success_at = nil
local hardware_stale = false
local hardware_sample_sequence = 0
local hardware_expiry_generation = 0
local hardware_stale_after = 20
local function apply_hardware()
  local value = hardware_state
  current.hardware_stale = hardware_stale
  current.gpu_sequence = hardware_sample_sequence > 0 and hardware_sample_sequence or nil
  current.cpu_temp = value and value.temperatures.cpu_temp_c or nil
  current.gpu_temp = value and value.temperatures.gpu_temp_c or nil
  current.fans = value and value.fans or nil
  current.gpu_activity = value and value.gpu.utilization_pct or nil
  current.gpu_renderer = value and value.gpu.renderer_pct or nil
  current.gpu_tiler = value and value.gpu.tiler_pct or nil
  current.cpu_power = value and value.power.cpu_w or nil
  current.gpu_power = value and value.power.gpu_w or nil
  current.ane_power = value and value.power.ane_w or nil
  current.ram_power = value and value.power.ram_w or nil
  current.cpu_frequency = value and value.frequency.average_mhz or nil
  current.cpu_efficiency_frequency = value and value.frequency.efficiency_mhz or nil
  current.cpu_performance_frequency = value and value.frequency.performance_mhz or nil
  current.cpu_super_frequency = value and value.frequency.super_mhz or nil
  current.power_mode = value and value.power_mode or nil
end

local function schedule_hardware_expiry()
  hardware_expiry_generation = hardware_expiry_generation + 1
  local generation = hardware_expiry_generation
  sbar.delay(hardware_stale_after, function()
    if generation ~= hardware_expiry_generation then return end
    hardware_expiry_generation = hardware_expiry_generation + 1
    hardware_state, hardware_success_at, hardware_stale = nil, nil, false
    apply_hardware()
    reset_history("gpu")
    update_hardware_cadence()
    render_all()
    rebuild("cpu")
    rebuild("gpu")
    rebuild("tmp")
  end)
end

local function accept_metrics(env)
  local accepted = stats_contract.accept(cursor, env, os.time())
  if not accepted then return end
  if accepted.reset then
    clear_histories()
    current = {}
    apply_hardware()
  end
  current.sequence = accepted.sequence
  local sampled = { gpu = true }

  if env.CPU_SAMPLED == "1" then
    sampled.cpu = true
    current.cpu_sequence = accepted.sequence
    current.cpu_busy = env.CPU_VALID == "1" and finite(env.CPU_BUSY_PCT, 0, 100) or nil
    current.cpu_user = env.CPU_VALID == "1" and finite(env.CPU_USER_PCT, 0, 100) or nil
    current.cpu_nice = env.CPU_VALID == "1" and finite(env.CPU_NICE_PCT, 0, 100) or nil
    current.cpu_system = env.CPU_VALID == "1" and finite(env.CPU_SYSTEM_PCT, 0, 100) or nil
    current.cpu_idle = env.CPU_VALID == "1" and finite(env.CPU_IDLE_PCT, 0, 100) or nil
    current.cpu_load1 = finite(env.CPU_LOAD1, 0)
    current.cpu_load5 = finite(env.CPU_LOAD5, 0)
    current.cpu_load15 = finite(env.CPU_LOAD15, 0)
    current.cpu_logical = finite(env.CPU_LOGICAL, 1)
    current.cpu_active = finite(env.CPU_ACTIVE, 1)
    if current.cpu_busy then append("cpu", current.cpu_busy) else reset_history("cpu") end
  end

  if env.MEM_SAMPLED == "1" then
    sampled.ram = true
    current.ram_sequence = accepted.sequence
    current.mem_total = env.MEM_VALID == "1" and finite(env.MEM_TOTAL_B, 0) or nil
    current.mem_used = env.MEM_VALID == "1" and finite(env.MEM_USED_B, 0) or nil
    current.mem_available = env.MEM_VALID == "1" and finite(env.MEM_AVAILABLE_B, 0) or nil
    current.mem_compressed = env.MEM_VALID == "1" and finite(env.MEM_COMPRESSED_B, 0) or nil
    current.mem_wired = env.MEM_VALID == "1" and finite(env.MEM_WIRED_B, 0) or nil
    current.ram_percent = current.mem_total and current.mem_total > 0 and 100 * current.mem_used / current.mem_total or nil
    current.swap_total = env.SWAP_VALID == "1" and finite(env.SWAP_TOTAL_B, 0) or nil
    current.swap_used = env.SWAP_VALID == "1" and finite(env.SWAP_USED_B, 0) or nil
    current.swap_percent = current.swap_total and current.swap_total > 0 and 100 * current.swap_used / current.swap_total or nil
    if current.ram_percent then append("ram", current.ram_percent) else reset_history("ram") end
  end

  if env.NET_SAMPLED == "1" then
    sampled.net = true
    current.net_sequence = accepted.sequence
    current.net_rx = env.NET_VALID == "1" and finite(env.NET_RX_BPS, 0) or nil
    current.net_tx = env.NET_VALID == "1" and finite(env.NET_TX_BPS, 0) or nil
    current.net_state = env.NET_STATE
    current.net_type = env.NET_PATH_TYPE
    current.net_session_rx = env.NET_SESSION_VALID == "1" and finite(env.NET_SESSION_RX_B, 0) or nil
    current.net_session_tx = env.NET_SESSION_VALID == "1" and finite(env.NET_SESSION_TX_B, 0) or nil
    current.net_expensive = env.NET_EXPENSIVE == "1"
    current.net_constrained = env.NET_CONSTRAINED == "1"
    if current.net_rx and current.net_tx then append("net", current.net_rx + current.net_tx) else reset_history("net") end
  end

  if env.SSD_SAMPLED == "1" then
    sampled.ssd = true
    current.ssd_sequence = accepted.sequence
    current.ssd_total = env.SSD_VALID == "1" and finite(env.SSD_TOTAL_B, 0) or nil
    current.ssd_used = env.SSD_VALID == "1" and finite(env.SSD_USED_B, 0) or nil
    current.ssd_free = env.SSD_VALID == "1" and finite(env.SSD_FREE_B, 0) or nil
    current.ssd_percent = env.SSD_VALID == "1" and finite(env.SSD_USED_PCT, 0, 100) or nil
    current.ssd_important = env.SSD_IMPORTANT_AVAILABLE_VALID == "1" and finite(env.SSD_IMPORTANT_AVAILABLE_B, 0) or nil
  end

  if env.SSD_IO_SAMPLED == "1" then
    sampled.ssd = true
    current.ssd_sequence = accepted.sequence
    current.ssd_read = env.SSD_IO_VALID == "1" and finite(env.SSD_READ_BPS, 0) or nil
    current.ssd_write = env.SSD_IO_VALID == "1" and finite(env.SSD_WRITE_BPS, 0) or nil
    if current.ssd_read and current.ssd_write then append("ssd", current.ssd_read + current.ssd_write)
    else reset_history("ssd") end
  end

  if env.CONDITION_SAMPLED == "1" then
    sampled.tmp, sampled.ram = true, true
    current.tmp_sequence = accepted.sequence
    current.thermal_state = env.THERMAL_VALID == "1" and env.THERMAL_STATE or nil
    current.pressure_state = env.PRESSURE_VALID == "1" and env.PRESSURE_STATE or nil
    current.low_power_state = env.LOW_POWER_STATE
  end

  local caps_valid = env.GPU_CAPS_VALID == "1"
  local present = caps_valid and env.GPU_PRESENT == "1"
  current.gpu_caps_valid = caps_valid
  if caps_valid then current.gpu_present = present else current.gpu_present = nil end
  if present then
    current.gpu_unified = env.GPU_UNIFIED == "1"
    current.gpu_low_power = env.GPU_LOW_POWER == "1"
    current.gpu_removable = env.GPU_REMOVABLE == "1"
    current.gpu_headless = env.GPU_HEADLESS == "1"
    current.gpu_recommended = finite(env.GPU_RECOMMENDED_MAX_B, 0)
  else
    current.gpu_unified = nil
    current.gpu_low_power = nil
    current.gpu_removable = nil
    current.gpu_headless = nil
    current.gpu_recommended = nil
  end
  render_all()
  for name in pairs(sampled) do rebuild(name) end
end

local function accept_cpu_detail(env)
  local accepted = stats_contract.accept_cpu_detail(cursor, env, os.time())
  if not accepted then return end
  if accepted.reset then
    clear_histories()
    current = {}
    apply_hardware()
  end
  current.cpu_detail_sequence = accepted.sequence
  current.cpu_cores = accepted.cores
  current.uptime = accepted.uptime
  render_all()
  rebuild("cpu")
end

update_hardware_cadence = function()
  local visible = active.cpu ~= nil or active.gpu ~= nil or active.tmp ~= nil
  local reduced = current.power_mode and (current.power_mode.source == "battery" or current.power_mode.mode == "low")
  items.tmp:set({ update_freq = visible and 2 or reduced and 15 or 5 })
end

local hardware_in_flight = false
local function refresh_hardware()
  if hardware_in_flight then return end
  hardware_in_flight = true
  shell.exec({ settings.config_dir .. "/scripts/hardware-state.py" }, function(output, exit_code)
    hardware_in_flight = false
    local value = exit_code == 0 and hardware_contract.validate(output) or nil
    local now = os.time()
    if value then
      hardware_sample_sequence = hardware_sample_sequence + 1
      hardware_state, hardware_success_at, hardware_stale = value, now, false
      schedule_hardware_expiry()
    elseif hardware_state and hardware_success_at and now >= hardware_success_at
        and now - hardware_success_at <= hardware_stale_after then
      hardware_stale = true
    else
      hardware_expiry_generation = hardware_expiry_generation + 1
      hardware_state, hardware_success_at, hardware_stale = nil, nil, false
    end
    apply_hardware()
    update_hardware_cadence()
    if value and current.gpu_activity then append("gpu", current.gpu_activity)
    elseif not hardware_stale then reset_history("gpu") end
    render_all()
    rebuild("cpu")
    rebuild("gpu")
    rebuild("tmp")
  end)
end

sbar.add("event", "system_cpu_detail_v1")
items.cpu:subscribe("system_metrics_v3", accept_metrics)
items.cpu:subscribe("system_cpu_detail_v1", accept_cpu_detail)
items.tmp:subscribe({ "routine", "system_woke" }, refresh_hardware)
render_all()
refresh_hardware()
