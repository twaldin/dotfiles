local M = {}

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

local function integer(value, minimum, maximum)
  return type(value) == "number" and value == value and value % 1 == 0
    and value >= minimum and value <= maximum
end

local failure_codes = {
  authentication_failed = true, invalid_request = true, stale_request = true,
  replay = true, unsupported = true, preflight_failed = true,
  mutation_failed = true, readback_failed = true, rollback_failed = true,
  lease_invalid = true, internal_error = true,
}

local function validate_owner(owner)
  if type(owner) ~= "table" or owner.schema ~= "fan_power_owner_v1"
    or type(owner.ok) ~= "boolean" or type(owner.code) ~= "string" then return nil end
  if not owner.ok then
    if exact(owner, { schema = true, ok = true, code = true }) and failure_codes[owner.code] then
      return { ok = false, code = owner.code }
    end
    return nil
  end
  if owner.code ~= "ok" or not exact(owner, {
    schema = true, ok = true, code = true, fan = true, power = true,
  }) or not exact(owner.fan, {
    supported = true, mode = true, boost_seconds_remaining = true,
  }) or not exact(owner.power, {
    supported = true, source = true, mode = true, supported_modes = true,
  }) or type(owner.fan.supported) ~= "boolean"
    or type(owner.power.supported) ~= "boolean"
    or not integer(owner.fan.boost_seconds_remaining, 0, 60) then return nil end

  local fan_mode = owner.fan.mode
  if not ({ automatic = true, boost = true, unknown = true, unavailable = true })[fan_mode] then return nil end
  if owner.fan.supported and fan_mode ~= "automatic" and fan_mode ~= "boost"
    and fan_mode ~= "unknown" then return nil end
  if owner.fan.supported and fan_mode ~= "boost" and owner.fan.boost_seconds_remaining ~= 0 then return nil end
  if not owner.fan.supported and (fan_mode ~= "unavailable"
    or owner.fan.boost_seconds_remaining ~= 0) then return nil end

  local power = owner.power
  if not ({ battery = true, ac = true, unavailable = true })[power.source]
    or not ({ automatic = true, low = true, high = true, unavailable = true })[power.mode]
    or type(power.supported_modes) ~= "table" or #power.supported_modes > 3 then return nil end
  local order, previous, seen = { automatic = 1, low = 2, high = 3 }, 0, {}
  for key in pairs(power.supported_modes) do
    if type(key) ~= "number" or key % 1 ~= 0 or key < 1 or key > #power.supported_modes then return nil end
  end
  for _, mode in ipairs(power.supported_modes) do
    if not order[mode] or seen[mode] or order[mode] <= previous then return nil end
    seen[mode], previous = true, order[mode]
  end
  if power.supported then
    if power.source == "unavailable" or power.mode == "unavailable"
      or power.supported_modes[1] ~= "automatic" or not seen[power.mode] then return nil end
  elseif power.source ~= "unavailable" or power.mode ~= "unavailable"
    or #power.supported_modes ~= 0 then return nil end
  return { ok = true, fan = owner.fan, power = power }
end

function M.validate(value)
  if not exact(value, { schema = true, trusted = true, recovery = true })
    and not exact(value, { schema = true, trusted = true, owner = true }) then return nil end
  if value.schema ~= "fan_power_client_v1" or type(value.trusted) ~= "boolean" then return nil end
  if not value.trusted then
    if value.recovery ~= "open_install_instructions" then return nil end
    return { trusted = false }
  end
  local owner = validate_owner(value.owner)
  return owner and { trusted = true, owner = owner } or nil
end

local Controller = {}
Controller.__index = Controller

function M.new(options)
  assert(type(options) == "table" and type(options.run) == "function"
    and type(options.changed) == "function" and type(options.recovery) == "function"
    and (options.now == nil or type(options.now) == "function"))
  return setmetatable({
    options = options, phase = "idle", state = nil, generation = 0, open = false,
    last_refresh_at = nil,
  }, Controller)
end

