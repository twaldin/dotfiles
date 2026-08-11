package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local objects, executions = {}, {}

local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then target[key] = target[key] or {}; merge(target[key], value)
    else target[key] = value end
  end
end

local function add(kind, name, properties_or_width, properties)
  local initial = properties or properties_or_width
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
    if callback then callback("", 1) end
  end,
  delay = function(_, callback) callback() end,
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
  check(item.subscriptions["mouse.clicked"] and #item.subscriptions["mouse.clicked"] > 0, name .. " must be clickable")
end
check(objects.status == nil, "unified status item must not exist")
check(objects.system_cpu_detail_v1 and objects.system_cpu_detail_v1.kind == "event",
  "CPU detail event must be registered")
check(objects.cpu.subscriptions.system_cpu_detail_v1, "CPU item must consume CPU detail events")

local fixture = require("tests.stats-fixture")
local colors = require("colors")
fire(objects.cpu, "system_metrics_v2", fixture.metrics())
fire(objects.cpu, "system_cpu_detail_v1", fixture.cpu_detail())
local replay = fixture.metrics("00000000000000000001")
replay.CPU_BUSY_PCT, replay.CPU_USER_PCT, replay.CPU_SYSTEM_PCT, replay.CPU_IDLE_PCT = "80", "40", "40", "20"
fire(objects.cpu, "system_metrics_v2", replay)
check(objects.cpu.properties.label.string == "24%", "replayed metric mutated the UI")
local invalid = fixture.metrics("00000000000000000002")
invalid.CPU_BUSY_PCT = "99"
fire(objects.cpu, "system_metrics_v2", invalid)
check(objects.cpu.properties.label.string == "24%", "invalid metric relation mutated the UI")
local partial = fixture.metrics("00000000000000000002")
partial.SSD_SAMPLED, partial.SSD_VALID = "0", "0"
partial.SSD_TOTAL_B, partial.SSD_FREE_B, partial.SSD_USED_B, partial.SSD_USED_PCT = "0", "0", "0", "0"
partial.SSD_IMPORTANT_AVAILABLE_VALID, partial.SSD_IMPORTANT_AVAILABLE_B = "0", "0"
partial.CONDITION_SAMPLED, partial.THERMAL_VALID, partial.PRESSURE_VALID = "0", "0", "0"
partial.THERMAL_STATE, partial.PRESSURE_STATE, partial.LOW_POWER_STATE = "unknown", "unknown", "off_or_unsupported"
fire(objects.cpu, "system_metrics_v2", partial)
check(objects.ssd.properties.label.string == "50%", "unsampled SSD event cleared accepted state")
check(objects.tmp.properties.label.string == "OK", "unsampled condition event cleared accepted state")
check(objects.cpu.properties.label.string == "24%", "CPU payload did not render")
check(objects.gpu.properties.label.string == "UMA", "GPU capability did not render honestly")
check(objects.ram.properties.label.string == "50%", "RAM payload did not render")
check(objects.ssd.properties.label.string == "50%", "SSD payload did not render")
check(objects.tmp.properties.label.string == "OK", "thermal payload did not render")
for _, command in ipairs(executions) do
  check(not tostring(command):find("gpu%-usage%.py"), "GPU percent helper must not execute")
end

fire(objects.cpu, "mouse.clicked", { BUTTON = "left" })
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
check(not cpu_text:find("Performance") and not cpu_text:find("Efficiency"),
  "generic core bars must not claim performance or efficiency topology")

local factual_false = fixture.metrics("00000000000000000003")
factual_false.GPU_UNIFIED, factual_false.GPU_LOW_POWER = "0", "0"
factual_false.GPU_REMOVABLE, factual_false.GPU_HEADLESS = "0", "0"
fire(objects.cpu, "system_metrics_v2", factual_false)
check(objects.gpu.properties.label.string == "GPU", "factual non-unified GPU rendered unavailable")
fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })
for _, suffix in ipairs({ "unified", "low_power", "removable", "headless" }) do
  local row = objects["popup.gpu." .. suffix]
  check(row and row.properties.label.string == "No", "factual false GPU capability did not render No: " .. suffix)
end
fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })

local absent = fixture.metrics("00000000000000000004")
absent.GPU_PRESENT, absent.GPU_UNIFIED, absent.GPU_LOW_POWER = "0", "0", "0"
absent.GPU_REMOVABLE, absent.GPU_HEADLESS, absent.GPU_RECOMMENDED_MAX_B = "0", "0", "0"
fire(objects.cpu, "system_metrics_v2", absent)
check(objects.gpu.properties.label.string == "—", "absent GPU must not render as activity")
fire(objects.gpu, "mouse.clicked", { BUTTON = "left" })
check(objects["popup.gpu.present"] and objects["popup.gpu.present"].properties.label.string == "No",
  "valid GPU absence must remain distinct from unavailable capabilities")
check(objects["popup.gpu.activity_note"] ~= nil, "GPU popup must explain public activity limits")
check(objects["popup.gpu.history_graph"] == nil, "GPU popup must not show a fake activity graph")
check(objects["popup.gpu.usage"] == nil, "GPU popup must not show a fake activity percent")
local unavailable = fixture.metrics("00000000000000000005")
unavailable.GPU_CAPS_VALID, unavailable.GPU_PRESENT, unavailable.GPU_UNIFIED = "0", "0", "0"
unavailable.GPU_LOW_POWER, unavailable.GPU_REMOVABLE, unavailable.GPU_HEADLESS = "0", "0", "0"
unavailable.GPU_RECOMMENDED_MAX_B = "0"
fire(objects.cpu, "system_metrics_v2", unavailable)
check(objects["popup.gpu.present"].properties.label.string == "—",
  "unavailable GPU capabilities must not render as absent")
fire(objects.tmp, "mouse.clicked", { BUTTON = "left" })
local power_row = objects["popup.tmp.power"]
check(power_row and power_row.properties.label.string ~= "",
  "TMP popup is missing Low Power Mode value")
check(power_row.properties.label.color == colors.primary,
  "TMP Low Power Mode value lost the shared visible color")
local unavailable_metrics = fixture.metrics("00000000000000000006")
unavailable_metrics.CPU_VALID = "0"
unavailable_metrics.CPU_BUSY_PCT, unavailable_metrics.CPU_USER_PCT = "0", "0"
unavailable_metrics.CPU_SYSTEM_PCT, unavailable_metrics.CPU_IDLE_PCT = "0", "0"
unavailable_metrics.NET_VALID = "0"
unavailable_metrics.NET_RX_BPS, unavailable_metrics.NET_TX_BPS = "0", "0"
fire(objects.cpu, "system_metrics_v2", unavailable_metrics)
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
print("Six public stats items and CPU detail/GPU capability UI passed")
