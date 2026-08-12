-- This validates public events inside the current macOS user session.
-- SketchyBar custom events do not authenticate same-user senders. A private
-- file handoff would not add authentication because the same user can replace it.
local M = {}
local MAXIMUM_EXACT_INTEGER = 9007199254740991
local MAXIMUM_SEQUENCE = "18446744073709551615"
local SERIALIZED_PERCENTAGE_TOLERANCE = 0.0021

local metrics_required = {
  "METRICS_SCHEMA", "PRODUCER_INSTANCE", "METRICS_SEQ", "METRICS_SAMPLE_EPOCH_S",
  "CPU_SAMPLED", "CPU_VALID", "CPU_BUSY_PCT", "CPU_USER_PCT", "CPU_NICE_PCT",
  "CPU_SYSTEM_PCT", "CPU_IDLE_PCT", "CPU_LOAD1", "CPU_LOAD5", "CPU_LOAD15",
  "CPU_LOGICAL", "CPU_ACTIVE", "MEM_SAMPLED", "MEM_VALID", "MEM_TOTAL_B",
  "MEM_USED_B", "MEM_AVAILABLE_B", "MEM_COMPRESSED_B", "MEM_WIRED_B",
  "SWAP_VALID", "SWAP_TOTAL_B", "SWAP_USED_B", "SSD_SAMPLED", "SSD_VALID",
  "SSD_TOTAL_B", "SSD_FREE_B", "SSD_USED_B", "SSD_USED_PCT",
  "SSD_IMPORTANT_AVAILABLE_VALID", "SSD_IMPORTANT_AVAILABLE_B", "SSD_IO_SAMPLED",
  "SSD_IO_VALID", "SSD_READ_BPS", "SSD_WRITE_BPS", "NET_SAMPLED",
  "NET_VALID", "NET_STATE", "NET_PATH_TYPE", "NET_RX_BPS", "NET_TX_BPS",
  "NET_SESSION_VALID", "NET_SESSION_RX_B", "NET_SESSION_TX_B",
  "NET_EXPENSIVE", "NET_CONSTRAINED", "CONDITION_SAMPLED", "THERMAL_VALID",
  "PRESSURE_VALID", "THERMAL_STATE", "PRESSURE_STATE", "LOW_POWER_STATE",
  "GPU_CAPS_VALID", "GPU_PRESENT", "GPU_UNIFIED", "GPU_LOW_POWER",
  "GPU_REMOVABLE", "GPU_HEADLESS", "GPU_RECOMMENDED_MAX_B", "GPU_ACTIVITY_VALID",
}
local metrics_bits = {
  "CPU_SAMPLED", "CPU_VALID", "MEM_SAMPLED", "MEM_VALID", "SWAP_VALID",
  "SSD_SAMPLED", "SSD_VALID", "SSD_IMPORTANT_AVAILABLE_VALID", "SSD_IO_SAMPLED",
  "SSD_IO_VALID", "NET_SAMPLED", "NET_VALID", "NET_SESSION_VALID", "NET_EXPENSIVE", "NET_CONSTRAINED", "CONDITION_SAMPLED",
  "THERMAL_VALID", "PRESSURE_VALID", "GPU_CAPS_VALID", "GPU_PRESENT",
  "GPU_UNIFIED", "GPU_LOW_POWER", "GPU_REMOVABLE", "GPU_HEADLESS", "GPU_ACTIVITY_VALID",
}
local cpu_detail_required = {
  "CPU_DETAIL_SCHEMA", "PRODUCER_INSTANCE", "CPU_DETAIL_SEQ", "CPU_DETAIL_SAMPLE_EPOCH_S",
  "CPU_CORE_VALID", "CPU_CORE_COUNT", "CPU_CORE_BUSY_PCTS", "UPTIME_VALID", "UPTIME_S",
}

local function one_of(value, choices)
  for _, choice in ipairs(choices) do if value == choice then return true end end
  return false
end

local function number(value, minimum, maximum, integer)
  if type(value) == "string" then
    if integer then
      if not value:match("^%d+$") then return nil end
    elseif not value:match("^%d+$") and not value:match("^%d+%.%d+$") then
      return nil
    end
  elseif type(value) ~= "number" then
    return nil
  end
  local parsed = tonumber(value)
  if not parsed or parsed ~= parsed or parsed == math.huge or parsed == -math.huge then return nil end
  if parsed < minimum or (maximum and parsed > maximum) then return nil end
  if integer and parsed ~= math.floor(parsed) then return nil end
  return parsed
end

local function all_zero(values)
  for _, value in ipairs(values) do if value ~= 0 then return false end end
  return true
end