function Controller:finish(output, exit_code, generation)
  if generation ~= self.generation then return end
  local accepted = M.validate(output)
  if accepted and accepted.trusted and accepted.owner.ok and exit_code == 0 then
    self.phase, self.state = "ready", accepted.owner
    self.last_refresh_at = (self.options.now or os.time)()
  elseif accepted and not accepted.trusted then
    self.phase, self.state = "recovery", nil
  else
    self.phase, self.state = "error", accepted and accepted.owner or nil
  end
  if not self.open then self.phase, self.state = "idle", nil end
  self.options.changed()
end

function Controller:refresh()
  if self.phase == "checking" or self.phase == "busy" then return end
  self.phase = "checking"
  self.generation = self.generation + 1
  local generation = self.generation
  self.options.run({ "status" }, function(output, exit_code)
    self:finish(output, exit_code, generation)
  end)
end

function Controller:apply(arguments, label)
  if self.phase ~= "ready" then return end
  self.phase = "busy"
  self.busy_label = label
  self.generation = self.generation + 1
  local generation = self.generation
  self.options.changed()
  self.options.run(arguments, function(output, exit_code)
    if generation == self.generation then self.busy_label = nil end
    self:finish(output, exit_code, generation)
  end)
end

function Controller:closed()
  self.open = false
  if self.phase ~= "busy" then
    self.generation = self.generation + 1
    self.phase, self.state = "idle", nil
  end
end

local labels = { automatic = "Automatic", low = "Low Power", high = "High Power" }

function Controller:build(host, token, popup, colors)
  self.open = true
  popup.section(host, token, "owner_heading", "Fan and power control")
  local now = (self.options.now or os.time)()
  if self.phase == "idle" or (self.phase == "ready"
      and (not self.last_refresh_at or now < self.last_refresh_at
        or now - self.last_refresh_at >= 2)) then
    self:refresh()
  end
  if self.phase == "checking" then
    popup.note(host, token, "owner_checking", "Checking signed privileged owner…", { align = "center" })
    return
  end
  if self.phase == "busy" then
    popup.note(host, token, "owner_busy", self.busy_label or "Applying…", {
      align = "center", color = colors.warning,
    })
    popup.note(host, token, "owner_busy_guard", "Controls are inert until verified readback completes", {
      align = "center",
    })
    return
  end
  if self.phase ~= "ready" or not self.state or not self.state.ok then
    popup.note(host, token, "owner_unavailable", "Signed owner or live permission check failed", {
      align = "center", color = colors.warning,
    })
    popup.link(host, token, "owner_recovery", "Open install and permission recovery", self.options.recovery)
    return
  end

  local fan, power = self.state.fan, self.state.power
  local actions = 0
  if fan.supported then
    local fan_label = ({ automatic = "Automatic", boost = "Maximum Boost", unknown = "State not confirmed" })[fan.mode]
    popup.field(host, token, "owner_fan_state", "Fan policy", fan_label, {
      value_color = fan.mode == "unknown" and colors.warning or nil,
    })
    if fan.mode == "automatic" then
      popup.choice(host, token, "owner_fan_boost", "Boost to hardware maximum · 60 seconds", false,
        function() self:apply({ "fan", "boost" }, "Maximum Boost active · Automatic in at most 60 seconds") end,
        { icon = "↑", color = colors.warning })
    else
      popup.choice(host, token, "owner_fan_automatic", "Return all fans to Automatic", false,
        function() self:apply({ "fan", "automatic" }, "Returning all fans to Automatic…") end,
        { icon = "↺", color = colors.green })
    end
    actions = actions + 1
  end

  if power.supported then
    popup.field(host, token, "owner_power_state", "Power mode",
      labels[power.mode] .. " · " .. (power.source == "ac" and "AC" or "Battery"))
    for _, mode in ipairs(power.supported_modes) do
      if mode ~= power.mode then
        popup.choice(host, token, "owner_power_" .. mode, "Use " .. labels[mode] .. " on " ..
          (power.source == "ac" and "AC" or "Battery"), false,
          function() self:apply({ "power", power.source, mode }, "Applying " .. labels[mode] .. "…") end)
        actions = actions + 1
      end
    end
  end

  if actions == 0 then
    popup.note(host, token, "owner_no_capabilities", "No live fan or power write capability passed", {
      align = "center", color = colors.warning,
    })
    popup.link(host, token, "owner_recovery", "Open install and permission recovery", self.options.recovery)
  end
end

return M
