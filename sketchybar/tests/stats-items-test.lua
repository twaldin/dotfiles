package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local objects, executions = {}, {}
local delayed = {}
local clock = os.time()
os.time = function() return clock end
local hardware_callback = nil

local function hardware_sample(cpu_temp, gpu_temp)
  return {
    schema = "hardware_state_v1", smc_available = true, native_available = true,
    temperatures = {
      cpu_temp_c = cpu_temp, cpu_sensor_count = cpu_temp and 8 or 0,
      gpu_temp_c = gpu_temp, gpu_sensor_count = gpu_temp and 4 or 0,
    },
    fans = { { index = 1, rpm = 2500, min_rpm = 2000, max_rpm = 7000, target_rpm = 2500, mode = "automatic" } },
    gpu = { utilization_pct = 31, renderer_pct = 29, tiler_pct = 20 },
    power = { cpu_w = 12, gpu_w = 3, ane_w = 0, ram_w = 1.5 },
    frequency = { average_mhz = 2600, efficiency_mhz = 1500, performance_mhz = 3600 },
    power_mode = { source = "ac", mode = "high", supported = { "automatic", "low", "high" } },
  }
end

local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then target[key] = target[key] or {}; merge(target[key], value)
    else target[key] = value end
  end
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function add(kind, name, properties_or_width, properties)
  local initial = copy(properties or properties_or_width)
  if type(initial) ~= "table" then initial = {} end
  local object = { kind = kind, name = name, properties = initial, subscriptions = {} }
  function object:set(update) merge(object.properties, update) end
  function object:push(values) object.values = values end
  function object:subscribe(events, callback)
    if type(events) ~= "table" then events = { events } end
    for _, event in ipairs(events) do
      object.subscriptions[event] = object.subscriptions[event] or {}
      object.subscriptions[event][#object.subscriptions[event] + 1] = callback
    end
  end
  objects[name] = object
  return object
end

sbar = {
  add = add,
  remove = function(target)
    if type(target) == "table" then objects[target.name] = nil; return end
    for name in pairs(objects) do if name:match(target) then objects[name] = nil end end
  end,
  exec = function(command, callback)
    executions[#executions + 1] = command
    if callback and tostring(command):find("hardware%-state%.py") then
      hardware_callback = callback
      callback(hardware_sample(73, 61), 0)
    elseif callback then callback("", 1) end
  end,
  delay = function(seconds, callback)
    if seconds == 20 then delayed[#delayed + 1] = callback else callback() end
  end,
  animate = function(_, _, callback) callback() end,
}

require("items.status")
local function check(value, message) if not value then error(message, 0) end end
local function fire(object, event, env)
  for _, callback in ipairs(object.subscriptions[event] or {}) do callback(env or {}) end
end
local names = { "cpu", "gpu", "ram", "net", "ssd", "tmp" }
local item_count = 0
for _, object in pairs(objects) do if object.kind == "item" and not object.name:match("^popup%.") then item_count = item_count + 1 end end
check(item_count == 6, "status must contain exactly six bar items")
for _, name in ipairs(names) do
  local item = objects[name]
  check(item ~= nil and item.kind == "item", "missing stat item " .. name)
  check(item.properties.background.drawing == false, name .. " idle background must be hidden")
  check(item.properties.width == (name == "tmp" and 72 or 48), name .. " fixed width changed")
  check(item.subscriptions["mouse.clicked"] and #item.subscriptions["mouse.clicked"] > 0, name .. " must be clickable")
end
check(objects.status == nil, "unified status item must not exist")
check(objects.system_cpu_detail_v1 and objects.system_cpu_detail_v1.kind == "event",
  "CPU detail event must be registered")
check(objects.cpu.subscriptions.system_cpu_detail_v1, "CPU item must consume CPU detail events")
check(objects.tmp.properties.update_freq == 5, "hardware telemetry must use the active AC cadence")

local fixture = require("tests.stats-fixture")
local colors = require("colors")
fire(objects.cpu, "system_metrics_v3", fixture.metrics())
fire(objects.cpu, "system_cpu_detail_v1", fixture.cpu_detail())
fire(objects.ssd, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.ssd.read"] and objects["popup.ssd.read"].properties.label.string == "40.0 KB/s",
  "SSD popup is missing the Data backing-device read rate")
check(objects["popup.ssd.write"] and objects["popup.ssd.write"].properties.label.string == "10.0 KB/s",
  "SSD popup is missing the Data backing-device write rate")
check(objects["popup.ssd.combined"] and objects["popup.ssd.combined"].properties.label.string == "50.0 KB/s",
  "SSD popup is missing the combined backing-device rate")
check(objects["popup.ssd.io_note"] and objects["popup.ssd.io_note"].properties.label.string:find("Shared APFS backing%-target rates"),
  "SSD popup overclaims APFS Data-volume attribution")
check(objects["popup.ssd.used"] and objects["popup.ssd.free"] and objects["popup.ssd.total"],
  "SSD popup lost Data-volume capacity rows")
fire(objects.ssd, "mouse.clicked", { BUTTON = "left" })
local replay = fixture.metrics("00000000000000000001")
replay.CPU_BUSY_PCT, replay.CPU_USER_PCT, replay.CPU_SYSTEM_PCT, replay.CPU_IDLE_PCT = "80", "40", "40", "20"
fire(objects.cpu, "system_metrics_v3", replay)
check(objects.cpu.properties.label.string == "24%", "replayed metric mutated the UI")
local invalid = fixture.metrics("00000000000000000002")
invalid.CPU_BUSY_PCT = "99"
fire(objects.cpu, "system_metrics_v3", invalid)
check(objects.cpu.properties.label.string == "24%", "invalid metric relation mutated the UI")
local partial = fixture.metrics("00000000000000000002")
partial.SSD_SAMPLED, partial.SSD_VALID = "0", "0"
partial.SSD_TOTAL_B, partial.SSD_FREE_B, partial.SSD_USED_B, partial.SSD_USED_PCT = "0", "0", "0", "0"
partial.SSD_IMPORTANT_AVAILABLE_VALID, partial.SSD_IMPORTANT_AVAILABLE_B = "0", "0"
partial.SSD_IO_SAMPLED, partial.SSD_IO_VALID = "1", "0"
partial.SSD_READ_BPS, partial.SSD_WRITE_BPS = "0", "0"
partial.CONDITION_SAMPLED, partial.THERMAL_VALID, partial.PRESSURE_VALID = "0", "0", "0"
partial.THERMAL_STATE, partial.PRESSURE_STATE, partial.LOW_POWER_STATE = "unknown", "unknown", "off_or_unsupported"
fire(objects.cpu, "system_metrics_v3", partial)
check(objects.ssd.properties.label.string == "50%", "unsampled SSD event cleared accepted state")
fire(objects.ssd, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.ssd.read"].properties.label.string == "—"
      and objects["popup.ssd.write"].properties.label.string == "—",
  "invalid SSD I/O sample left stale rates")
local ssd_cleared = true
for _, point in ipairs(objects["popup.ssd.history_graph"].values) do
  if point ~= 0 then ssd_cleared = false end
end
check(ssd_cleared, "invalid SSD I/O sample did not clear the rate history")
fire(objects.ssd, "mouse.clicked", { BUTTON = "left" })
check(objects.tmp.properties.label.string == "C73 G61", "unsampled condition event cleared accepted hardware temperatures")
check(objects.cpu.properties.label.string == "24%", "CPU payload did not render")
check(objects.gpu.properties.label.string == "31%", "GPU activity did not render")
check(objects.ram.properties.label.string == "50%", "RAM payload did not render")
check(objects.ssd.properties.label.string == "50%", "SSD payload did not render")
check(objects.tmp.properties.label.string == "C73 G61", "separate CPU/GPU temperatures did not render in fixed order")
for _, command in ipairs(executions) do
  check(not tostring(command):find("gpu%-usage%.py"), "GPU percent helper must not execute")
end

fire(objects.cpu, "mouse.clicked", { BUTTON = "left" })
check(objects.tmp.properties.update_freq == 2, "visible hardware popup must use the foreground cadence")
check(objects["popup.cpu.cores_1"] ~= nil, "CPU popup is missing generic per-core bars")
check(objects["popup.cpu.uptime"] and objects["popup.cpu.uptime"].properties.label.string == "1d 1h 1m",
  "CPU popup is missing provider uptime")
local cpu_text = ""
for name, object in pairs(objects) do
  if name:match("^popup%.cpu%.") then
    cpu_text = cpu_text .. " " .. tostring(object.properties.icon and object.properties.icon.string or "")
      .. " " .. tostring(object.properties.label and object.properties.label.string or "")
  end
end
check(cpu_text:find("Highest recognized sensor") and cpu_text:find("Weighted frequency"),
  "CPU hardware telemetry is missing")

local lower_session = fixture.metrics("00000000000000000003")
lower_session.NET_SESSION_RX_B = "1199999"
lower_session.CPU_BUSY_PCT, lower_session.CPU_USER_PCT = "80", "40"
lower_session.CPU_SYSTEM_PCT, lower_session.CPU_IDLE_PCT = "40", "20"
fire(objects.cpu, "system_metrics_v3", lower_session)
check(objects.cpu.properties.label.string == "24%",
  "lower provider-session total mutated the UI")
local factual_false = fixture.metrics("00000000000000000003")
factual_false.GPU_UNIFIED, factual_false.GPU_LOW_POWER = "0", "0"
factual_false.GPU_REMOVABLE, factual_false.GPU_HEADLESS = "0", "0"
fire(objects.cpu, "system_metrics_v3", factual_false)
check(objects.gpu.properties.label.string == "31%", "GPU activity was replaced by a capability label")
fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })
for _, suffix in ipairs({ "unified", "low_power", "removable", "headless" }) do
  local row = objects["popup.gpu." .. suffix]
  check(row and row.properties.label.string == "No", "factual false GPU capability did not render No: " .. suffix)
end
fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })

local absent = fixture.metrics("00000000000000000004")
absent.GPU_PRESENT, absent.GPU_UNIFIED, absent.GPU_LOW_POWER = "0", "0", "0"
absent.GPU_REMOVABLE, absent.GPU_HEADLESS, absent.GPU_RECOMMENDED_MAX_B = "0", "0", "0"
fire(objects.cpu, "system_metrics_v3", absent)
check(objects.gpu.properties.label.string == "31%", "independent GPU activity probe was discarded")
fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.gpu.present"] and objects["popup.gpu.present"].properties.label.string == "No",
  "valid GPU absence must remain distinct from unavailable capabilities")
check(objects["popup.gpu.history_graph"] ~= nil, "GPU popup is missing measured activity history")
check(objects["popup.gpu.activity"] and objects["popup.gpu.activity"].properties.label.string == "31%",
  "GPU popup is missing measured utilization")
local unavailable = fixture.metrics("00000000000000000005")
unavailable.GPU_CAPS_VALID, unavailable.GPU_PRESENT, unavailable.GPU_UNIFIED = "0", "0", "0"
unavailable.GPU_LOW_POWER, unavailable.GPU_REMOVABLE, unavailable.GPU_HEADLESS = "0", "0", "0"
unavailable.GPU_RECOMMENDED_MAX_B = "0"
fire(objects.cpu, "system_metrics_v3", unavailable)
check(objects["popup.gpu.present"].properties.label.string == "—",
  "unavailable GPU capabilities must not render as absent")
