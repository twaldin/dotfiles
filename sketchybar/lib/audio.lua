local settings = require("settings")
local shell = require("lib.shell")

--[[ Private state ──────────────────────────────────────────────────────
     All mutable state lives in module-private locals.  Nothing below
     appears on the returned table M.
--]]
local confirmed_state  = nil    -- last valid parse result (contains handles)
local generation       = {}    -- unique, non-reusable confirmed-state token
local request_token    = {}    -- unique async state-read callback token
local action_token     = {}    -- unique async write callback token
local in_flight        = false -- refresh coalescing gate
local action_in_flight = false -- single concurrent action gate
local refresh_pending  = false -- latest-state retry requested during busy work
local active_claims_cleared = false -- hide time-sensitive use after a failed read
local waiters          = {}    -- one-shot refresh callbacks
local listeners        = {}    -- persistent subscribers
local last_error       = "Audio state unavailable"
local pending_label    = nil   -- transient label during an action
local session_started  = false -- opaque-handle session accepted by the coordinator

local M = {}

-- ── Validators ────────────────────────────────────────────────────────

local function finite_number(v)
  return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function exact_keys(value, allowed)
  if type(value) ~= "table" then return false end
  for key in pairs(value) do
    if type(key) ~= "string" or not allowed[key] then return false end
  end
  return true
end

local function is_array(value, cap)
  if type(value) ~= "table" then return false end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if maximum > cap or count ~= maximum then return false end
  for index = 1, maximum do
    if rawget(value, index) == nil then return false end
  end
  return true
end

local function safe_key(v)
  if type(v) ~= "string" or #v ~= 64 or not v:match("^[0-9a-f]+$") then
    return nil
  end
  return v
end

local function enum_set(v, allowed)
  if not is_array(v, 3) then return nil end
  local out = {}
  for _, e in ipairs(v) do
    if not allowed[e] or out[e] then return nil end
    out[e] = true
  end
  return out
end

local function scalar_cap(v)
  if not exact_keys(v, { available = true, settable = true, value = true }) then return nil end
  if type(v.available) ~= "boolean"
     or type(v.settable) ~= "boolean" then return nil end
  if v.settable and not v.available then return nil end
  local a = v.value
  if not v.available and a ~= nil then return nil end
  if a ~= nil and (not finite_number(a) or a < 0 or a > 100) then return nil end
  if v.available and a == nil then return nil end
  return {
    available = v.available,
    settable  = v.settable,
    value     = v.available and a or nil,
  }
end

local function bool_cap(v)
  if not exact_keys(v, { available = true, settable = true, value = true }) then return nil end
  if type(v.available) ~= "boolean"
     or type(v.settable) ~= "boolean" then return nil end
  if v.settable and not v.available then return nil end
  local a = v.value
  if not v.available and a ~= nil then return nil end
  if a ~= nil and type(a) ~= "boolean" then return nil end
  if v.available and a == nil then return nil end
  return {
    available = v.available,
    settable  = v.settable,
    value     = a,
  }
end

local function dir_state(v, direction)
  local allowed = { volume = true, mute = true }
  if direction == "input" then allowed.active = true end
  if not exact_keys(v, allowed) then return nil end
  local vol  = scalar_cap(v.volume)
  local mute = bool_cap(v.mute)
  if not vol or not mute
     or (v.active ~= nil and type(v.active) ~= "boolean") then return nil end
  local result = { volume = vol, mute = mute }
  if v.active ~= nil then result.active = v.active end
  return result
end

-- ── Schema 1 parser (private; result contains handles) ───────────────────