local event_metadata = { NAME = true, SENDER = true, INFO = true }
local function has_exact_event_keys(env, required)
  local expected = {}
  for _, key in ipairs(required) do
    if env[key] == nil then return false end
    expected[key] = true
  end
  for key in pairs(env) do
    if not expected[key] and not event_metadata[key] then return false end
  end
  return true
end

local function valid_instance(value)
  return type(value) == "string" and #value == 32 and value:match("^[0-9a-f]+$") ~= nil
end

local function valid_sequence(value)
  return type(value) == "string" and #value == 20 and value:match("^%d+$") ~= nil
    and value <= MAXIMUM_SEQUENCE
end

local function envelope(cursor, instance, sequence, epoch_value, now, sequence_key)
  if not valid_instance(instance) or not valid_sequence(sequence) then return nil end
  local epoch = number(epoch_value, 1, MAXIMUM_EXACT_INTEGER, true)
  now = number(now, 1, MAXIMUM_EXACT_INTEGER, true)
  if not epoch or not now or epoch > now or now - epoch > 15 then return nil end
  if cursor.retired and cursor.retired[instance] then return nil end
  if cursor.instance == instance and cursor[sequence_key] and sequence <= cursor[sequence_key] then return nil end
  return epoch
end

local function commit(cursor, instance, sequence, epoch, sequence_key)
  local reset = cursor.instance ~= instance
  if reset and cursor.instance then
    cursor.retired = cursor.retired or {}
    cursor.retired[cursor.instance] = true
  end
  if reset then
    cursor.metrics_sequence = nil
    cursor.cpu_detail_sequence = nil
    cursor.network_session_rx = nil
    cursor.network_session_tx = nil
  end
  cursor.instance = instance
  cursor[sequence_key] = sequence
  return { reset = reset, sequence = sequence, epoch = epoch }
end