fire(objects.tmp, "mouse.clicked", { BUTTON = "left" })
local power_row = objects["popup.tmp.power_mode"]
check(power_row and power_row.properties.label.string == "High",
  "TMP popup is missing the active power mode")
check(power_row.properties.label.color == colors.primary,
  "TMP power mode lost the shared visible color")
check(objects["popup.tmp.fan_1"] and objects["popup.tmp.fan_1"].properties.label.string:find("2500 RPM"),
  "TMP popup is missing fan telemetry")
local unavailable_metrics = fixture.metrics("00000000000000000006")
unavailable_metrics.CPU_VALID = "0"
unavailable_metrics.CPU_BUSY_PCT, unavailable_metrics.CPU_USER_PCT = "0", "0"
unavailable_metrics.CPU_SYSTEM_PCT, unavailable_metrics.CPU_IDLE_PCT = "0", "0"
unavailable_metrics.NET_VALID = "0"
unavailable_metrics.NET_RX_BPS, unavailable_metrics.NET_TX_BPS = "0", "0"
unavailable_metrics.THERMAL_VALID, unavailable_metrics.PRESSURE_VALID = "0", "0"
unavailable_metrics.THERMAL_STATE, unavailable_metrics.PRESSURE_STATE = "unknown", "unknown"
fire(objects.cpu, "system_metrics_v3", unavailable_metrics)
check(objects["popup.tmp.thermal"].properties.drawing == false
      and objects["popup.tmp.pressure"].properties.drawing == false,
  "invalid system conditions must be omitted from the TMP popup")
