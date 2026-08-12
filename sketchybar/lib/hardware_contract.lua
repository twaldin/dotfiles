local M = {}

local function finite(value, minimum, maximum)
  if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then return nil end
  if value < minimum or value > maximum then return nil end
  return value
end

local function allowed(value, keys)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do if not keys[key] then return false end end
  return true
end

local function exact(value, keys)
  if not allowed(value, keys) then return false end
  for key in pairs(keys) do if value[key] == nil then return false end end
  return true
end

local function nullable_number(value, minimum, maximum)
  return value == nil or finite(value, minimum, maximum) ~= nil
end

local function numbers(value, keys, bounds)
  if not allowed(value, keys) then return false end
  for key in pairs(keys) do
    local range = bounds[key]
    if not nullable_number(value[key], range[1], range[2]) then return false end
  end
  return true
end

function M.validate(value)
  if not allowed(value, {
    schema = true, smc_available = true, native_available = true, temperatures = true,
    fans = true, gpu = true, power = true, frequency = true, power_mode = true,
  }) or value.schema ~= "hardware_state_v1" or type(value.temperatures) ~= "table"
    or type(value.fans) ~= "table" or type(value.gpu) ~= "table"
    or type(value.power) ~= "table" or type(value.frequency) ~= "table"
    or type(value.smc_available) ~= "boolean" or type(value.native_available) ~= "boolean" then return nil end

  if not allowed(value.temperatures, {
    cpu_temp_c = true, cpu_sensor_count = true, gpu_temp_c = true, gpu_sensor_count = true,
  }) or not nullable_number(value.temperatures.cpu_temp_c, 0, 130)
    or not nullable_number(value.temperatures.gpu_temp_c, 0, 130)
    or finite(value.temperatures.cpu_sensor_count, 0, 64) == nil
    or finite(value.temperatures.gpu_sensor_count, 0, 64) == nil
    or value.temperatures.cpu_sensor_count % 1 ~= 0 or value.temperatures.gpu_sensor_count % 1 ~= 0 then return nil end

  if type(value.fans) ~= "table" or #value.fans > 8 then return nil end
  for index, fan in ipairs(value.fans) do
    if not exact(fan, { index = true, rpm = true, min_rpm = true, max_rpm = true, target_rpm = true, mode = true })
      or fan.index ~= index or finite(fan.rpm, 0, 30000) == nil
      or finite(fan.min_rpm, 0, 30000) == nil or finite(fan.max_rpm, 0, 30000) == nil
      or finite(fan.target_rpm, 0, 30000) == nil or fan.min_rpm > fan.max_rpm
      or fan.target_rpm < fan.min_rpm or fan.target_rpm > fan.max_rpm
      or (fan.mode ~= "automatic" and fan.mode ~= "manual") then return nil end
  end
  if not numbers(value.gpu, { utilization_pct = true, renderer_pct = true, tiler_pct = true }, {
    utilization_pct = { 0, 100 }, renderer_pct = { 0, 100 }, tiler_pct = { 0, 100 },
  }) or not numbers(value.power, { cpu_w = true, gpu_w = true, ane_w = true, ram_w = true }, {
    cpu_w = { 0, 1000 }, gpu_w = { 0, 1000 }, ane_w = { 0, 1000 }, ram_w = { 0, 1000 },
  }) or not numbers(value.frequency, {
    average_mhz = true, efficiency_mhz = true, performance_mhz = true, super_mhz = true,
  }, {
    average_mhz = { 1, 10000 }, efficiency_mhz = { 1, 10000 },
    performance_mhz = { 1, 10000 }, super_mhz = { 1, 10000 },
  }) then return nil end

  if value.power_mode ~= nil then
    if not exact(value.power_mode, { source = true, mode = true, supported = true })
      or not ({ ac = true, battery = true, ups = true })[value.power_mode.source]
      or not ({ automatic = true, low = true, high = true })[value.power_mode.mode]
      or type(value.power_mode.supported) ~= "table" or #value.power_mode.supported < 1
      or #value.power_mode.supported > 3 then return nil end
    local seen, previous = {}, 0
    local order = { automatic = 1, low = 2, high = 3 }
    for _, mode in ipairs(value.power_mode.supported) do
      if not order[mode] or seen[mode] or order[mode] <= previous then return nil end
      previous, seen[mode] = order[mode], true
    end
    if value.power_mode.supported[1] ~= "automatic" then return nil end
    if not seen[value.power_mode.mode] then return nil end
  end
  return value
end

return M
