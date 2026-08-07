local settings = require("settings")
local shell = require("lib.shell")
local M = {
  current = { interface = "—", state = "offline", ssid = "—", ip = "—", router = "—", rx_rate = 0, tx_rate = 0 },
  previous = nil,
  in_flight = false,
  waiters = {},
  history = {},
}
for _ = 1, 48 do M.history[#M.history + 1] = 0 end

local function fields(line)
  local out = {}
  for field in (line .. "	"):gmatch("(.-)	") do out[#out + 1] = field end
  return out
end

local function finish()
  local waiters = M.waiters
  M.waiters = {}
  M.in_flight = false
  for _, waiter in ipairs(waiters) do waiter(M.current) end
end

function M.sample(callback)
  if callback then M.waiters[#M.waiters + 1] = callback end
  if M.in_flight then return end
  M.in_flight = true
  shell.exec({ settings.config_dir .. "/scripts/network-sample.sh" }, function(output, exit_code)
    local row = fields(shell.trim(output))
    local now, rx, tx = tonumber(row[1]), tonumber(row[3]), tonumber(row[4])
    if exit_code == 0 and now and row[2] and rx and tx then
      local sample = {
        time = now,
        interface = shell.display(row[2] ~= "" and row[2] or "—"),
        rx_bytes = rx,
        tx_bytes = tx,
        ip = shell.display(row[5] ~= "" and row[5] or "—"),
        router = shell.display(row[6] ~= "" and row[6] or "—"),
        ssid = shell.display(row[7] ~= "" and row[7] or "—"),
      }
      sample.state = sample.interface ~= "—" and sample.ip ~= "—" and "connected" or "offline"
      sample.rx_rate, sample.tx_rate = 0, 0
      local previous = M.previous
      if previous and previous.interface == sample.interface and sample.time > previous.time then
        local elapsed = sample.time - previous.time
        sample.rx_rate = math.max(0, sample.rx_bytes - previous.rx_bytes) / elapsed
        sample.tx_rate = math.max(0, sample.tx_bytes - previous.tx_bytes) / elapsed
      end
      -- Publish the previous counter tuple atomically after all validation.
      M.previous = { time = sample.time, interface = sample.interface, rx_bytes = sample.rx_bytes, tx_bytes = sample.tx_bytes }
      M.current = sample
    else
      M.current = { interface = "—", state = "offline", ssid = "—", ip = "—", router = "—", rx_rate = 0, tx_rate = 0 }
      M.previous = nil
    end
    M.history[#M.history + 1] = M.scale_rate(math.max(M.current.rx_rate or 0, M.current.tx_rate or 0))
    if #M.history > 48 then table.remove(M.history, 1) end
    finish()
  end)
end

function M.format_rate(bytes)
  bytes = math.max(0, tonumber(bytes) or 0)
  if bytes >= 1048576 then return string.format("%.1f MiB/s", bytes / 1048576) end
  if bytes >= 1024 then return string.format("%.0f KiB/s", bytes / 1024) end
  return string.format("%.0f B/s", bytes)
end

function M.scale_rate(bytes)
  local maximum = 100 * 1024 * 1024
  return math.max(0, math.min(1, math.log(1 + math.max(0, tonumber(bytes) or 0)) / math.log(1 + maximum)))
end

return M
