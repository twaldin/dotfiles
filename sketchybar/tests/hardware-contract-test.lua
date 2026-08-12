package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local contract = require("lib.hardware_contract")

local function fixture()
  return {
    schema = "hardware_state_v1", smc_available = true, native_available = true,
    temperatures = { cpu_temp_c = 70.5, cpu_sensor_count = 2, gpu_temp_c = 60.25, gpu_sensor_count = 1 },
    fans = { { index = 1, rpm = 2500, min_rpm = 2000, max_rpm = 7000, target_rpm = 2500, mode = "automatic" } },
    gpu = { utilization_pct = 30 }, power = { cpu_w = 10, gpu_w = 2, ane_w = 0, ram_w = 1 },
    frequency = { average_mhz = 2500, efficiency_mhz = 1500, performance_mhz = 3500 },
    power_mode = { source = "ac", mode = "high", supported = { "automatic", "low", "high" } },
  }
end

assert(contract.validate(fixture()), "valid hardware fixture rejected")
local optional = fixture()
optional.gpu, optional.power, optional.frequency, optional.power_mode = {}, {}, {}, nil
assert(contract.validate(optional), "decoded null optionals rejected")

local extra = fixture(); extra.raw_identifier = "forbidden"
assert(not contract.validate(extra), "extra top-level key accepted")
local nested_extra = fixture(); nested_extra.gpu.service = "forbidden"
assert(not contract.validate(nested_extra), "extra nested key accepted")
local nan = fixture(); nan.power.cpu_w = 0 / 0
assert(not contract.validate(nan), "non-finite power accepted")
local range = fixture(); range.gpu.utilization_pct = 101
assert(not contract.validate(range), "out-of-range utilization accepted")
local fan = fixture(); fan.fans[1].target_rpm = 8000
assert(not contract.validate(fan), "out-of-range fan target accepted")
local fan_index = fixture(); fan_index.fans[1].index = 2
assert(not contract.validate(fan_index), "noncanonical fan index accepted")
local modes = fixture(); modes.power_mode.supported = { "automatic", "high", "low" }
assert(not contract.validate(modes), "noncanonical power mode ordering accepted")

print("Hardware contract tests passed")