fire(objects.ram, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.ram.pressure_heading"] == nil and objects["popup.ram.pressure"] == nil,
  "invalid memory pressure must be omitted from the RAM popup")
fire(objects.ram, "mouse.clicked", { BUTTON = "left" })
fire(objects.cpu, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.cpu.user"] and objects["popup.cpu.user"].properties.label.string == "—",
  "unavailable CPU user and nice values must not fabricate zero")
fire(objects.net, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.net.combined"] and objects["popup.net.combined"].properties.label.string == "—",
  "unavailable combined network traffic must not fabricate zero")
check(objects["popup.net.download"] and objects["popup.net.download"].properties.label.string == "—",
  "unavailable download traffic must not render a malformed rate")
check(objects["popup.net.upload"] and objects["popup.net.upload"].properties.label.string == "—",
  "unavailable upload traffic must not render a malformed rate")
check(objects["popup.net.session_download"]
      and objects["popup.net.session_download"].properties.icon.string == "Provider session download"
      and not objects["popup.net.session_download"].properties.label.string:find("/s", 1, true),
  "provider-session download row has rate units or the wrong label")
check(objects["popup.net.session_upload"]
      and objects["popup.net.session_upload"].properties.icon.string == "Provider session upload"
      and not objects["popup.net.session_upload"].properties.label.string:find("/s", 1, true),
  "provider-session upload row has rate units or the wrong label")
check(objects["popup.net.session_note"].properties.label.string:find("gaps are not inferred", 1, true),
  "provider-session lower-bound note is missing")

fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })
local measured_gpu_graph_points = #objects["popup.gpu.history_graph"].values
hardware_callback("", 1)
check(objects.gpu.properties.label.string == "31%" and objects.tmp.properties.label.string == "C73 G61",
  "one transient hardware failure erased the separate recent temperature sample")
check(#objects["popup.gpu.history_graph"].values == measured_gpu_graph_points,
  "a stale GPU value was fabricated as a fresh history sample")
fire(objects.tmp, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.tmp.hardware_stale"]
      and objects["popup.tmp.hardware_stale"].properties.label.string == "Refresh delayed · showing a recent sample",
  "transient hardware failure is not rendered as a delayed recent sample")
clock = clock + 21
check(#delayed == 1, "fresh hardware sample did not schedule one bounded expiry")
delayed[1]()
check(objects.gpu.properties.label.string ~= "31%" and objects.tmp.properties.label.string == "C— G—",
  "hardware temperatures did not become explicit source-absent labels after expiry")
hardware_callback("", 1)
check(objects.gpu.properties.label.string ~= "31%" and objects.tmp.properties.label.string == "C— G—",
  "a failure after expiry restored old hardware temperatures")
hardware_callback(hardware_sample(nil, 61), 0)
check(objects.tmp.properties.label.string == "C— G61",
  "a recognized GPU temperature did not stay separate from an absent CPU source")
hardware_callback(hardware_sample(73, nil), 0)
check(objects.tmp.properties.label.string == "C73 G—",
  "a recognized CPU temperature did not stay separate from an absent GPU source")
hardware_callback(hardware_sample(100, 130), 0)
check(objects.tmp.properties.label.string == "C100 G130",
  "three-digit temperatures did not remain separate and complete")
check(objects.tmp.properties.label.font.size == 9.5,
  "three-digit temperature pair did not use the certified compact face")
hardware_callback(hardware_sample(nil, nil), 0)
check(objects.tmp.properties.label.string == "C— G—",
  "complete temperature absence did not use explicit CPU/GPU em dashes")
check(objects.tmp.properties.label.font.size == 12.0,
  "source-absent labels did not restore the normal bar value face")
local replacement = fixture.metrics("00000000000000000001")
replacement.PRODUCER_INSTANCE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
replacement.NET_SESSION_RX_B, replacement.NET_SESSION_TX_B = "0", "0"
fire(objects.cpu, "system_metrics_v3", replacement)
fire(objects.net, "mouse.clicked", { BUTTON = "left" })
check(#objects["popup.net.history_graph"].values > 1,
  "new producer did not clear and restart the network history")
fire(objects.ssd, "mouse.clicked", { BUTTON = "left" })
check(#objects["popup.ssd.history_graph"].values > 1,
  "new producer did not clear and restart the SSD I/O history")
fire(objects.ssd, "mouse.clicked", { BUTTON = "left" })
print("Six stats items and separate CPU/GPU hardware temperatures passed")
