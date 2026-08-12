package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path
local module = require("lib.fan_power_control")

local function valid(owner)
  return {
    schema = "fan_power_client_v1", trusted = true,
    owner = owner or {
      schema = "fan_power_owner_v1", ok = true, code = "ok",
      fan = { supported = true, mode = "automatic", boost_seconds_remaining = 0 },
      power = {
        supported = true, source = "ac", mode = "automatic",
        supported_modes = { "automatic", "low", "high" },
      },
    },
  }
end

assert(module.validate(valid()).trusted, "valid trusted owner accepted")
assert(module.validate({
  schema = "fan_power_client_v1", trusted = false,
  recovery = "open_install_instructions",
}).trusted == false, "closed recovery accepted")
local malformed = valid(); malformed.owner.extra = true
assert(module.validate(malformed) == nil, "unknown owner key rejected")
malformed = valid(); malformed.owner.fan.mode = "manual"
assert(module.validate(malformed) == nil, "custom fan mode rejected")
local unknown = valid(); unknown.owner.fan.mode = "unknown"
assert(module.validate(unknown).trusted, "unknown live fan policy keeps Automatic recovery available")
malformed = valid(); malformed.owner.fan.mode = "automatic"; malformed.owner.fan.boost_seconds_remaining = 1
assert(module.validate(malformed) == nil, "non-Boost lease remainder rejected")
malformed = valid(); malformed.owner.power.supported_modes = { "automatic", "high", "low" }
assert(module.validate(malformed) == nil, "noncanonical power modes rejected")
malformed = valid(); malformed.owner.power.source = "ups"
assert(module.validate(malformed) == nil, "UPS write source rejected")
malformed = valid(); malformed.owner.power.mode = "custom"
assert(module.validate(malformed) == nil, "custom power mode rejected")

local pending, changes, recovery_count = {}, 0, 0
local controller = module.new({
  run = function(arguments, callback)
    pending[#pending + 1] = { arguments = arguments, callback = callback }
  end,
  changed = function() changes = changes + 1 end,
  recovery = function() recovery_count = recovery_count + 1 end,
})

local calls = {}
local popup = {}
for _, name in ipairs({ "section", "note", "link", "field", "choice" }) do
  popup[name] = function(_, _, suffix, ...)
    calls[#calls + 1] = { kind = name, suffix = suffix, arguments = { ... } }
  end
end
local colors = { warning = 1, green = 2 }
local function reset() calls = {} end
local function count(kind)
  local result = 0
  for _, call in ipairs(calls) do if call.kind == kind then result = result + 1 end end
  return result
end
local function find(suffix)
  for _, call in ipairs(calls) do if call.suffix == suffix then return call end end
end

controller:build({}, 1, popup, colors)
assert(#pending == 1 and pending[1].arguments[1] == "status", "first build performs status only")
assert(find("owner_checking") and count("choice") == 0 and count("link") == 0,
  "checking state has no operation-looking action")
pending[1].callback(valid(), 0)
assert(changes == 1, "status completion requests one rebuild")
reset(); controller:build({}, 1, popup, colors)
assert(count("choice") == 3 and count("link") == 0, "only live supported mutations render")
assert(find("owner_fan_boost") and find("owner_power_low") and find("owner_power_high"),
  "automatic fan and power selections are not rendered as no-op actions")

local unknown_controller = module.new({
  run = function() error("unknown-state rendering must not execute") end,
  changed = function() end,
  recovery = function() end,
})
local unknown_owner = valid(); unknown_owner.owner.fan.mode = "unknown"
unknown_controller.open, unknown_controller.phase = true, "checking"
unknown_controller:finish(unknown_owner, 0, unknown_controller.generation)
reset(); unknown_controller:build({}, 1, popup, colors)
local unknown_field = find("owner_fan_state")
assert(unknown_field and unknown_field.arguments[2] == "State not confirmed"
    and type(unknown_field.arguments[3]) == "table"
    and unknown_field.arguments[3].value_color == colors.warning,
  "unconfirmed fan policy has truthful warning text and styling")
assert(find("owner_fan_automatic") and not find("owner_fan_boost"),
  "unknown fan policy offers Automatic recovery only")
reset(); controller:build({}, 1, popup, colors)

local boost = find("owner_fan_boost")
boost.arguments[3]()
assert(changes == 2 and #pending == 2, "boost becomes busy before execution")
assert(table.concat(pending[2].arguments, " ") == "fan boost", "boost request is closed")
reset(); controller:build({}, 1, popup, colors)
assert(find("owner_busy") and count("choice") == 0 and count("link") == 0,
  "busy state is visibly inert")
pending[2].callback(valid(), 0)
reset(); controller:build({}, 1, popup, colors)
assert(count("choice") == 3, "verified readback restores actions")

local low = find("owner_power_low")
low.arguments[3]()
assert(#pending == 3, "power action starts one closed request")
controller:closed()
pending[3].callback(valid(), 0)
reset(); controller:build({}, 1, popup, colors)
assert(#pending == 4 and find("owner_checking"),
  "busy completion after close discards stale capability state")
controller:closed()
pending[4].callback(valid(), 0)
reset(); controller:build({}, 1, popup, colors)
assert(#pending == 5 and find("owner_checking"), "closed status callback cannot revive stale state")
pending[5].callback({
  schema = "fan_power_client_v1", trusted = false,
  recovery = "open_install_instructions",
}, 69)
reset(); controller:build({}, 1, popup, colors)
assert(count("choice") == 0 and count("link") == 1 and find("owner_recovery"),
  "provenance failure has one concrete recovery action only")
find("owner_recovery").arguments[2]()
assert(recovery_count == 1, "recovery action is real")


local clock = 100
local cadence_pending = {}
local cadence = module.new({
  run = function(arguments, callback)
    cadence_pending[#cadence_pending + 1] = { arguments = arguments, callback = callback }
  end,
  changed = function() end,
  recovery = function() end,
  now = function() return clock end,
})
reset(); cadence:build({}, 1, popup, colors)
assert(#cadence_pending == 1, "cadence controller starts one status read")
cadence_pending[1].callback(valid(), 0)
clock = 101
reset(); cadence:build({}, 1, popup, colors)
assert(#cadence_pending == 1 and count("choice") == 3,
  "fresh owner state does not start a redundant read")
clock = 102
reset(); cadence:build({}, 1, popup, colors)
assert(#cadence_pending == 2 and find("owner_checking") and count("choice") == 0,
  "open owner state refreshes on a bounded cadence and is inert while checking")
cadence_pending[2].callback(valid(), 0)
clock = 90
reset(); cadence:build({}, 1, popup, colors)
assert(#cadence_pending == 3 and find("owner_checking") and count("choice") == 0,
  "a regressed refresh clock invalidates ready owner controls immediately")

print("fan/power Lua capability and inert-busy tests passed")