local function parse_state(doc)
  if not exact_keys(doc, {
    schema = true, ok = true, defaults = true, default_settable = true,
    devices = true, warning_count = true,
  }) then return nil end
  if doc.schema ~= 1 or doc.ok ~= true then return nil end
  if not exact_keys(doc.defaults, {
    input = true, output = true, system_output = true,
  }) or not exact_keys(doc.default_settable, {
    input = true, output = true, system_output = true,
  }) or not is_array(doc.devices, 128) then return nil end
  for _, role in ipairs({ "input", "output", "system_output" }) do
    if type(doc.default_settable[role]) ~= "boolean" then return nil end
  end

  local wc = doc.warning_count
  if type(wc) ~= "number" or wc ~= math.floor(wc)
     or wc < 0 or wc > 10000 then return nil end

  local st = {
    confirmed     = true,
    defaults      = {},
    default_settable = {
      input = doc.default_settable.input,
      output = doc.default_settable.output,
      system_output = doc.default_settable.system_output,
    },
    devices       = {},
    by_key        = {},
    warning_count = wc,
  }

  for _, role in ipairs({ "input", "output", "system_output" }) do
    local v = doc.defaults[role]
    if v ~= nil and not safe_key(v) then return nil end
    st.defaults[role] = v
  end

  for _, raw in ipairs(doc.devices) do
    if not exact_keys(raw, {
      key = true, name = true, directions = true, eligible_roles = true,
      roles = true, input = true, output = true,
    }) then return nil end
    local key  = safe_key(raw.key)
    local dirs = enum_set(raw.directions, { input = true, output = true })
    local eligible_roles = enum_set(raw.eligible_roles,
                                    { input = true, output = true, system_output = true })
    local roles = enum_set(raw.roles,
                           { input = true, output = true, system_output = true })
    if not key or not dirs or not eligible_roles or not roles or st.by_key[key] then return nil end
    for eligible_role in pairs(eligible_roles) do
      local direction = eligible_role == "input" and "input" or "output"
      if not dirs[direction] then return nil end
    end

    local inp = raw.input  == nil and nil or dir_state(raw.input, "input")
    local out = raw.output == nil and nil or dir_state(raw.output, "output")
    if (dirs.input  and not inp)
       or (not dirs.input  and raw.input  ~= nil) then return nil end
    if (dirs.output and not out)
       or (not dirs.output and raw.output ~= nil) then return nil end
    if inp and inp.active ~= nil and dirs.output then return nil end

    if type(raw.name) ~= "string" then return nil end
    local visible_name = shell.display(raw.name)

    local dev = {
      key = key, name = visible_name, raw_name = raw.name,
      directions = dirs, eligible_roles = eligible_roles,
      roles = roles, input = inp, output = out,
    }
    st.devices[#st.devices + 1] = dev
    st.by_key[key] = dev
  end

  for _, role in ipairs({ "input", "output", "system_output" }) do
    local key = st.defaults[role]
    local dev = key and st.by_key[key] or nil
    local dk  = role == "input" and "input" or "output"
    if key and (not dev or not dev.directions[dk]) then return nil end
    for _, candidate in ipairs(st.devices) do
      local flagged = candidate.roles[role] or false
      if flagged ~= (key ~= nil and candidate.key == key) then return nil end
    end
  end

  -- Check raw and normalized values before truncation.  Otherwise a long handle
  -- can be shortened into a visible prefix before the privacy check.
  for _, dev in ipairs(st.devices) do
    local unsafe = false
    for key in pairs(st.by_key) do
      if dev.raw_name:find(key, 1, true)
         or dev.name:find(key, 1, true) then
        unsafe = true
        break
      end
    end
    dev.name = unsafe and "Unnamed audio device" or shell.ellipsis(dev.name, 80)
    if dev.name == "" then dev.name = "Unnamed audio device" end
    dev.raw_name = nil
  end

  return st
end

local function parse_write(doc)
  if not exact_keys(doc, {
    schema = true, ok = true, action = true, role = true,
    key = true, volume = true, mute = true,
  }) or doc.schema ~= 1 or doc.ok ~= true or not safe_key(doc.key) then
    return nil
  end
  if doc.role ~= "input" and doc.role ~= "output"
     and doc.role ~= "system_output" then return nil end
  if doc.action == "set_volume" then
    if doc.role == "system_output" or not finite_number(doc.volume)
       or doc.volume < 0 or doc.volume > 100 or doc.mute ~= nil then return nil end
  elseif doc.action == "set_mute" then
    if doc.role == "system_output" or type(doc.mute) ~= "boolean"
       or doc.volume ~= nil then return nil end
  elseif doc.action == "set_default" then
    if doc.volume ~= nil or doc.mute ~= nil then return nil end
  else
    return nil
  end
  return doc
end

-- ── Generation ────────────────────────────────────────────────────────

local function next_gen()
  generation = {}
  return generation
end

local function next_request()
  request_token = {}
  return request_token
end

local function next_action()
  action_token = {}
  return action_token
end

-- ── View builder (handle-free snapshot) ──────────────────────────────────

local function copy_cap(c)
  return { available = c.available, settable = c.settable, value = c.value }
end

local function copy_dir(d, include_active)
  if not d then return nil end
  local result = { volume = copy_cap(d.volume), mute = copy_cap(d.mute) }
  if include_active and d.active ~= nil then result.active = d.active end
  return result
end

local function build_view()
  if not confirmed_state then
    return {
      confirmed     = false,
      actions_available = false,
      warning_count = 0,
      defaults      = { input = nil, output = nil, system_output = nil },
      devices       = {},
      busy          = action_in_flight or in_flight,
      pending_label = pending_label,
      error         = last_error,
    }
  end

  local key_ord = {}
  local vdevs   = {}
  for i, dev in ipairs(confirmed_state.devices) do
    key_ord[dev.key] = i
    vdevs[i] = {
      ordinal    = i,
      name       = dev.name,
      directions = {
        input  = dev.directions.input  or false,
        output = dev.directions.output or false,
      },
      eligible_roles = {
        input         = dev.eligible_roles.input         or false,
        output        = dev.eligible_roles.output        or false,
        system_output = dev.eligible_roles.system_output or false,
      },
      roles = {
        input         = dev.roles.input         or false,
        output        = dev.roles.output        or false,
        system_output = dev.roles.system_output or false,
      },
      input  = copy_dir(dev.input, not active_claims_cleared),
      output = copy_dir(dev.output, false),
    }
  end

  local vdefs = {}
  for _, role in ipairs({ "input", "output", "system_output" }) do
    local key = confirmed_state.defaults[role]
    if key and key_ord[key] then
      local ord = key_ord[key]
      vdefs[role] = { ordinal = ord, name = vdevs[ord].name }
    end
  end

  return {
    confirmed     = true,
    actions_available = session_started,
    warning_count = confirmed_state.warning_count,
    defaults      = vdefs,
    default_settable = {
      input = confirmed_state.default_settable.input,
      output = confirmed_state.default_settable.output,
      system_output = confirmed_state.default_settable.system_output,
    },
    devices       = vdevs,
    busy          = action_in_flight or in_flight,
    pending_label = pending_label,
    error         = last_error,
  }
end

-- ── Notification ──────────────────────────────────────────────────────

local function notify()
  local view = build_view()
  for _, fn in ipairs(listeners) do fn(view) end
end

-- ── Safe errors ───────────────────────────────────────────────────────

local function safe_error(code)
  if code == 69 then return "Audio control is unavailable" end
  if code == 75 then return "Audio state changed externally" end
  if code == 64 then return "Audio request is invalid" end
  return "Audio state unavailable"
end

-- ── Private action machinery ──────────────────────────────────────────

local function finish_action(token, output, exit_code, predicate, callback)
  if not action_in_flight or token ~= action_token then return end
  action_in_flight = false
  pending_label = nil
  local observed = exit_code == 0 and parse_write(output) or nil
  M.refresh(function(_, refreshed, rerr)
    local ok = refreshed and observed ~= nil and predicate(observed)
    if ok then
      last_error = nil
    elseif rerr then
      last_error = rerr
    elseif exit_code ~= 0 then
      last_error = safe_error(exit_code)
    else
      last_error = "Audio state changed externally"
    end
    notify()
    if type(callback) == "function" then callback(ok, last_error) end
  end)
end

local function begin_action(argv, label, predicate, callback)
  if action_in_flight or in_flight then
    if type(callback) == "function" then
      callback(false, "Audio controls are busy")
    end
    return false
  end
  action_in_flight = true
  pending_label    = label
  last_error       = nil
  local token = next_action()
  notify()
  shell.exec(argv, function(output, exit_code)
    if not action_in_flight or token ~= action_token then return end
    finish_action(token, output, exit_code, predicate, callback)
  end)
  return true
end

local function set_default_internal(role, key, callback)
  if not confirmed_state or not confirmed_state.by_key[key] then
    if type(callback) == "function" then
      callback(false, "The selected audio device is unavailable")
    end
    return false
  end
  local expected_key = confirmed_state.defaults[role]
  if not expected_key then
    if type(callback) == "function" then
      callback(false, "The current audio default is unavailable")
    end
    return false
  end
  local label = role == "input"         and "Changing microphone…"
             or role == "system_output" and "Changing system alerts…"
             or "Changing sound output…"
  return begin_action(
    { settings.paths.audio_state, "audio", "set-default", role, key, expected_key },
    label,
    function(observed)
      return observed.action == "set_default" and observed.role == role
        and observed.key == key and confirmed_state
        and confirmed_state.defaults[role] == key
    end,
    callback
  )
end

-- ── Resolve internal role (private; returns handle-bearing objects) ──────

local function resolve_role(role)
  if not confirmed_state then return nil, nil end
  local key = confirmed_state.defaults[role]
  local dev = key and confirmed_state.by_key[key] or nil
  if not dev then return nil, nil end
  return dev, role == "input" and dev.input or dev.output
end

-- ── Public API ────────────────────────────────────────────────────────

function M.subscribe(fn)
  if type(fn) ~= "function" or #listeners >= 32 then return false end
  listeners[#listeners + 1] = fn
  fn(build_view())
  return true
end

function M.refresh(callback, retry_if_busy)
  if type(callback) == "function" then
    if #waiters >= 64 then
      callback(build_view(), false, "Audio refresh queue is full")
      return false
    end
    waiters[#waiters + 1] = callback
  end
  if action_in_flight or in_flight then
    if retry_if_busy == true then
      refresh_pending = true
      -- Keep this fail-closed flag until a later response parses successfully.
      if not active_claims_cleared then
        active_claims_cleared = true
        notify()
      end
    end
    return false
  end
  refresh_pending = false
  in_flight = true
  local token = next_request()
  local argv = { settings.paths.audio_state, "audio", "state" }
  if not session_started then argv[#argv + 1] = "begin" end
  shell.exec(
    argv,
    function(output, exit_code)
      if not in_flight or token ~= request_token then return end
      local parsed = exit_code == 0 and parse_state(output) or nil
      if parsed then
        next_gen()
        confirmed_state = parsed
        active_claims_cleared = false
        session_started = true
        last_error      = nil
      else
        next_gen()
        active_claims_cleared = true
        session_started = false
        last_error = safe_error(exit_code)
      end
      in_flight = false
      local batch = waiters
      waiters = {}
      notify()
      local view = build_view()
      local ok   = parsed ~= nil
      for _, w in ipairs(batch) do w(view, ok, last_error) end
      if refresh_pending and not action_in_flight and not in_flight then
        M.refresh(nil, true)
      end
    end
  )
  return true
end

function M.view()
  return build_view()
end

function M.role_settable(role)
  if role ~= "input" and role ~= "output"
     and role ~= "system_output" then return false end
  return session_started and confirmed_state ~= nil
    and confirmed_state.default_settable[role] == true
end

function M.choices(role)
  if not M.role_settable(role) or not confirmed_state then return {} end
  local dk    = role == "input" and "input" or "output"
  local token = generation
  local default_known = confirmed_state.defaults[role] ~= nil
  local reason = role == "input" and "current microphone unavailable"
    or role == "system_output" and "current system alert device unavailable"
    or "current sound output unavailable"
  local result = {}
  for i, dev in ipairs(confirmed_state.devices) do
    if dev.directions[dk] and dev.eligible_roles[role] then
      local captured_key = dev.key
      local choice = {
        ordinal = i,
        name = dev.name,
        available = default_known,
        reason = default_known and nil or reason,
      }
      if default_known then
        choice.invoke = function(cb)
          if token ~= generation then
            if type(cb) == "function" then
              cb(false, "Audio state changed; refresh choices")
            end
            return false
          end
          return set_default_internal(role, captured_key, cb)
        end
      end
      result[#result + 1] = choice
    end
  end
  return result
end

local function stale_control(callback)
  if type(callback) == "function" then
    callback(false, "Audio state changed; refresh controls")
  end
  return false
end

local function set_volume_internal(role, key, value, callback)
  if not finite_number(value) then return false end
  value = math.floor(math.max(0, math.min(100, value)) + 0.5)
  local dev = confirmed_state and confirmed_state.by_key[key] or nil
  local dk = role == "input" and "input" or "output"
  local dir = dev and dev[dk] or nil
  if not confirmed_state or confirmed_state.defaults[role] ~= key
     or not dir or not dir.volume.available or not dir.volume.settable then
    if type(callback) == "function" then
      callback(false, "Level is controlled by the device")
    end
    return false
  end
  return begin_action(
    { settings.paths.audio_state, "audio", "set-volume",
      role, string.format("%.0f", value), key },
    role == "input" and "Changing microphone level…"
                     or "Changing output level…",
    function(observed)
      if observed.action ~= "set_volume" or observed.role ~= role
         or observed.key ~= key or not confirmed_state
         or confirmed_state.defaults[role] ~= key then return false end
      local current = confirmed_state.by_key[key]
      local capability = current and current[dk] and current[dk].volume
      return capability and capability.available
        and capability.value == observed.volume
    end,
    callback
  )
end

local function set_mute_internal(role, key, value, callback)
  if type(value) ~= "boolean" then return false end
  local dev = confirmed_state and confirmed_state.by_key[key] or nil
  local dk = role == "input" and "input" or "output"
  local dir = dev and dev[dk] or nil
  if not confirmed_state or confirmed_state.defaults[role] ~= key
     or not dir or not dir.mute.available or not dir.mute.settable then
    local reason = role == "input"
      and "Microphone mute is not supported by this device"
       or "Mute is not supported by this device"
    if type(callback) == "function" then callback(false, reason) end
    return false
  end
  return begin_action(
    { settings.paths.audio_state, "audio", "set-mute",
      role, value and "on" or "off", key },
    role == "input" and "Changing microphone mute…"
                     or "Changing output mute…",
    function(observed)
      if observed.action ~= "set_mute" or observed.role ~= role
         or observed.key ~= key or observed.mute ~= value
         or not confirmed_state or confirmed_state.defaults[role] ~= key then
        return false
      end
      local current = confirmed_state.by_key[key]
      local capability = current and current[dk] and current[dk].mute
      return capability and capability.available and capability.value == observed.mute
    end,
    callback
  )
end

function M.controls(role)
  if not session_started or (role ~= "input" and role ~= "output") then return nil end
  local token = generation
  local dev = resolve_role(role)
  if not dev then return nil end
  local key = dev.key
  return {
    set_volume = function(value, callback)
      if token ~= generation then return stale_control(callback) end
      return set_volume_internal(role, key, value, callback)
    end,
    set_mute = function(value, callback)
      if token ~= generation then return stale_control(callback) end
      return set_mute_internal(role, key, value, callback)
    end,
  }
end

function M.set_volume(role, value, callback)
  local controls = M.controls(role)
  if not controls then return false end
  return controls.set_volume(value, callback)
end

function M.set_mute(role, value, callback)
  local controls = M.controls(role)
  if not controls then return false end
  return controls.set_mute(value, callback)
end

return M