function M.accept(cursor, env, now)
  if type(cursor) ~= "table" or type(env) ~= "table"
      or not has_exact_event_keys(env, metrics_required) then return nil end
  if env.METRICS_SCHEMA ~= "3" then return nil end
  local instance, sequence = env.PRODUCER_INSTANCE, env.METRICS_SEQ
  local epoch = envelope(cursor, instance, sequence, env.METRICS_SAMPLE_EPOCH_S, now, "metrics_sequence")
  if not epoch then return nil end
  for _, key in ipairs(metrics_bits) do if env[key] ~= "0" and env[key] ~= "1" then return nil end end
  if env.CPU_VALID == "1" and env.CPU_SAMPLED ~= "1" then return nil end
  if (env.MEM_VALID == "1" or env.SWAP_VALID == "1") and env.MEM_SAMPLED ~= "1" then return nil end
  if (env.SSD_VALID == "1" or env.SSD_IMPORTANT_AVAILABLE_VALID == "1") and env.SSD_SAMPLED ~= "1" then return nil end
  if env.SSD_IO_VALID == "1" and env.SSD_IO_SAMPLED ~= "1" then return nil end
  if (env.NET_VALID == "1" or env.NET_SESSION_VALID == "1") and env.NET_SAMPLED ~= "1" then return nil end
  if (env.THERMAL_VALID == "1" or env.PRESSURE_VALID == "1") and env.CONDITION_SAMPLED ~= "1" then return nil end

  local cpu = {}
  for _, key in ipairs({ "CPU_BUSY_PCT", "CPU_USER_PCT", "CPU_NICE_PCT", "CPU_SYSTEM_PCT", "CPU_IDLE_PCT" }) do
    cpu[key] = number(env[key], 0, 100)
    if not cpu[key] then return nil end
  end
  local loads = {}
  for _, key in ipairs({ "CPU_LOAD1", "CPU_LOAD5", "CPU_LOAD15" }) do
    loads[key] = number(env[key], 0)
    if not loads[key] then return nil end
  end
  local logical = number(env.CPU_LOGICAL, 1, nil, true)
  local active = number(env.CPU_ACTIVE, 1, nil, true)
  if not logical or not active or active > logical then return nil end
  if env.CPU_VALID == "1" then
    local components = cpu.CPU_USER_PCT + cpu.CPU_NICE_PCT + cpu.CPU_SYSTEM_PCT
    if math.abs(cpu.CPU_BUSY_PCT - components) > SERIALIZED_PERCENTAGE_TOLERANCE or
        math.abs(components + cpu.CPU_IDLE_PCT - 100) > 0.02 then return nil end
  elseif not all_zero({ cpu.CPU_BUSY_PCT, cpu.CPU_USER_PCT, cpu.CPU_NICE_PCT, cpu.CPU_SYSTEM_PCT, cpu.CPU_IDLE_PCT }) then return nil end
  if env.CPU_SAMPLED == "0" and not all_zero({
      cpu.CPU_BUSY_PCT, cpu.CPU_USER_PCT, cpu.CPU_NICE_PCT, cpu.CPU_SYSTEM_PCT,
      cpu.CPU_IDLE_PCT, loads.CPU_LOAD1, loads.CPU_LOAD5, loads.CPU_LOAD15,
    }) then return nil end

  local mem_total = number(env.MEM_TOTAL_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local mem_used = number(env.MEM_USED_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local mem_available = number(env.MEM_AVAILABLE_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local mem_compressed = number(env.MEM_COMPRESSED_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local mem_wired = number(env.MEM_WIRED_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local swap_total = number(env.SWAP_TOTAL_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local swap_used = number(env.SWAP_USED_B, 0, MAXIMUM_EXACT_INTEGER, true)
  if not (mem_total and mem_used and mem_available and mem_compressed and mem_wired and swap_total and swap_used) then return nil end
  if env.MEM_VALID == "1" then
    if mem_used > mem_total or mem_available ~= mem_total - mem_used then return nil end
  elseif not all_zero({ mem_total, mem_used, mem_available, mem_compressed, mem_wired }) then return nil end
  if env.SWAP_VALID == "1" then if swap_used > swap_total then return nil end
  elseif not all_zero({ swap_total, swap_used }) then return nil end
  if env.MEM_SAMPLED == "0" and (env.MEM_VALID ~= "0" or env.SWAP_VALID ~= "0" or
      not all_zero({ mem_total, mem_used, mem_available, mem_compressed, mem_wired, swap_total, swap_used })) then return nil end

  local ssd_total = number(env.SSD_TOTAL_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local ssd_free = number(env.SSD_FREE_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local ssd_used = number(env.SSD_USED_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local ssd_percent = number(env.SSD_USED_PCT, 0, 100)
  local ssd_important = number(env.SSD_IMPORTANT_AVAILABLE_B, 0, MAXIMUM_EXACT_INTEGER, true)
  if not (ssd_total and ssd_free and ssd_used and ssd_percent and ssd_important) then return nil end
  if env.SSD_VALID == "1" then
    if ssd_total <= 0 or ssd_free > ssd_total or ssd_used ~= ssd_total - ssd_free then return nil end
    if math.abs(ssd_percent - (100 * ssd_used / ssd_total)) > 0.001 then return nil end
  elseif not all_zero({ ssd_total, ssd_free, ssd_used, ssd_percent, ssd_important }) then return nil end
  if env.SSD_SAMPLED == "0" and (env.SSD_VALID ~= "0" or env.SSD_IMPORTANT_AVAILABLE_VALID ~= "0" or
      not all_zero({ ssd_total, ssd_free, ssd_used, ssd_percent, ssd_important })) then return nil end
  local ssd_read = number(env.SSD_READ_BPS, 0, MAXIMUM_EXACT_INTEGER, true)
  local ssd_write = number(env.SSD_WRITE_BPS, 0, MAXIMUM_EXACT_INTEGER, true)
  if not ssd_read or not ssd_write then return nil end
  if env.SSD_IO_VALID == "0" and not all_zero({ ssd_read, ssd_write }) then return nil end
  if env.SSD_IO_SAMPLED == "0" and (env.SSD_IO_VALID ~= "0" or
      not all_zero({ ssd_read, ssd_write })) then return nil end

  local rx = number(env.NET_RX_BPS, 0, MAXIMUM_EXACT_INTEGER, true)
  local tx = number(env.NET_TX_BPS, 0, MAXIMUM_EXACT_INTEGER, true)
  local session_rx = number(env.NET_SESSION_RX_B, 0, MAXIMUM_EXACT_INTEGER, true)
  local session_tx = number(env.NET_SESSION_TX_B, 0, MAXIMUM_EXACT_INTEGER, true)
  if not rx or not tx or not session_rx or not session_tx
      or (env.NET_VALID == "0" and (rx ~= 0 or tx ~= 0))
      or (env.NET_SESSION_VALID == "0" and (session_rx ~= 0 or session_tx ~= 0)) then return nil end
  if cursor.instance == instance and env.NET_SESSION_VALID == "1"
      and ((cursor.network_session_rx and session_rx < cursor.network_session_rx)
        or (cursor.network_session_tx and session_tx < cursor.network_session_tx)) then return nil end
  if not one_of(env.NET_STATE, { "satisfied", "unsatisfied", "requires_connection", "unknown" }) then return nil end
  if not one_of(env.NET_PATH_TYPE, { "wifi", "wired", "cellular", "other", "multiple", "none", "unknown" }) then return nil end
  if not one_of(env.THERMAL_STATE, { "nominal", "fair", "serious", "critical", "unknown" }) then return nil end
  if not one_of(env.PRESSURE_STATE, { "normal", "warning", "critical", "unknown" }) then return nil end
  if not one_of(env.LOW_POWER_STATE, { "on", "off_or_unsupported" }) then return nil end
  if env.NET_SAMPLED == "0" and not (env.NET_VALID == "0" and env.NET_SESSION_VALID == "0"
      and rx == 0 and tx == 0 and session_rx == 0 and session_tx == 0 and
      env.NET_STATE == "unknown" and env.NET_PATH_TYPE == "unknown" and
      env.NET_EXPENSIVE == "0" and env.NET_CONSTRAINED == "0") then return nil end
  if env.CONDITION_SAMPLED == "0" and not (env.THERMAL_VALID == "0" and env.PRESSURE_VALID == "0" and
      env.THERMAL_STATE == "unknown" and env.PRESSURE_STATE == "unknown" and
      env.LOW_POWER_STATE == "off_or_unsupported") then return nil end
  if env.THERMAL_VALID == "0" and env.THERMAL_STATE ~= "unknown" then return nil end
  if env.PRESSURE_VALID == "0" and env.PRESSURE_STATE ~= "unknown" then return nil end
  if env.SSD_IMPORTANT_AVAILABLE_VALID == "0" and ssd_important ~= 0 then return nil end
  local gpu_max = number(env.GPU_RECOMMENDED_MAX_B, 0, MAXIMUM_EXACT_INTEGER, true)
  if not gpu_max or env.GPU_ACTIVITY_VALID ~= "0" then return nil end
  if env.GPU_CAPS_VALID == "0" and not (env.GPU_PRESENT == "0" and env.GPU_UNIFIED == "0" and
      env.GPU_LOW_POWER == "0" and env.GPU_REMOVABLE == "0" and env.GPU_HEADLESS == "0" and gpu_max == 0) then return nil end
  if env.GPU_PRESENT == "0" and not (env.GPU_UNIFIED == "0" and env.GPU_LOW_POWER == "0" and
      env.GPU_REMOVABLE == "0" and env.GPU_HEADLESS == "0" and gpu_max == 0) then return nil end

  local accepted = commit(cursor, instance, sequence, epoch, "metrics_sequence")
  if env.NET_SESSION_VALID == "1" then
    cursor.network_session_rx = session_rx
    cursor.network_session_tx = session_tx
  else
    cursor.network_session_rx = nil
    cursor.network_session_tx = nil
  end
  return accepted
end

local function percentages(value)
  if type(value) ~= "string" or #value == 0 or #value > 2048 then return nil end
  local result = {}
  for token in (value .. ","):gmatch("(.-),") do
    local parsed = number(token, 0, 100)
    if not parsed then return nil end
    result[#result + 1] = parsed
    if #result > 128 then return nil end
  end
  if #result == 0 then return nil end
  return result
end

function M.accept_cpu_detail(cursor, env, now)
  if type(cursor) ~= "table" or type(env) ~= "table"
      or not has_exact_event_keys(env, cpu_detail_required) then return nil end
  if env.CPU_DETAIL_SCHEMA ~= "1" then return nil end
  local instance, sequence = env.PRODUCER_INSTANCE, env.CPU_DETAIL_SEQ
  local epoch = envelope(cursor, instance, sequence, env.CPU_DETAIL_SAMPLE_EPOCH_S, now, "cpu_detail_sequence")
  if not epoch then return nil end
  if not one_of(env.CPU_CORE_VALID, { "0", "1" }) or not one_of(env.UPTIME_VALID, { "0", "1" }) then return nil end
  local count = number(env.CPU_CORE_COUNT, 0, 128, true)
  local uptime = number(env.UPTIME_S, 0, MAXIMUM_EXACT_INTEGER, true)
  if not count or not uptime or (env.UPTIME_VALID == "0" and uptime ~= 0) then return nil end
  local cores
  if env.CPU_CORE_VALID == "1" then
    cores = percentages(env.CPU_CORE_BUSY_PCTS)
    if not cores or count == 0 or #cores ~= count then return nil end
  elseif count ~= 0 or env.CPU_CORE_BUSY_PCTS ~= "0" then
    return nil
  end
  local accepted = commit(cursor, instance, sequence, epoch, "cpu_detail_sequence")
  accepted.cores = cores
  accepted.uptime = env.UPTIME_VALID == "1" and uptime or nil
  return accepted
end

return M
