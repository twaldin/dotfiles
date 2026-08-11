package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path
local contract = require("lib.stats_contract")
local fixture = require("tests.stats-fixture")
local function check(value, message) if not value then error(message, 0) end end
local function clone(value)
  local copy = {}
  for key, child in pairs(value) do copy[key] = child end
  return copy
end
local now = os.time()
local cursor = { retired = {} }

local first = fixture.metrics("00000000000000000001")
first.METRICS_SAMPLE_EPOCH_S = tostring(now)
local accepted = contract.accept(cursor, first, now)
check(accepted and accepted.reset and cursor.metrics_sequence == first.METRICS_SEQ,
  "fresh producer baseline was rejected")
check(not contract.accept(cursor, clone(first), now), "duplicate metric sequence was accepted")

local detail = fixture.cpu_detail("00000000000000000001")
detail.CPU_DETAIL_SAMPLE_EPOCH_S = tostring(now)
detail.NAME, detail.SENDER, detail.INFO = "cpu", "system_cpu_detail_v1", ""
accepted = contract.accept_cpu_detail(cursor, detail, now)
check(accepted and not accepted.reset and #accepted.cores == 10 and accepted.uptime == 90061,
  "CPU detail baseline was rejected")
check(cursor.cpu_detail_sequence == detail.CPU_DETAIL_SEQ, "CPU detail cursor did not advance")
check(not contract.accept_cpu_detail(cursor, clone(detail), now), "duplicate CPU detail sequence was accepted")

local second = fixture.metrics("00000000000000000002")
second.METRICS_SAMPLE_EPOCH_S = tostring(now)
second.NAME, second.SENDER, second.INFO = "cpu", "system_metrics_v2", ""
check(contract.accept(cursor, second, now) and cursor.metrics_sequence == second.METRICS_SEQ,
  "increasing metric sequence was rejected")

local rounded = fixture.metrics("00000000000000000003")
rounded.CPU_BUSY_PCT, rounded.CPU_USER_PCT, rounded.CPU_NICE_PCT = "66.667", "33.333", "33.333"
rounded.CPU_SYSTEM_PCT, rounded.CPU_IDLE_PCT = "0.000", "33.334"
rounded.METRICS_SAMPLE_EPOCH_S = tostring(now)
check(contract.accept(cursor, rounded, now), "three-decimal CPU rounding bound was rejected")

local invalid_metrics = {
  function(value) value.METRICS_SCHEMA = "1" end,
  function(value) value.METRICS_SAMPLE_EPOCH_S = tostring(now - 16) end,
  function(value) value.METRICS_SAMPLE_EPOCH_S = tostring(now + 1) end,
  function(value) value.CPU_BUSY_PCT = "nan" end,
  function(value) value.CPU_BUSY_PCT = "101" end,
  function(value) value.CPU_IDLE_PCT = "75" end,
  function(value) value.MEM_AVAILABLE_B = "1" end,
  function(value) value.SWAP_USED_B = "5000000000" end,
  function(value) value.SSD_USED_B = "1" end,
  function(value) value.NET_STATE = "connected" end,
  function(value) value.NET_VALID = "0" end,
  function(value) value.GPU_ACTIVITY_VALID = "1" end,
  function(value) value.PRESSURE_STATE = "red" end,
  function(value)
    value.CPU_SAMPLED, value.CPU_VALID = "0", "0"
    value.CPU_BUSY_PCT, value.CPU_USER_PCT, value.CPU_NICE_PCT = "0", "0", "0"
    value.CPU_SYSTEM_PCT, value.CPU_IDLE_PCT, value.CPU_LOAD1 = "0", "0", "1"
  end,
  function(value)
    value.NET_SAMPLED, value.NET_VALID = "0", "0"
    value.NET_RX_BPS, value.NET_TX_BPS = "0", "0"
  end,
  function(value)
    value.CONDITION_SAMPLED, value.THERMAL_VALID, value.PRESSURE_VALID = "0", "0", "0"
    value.THERMAL_STATE, value.PRESSURE_STATE, value.LOW_POWER_STATE = "unknown", "unknown", "on"
  end,
  function(value) value.CPU_ACTIVE = nil end,
  function(value) value.UNRELATED_FIELD = "1" end,
}
for index, mutate in ipairs(invalid_metrics) do
  local value = fixture.metrics("00000000000000000004")
  value.METRICS_SAMPLE_EPOCH_S = tostring(now)
  mutate(value)
  local before_instance = cursor.instance
  local before_metrics, before_detail = cursor.metrics_sequence, cursor.cpu_detail_sequence
  check(not contract.accept(cursor, value, now), "invalid metric contract case accepted: " .. index)
  check(cursor.instance == before_instance and cursor.metrics_sequence == before_metrics
      and cursor.cpu_detail_sequence == before_detail,
    "rejected metric event mutated cursor: " .. index)
end

local invalid_details = {
  function(value) value.CPU_DETAIL_SCHEMA = "2" end,
  function(value) value.CPU_DETAIL_SAMPLE_EPOCH_S = tostring(now - 16) end,
  function(value) value.CPU_CORE_COUNT = "9" end,
  function(value) value.CPU_CORE_BUSY_PCTS = "10,101,30,40,50,60,70,80,90,100" end,
  function(value) value.CPU_CORE_VALID, value.CPU_CORE_COUNT = "0", "0" end,
  function(value) value.UPTIME_VALID = "0" end,
  function(value) value.UPTIME_S = "9007199254740992" end,
  function(value) value.CPU_CORE_COUNT = nil end,
  function(value) value.UNRELATED_DETAIL_FIELD = "1" end,
}
for index, mutate in ipairs(invalid_details) do
  local value = fixture.cpu_detail("00000000000000000002")
  value.CPU_DETAIL_SAMPLE_EPOCH_S = tostring(now)
  mutate(value)
  local before_instance = cursor.instance
  local before_metrics, before_detail = cursor.metrics_sequence, cursor.cpu_detail_sequence
  check(not contract.accept_cpu_detail(cursor, value, now), "invalid CPU detail case accepted: " .. index)
  check(cursor.instance == before_instance and cursor.metrics_sequence == before_metrics
      and cursor.cpu_detail_sequence == before_detail,
    "rejected CPU detail event mutated cursor: " .. index)
end

local unavailable = fixture.cpu_detail("00000000000000000002")
unavailable.CPU_DETAIL_SAMPLE_EPOCH_S = tostring(now)
unavailable.CPU_CORE_VALID, unavailable.CPU_CORE_COUNT, unavailable.CPU_CORE_BUSY_PCTS = "0", "0", "0"
check(contract.accept_cpu_detail(cursor, unavailable, now), "explicit unavailable core detail was rejected")

local replacement = fixture.cpu_detail("00000000000000000009")
replacement.PRODUCER_INSTANCE = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
replacement.CPU_DETAIL_SAMPLE_EPOCH_S = tostring(now)
accepted = contract.accept_cpu_detail(cursor, replacement, now)
check(accepted and accepted.reset and cursor.retired[first.PRODUCER_INSTANCE],
  "producer replacement did not reset and retire")
local old = fixture.metrics("00000000000000000099")
old.METRICS_SAMPLE_EPOCH_S = tostring(now)
check(not contract.accept(cursor, old, now), "retired producer was accepted")
local replacement_metrics = fixture.metrics("00000000000000000001")
replacement_metrics.PRODUCER_INSTANCE = replacement.PRODUCER_INSTANCE
replacement_metrics.METRICS_SAMPLE_EPOCH_S = tostring(now)
accepted = contract.accept(cursor, replacement_metrics, now)
check(accepted and not accepted.reset, "independent replacement metric stream was rejected")
print("Stats metrics and CPU detail consumer contracts passed")
