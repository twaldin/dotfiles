local settings = require("settings")
local shell = require("lib.shell")

--[[ Private state ──────────────────────────────────────────────────────
     All mutable state lives in module-private locals.  Nothing below
     appears on the returned table M.
--]]
local confirmed_state  = nil    -- last valid parse result (contains UIDs)
local generation       = {}    -- unique, non-reusable staleness token
local in_flight        = false -- refresh coalescing gate
local action_in_flight = false -- single concurrent action gate
local waiters          = {}    -- one-shot refresh callbacks
local listeners        = {}    -- persistent subscribers
local last_error       = "Audio state unavailable"
local pending_label    = nil   -- transient label during an action

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

local function safe_uid(v)
  if type(v) ~= "string" or v == "" or #v > 1024
     or v:find("[%z\1-\31\127]") then
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

local function dir_state(v)
  if not exact_keys(v, { volume = true, mute = true }) then return nil end
  local vol  = scalar_cap(v.volume)
  local mute = bool_cap(v.mute)
  if not vol or not mute then return nil end
  return { volume = vol, mute = mute }
end

-- ── Schema 1 parser (private; result contains UIDs) ───────────────────

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
    by_uid        = {},
    warning_count = wc,
  }

  for _, role in ipairs({ "input", "output", "system_output" }) do
    local v = doc.defaults[role]
    if v ~= nil and not safe_uid(v) then return nil end
    st.defaults[role] = v
  end

  for _, raw in ipairs(doc.devices) do
    if not exact_keys(raw, {
      uid = true, name = true, directions = true, roles = true,
      input = true, output = true,
    }) then return nil end
    local uid  = safe_uid(raw.uid)
    local dirs = enum_set(raw.directions, { input = true, output = true })
    local roles = enum_set(raw.roles,
                           { input = true, output = true, system_output = true })
    if not uid or not dirs or not roles or st.by_uid[uid] then return nil end

    local inp = raw.input  == nil and nil or dir_state(raw.input)
    local out = raw.output == nil and nil or dir_state(raw.output)
    if (dirs.input  and not inp)
       or (not dirs.input  and raw.input  ~= nil) then return nil end
    if (dirs.output and not out)
       or (not dirs.output and raw.output ~= nil) then return nil end

    if type(raw.name) ~= "string" then return nil end
    local visible_name = shell.display(raw.name)

    local dev = {
      uid = uid, name = visible_name, raw_name = raw.name,
      directions = dirs, roles = roles, input = inp, output = out,
    }
    st.devices[#st.devices + 1] = dev
    st.by_uid[uid] = dev
  end

  for _, role in ipairs({ "input", "output", "system_output" }) do
    local uid = st.defaults[role]
    local dev = uid and st.by_uid[uid] or nil
    local dk  = role == "input" and "input" or "output"
    if uid and (not dev or not dev.directions[dk]) then return nil end
    for _, candidate in ipairs(st.devices) do
      local flagged = candidate.roles[role] or false
      if flagged ~= (uid ~= nil and candidate.uid == uid) then return nil end
    end
  end

  -- Check raw and normalized values before truncation.  Otherwise a long UID
  -- can be shortened into a visible prefix before the privacy check.
  for _, dev in ipairs(st.devices) do
    local unsafe = false
    for uid in pairs(st.by_uid) do
      local visible_uid = shell.display(uid)
      if dev.raw_name:find(uid, 1, true)
         or dev.name:find(uid, 1, true)
         or (visible_uid ~= "" and dev.name:find(visible_uid, 1, true)) then
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

-- ── Generation ────────────────────────────────────────────────────────

local function next_gen()
  generation = {}
  return generation
end

-- ── View builder (UID-free snapshot) ──────────────────────────────────

local function copy_cap(c)
  return { available = c.available, settable = c.settable, value = c.value }
end

local function copy_dir(d)
  if not d then return nil end
  return { volume = copy_cap(d.volume), mute = copy_cap(d.mute) }
end

local function build_view()
  if not confirmed_state then
    return {
      confirmed     = false,
      warning_count = 0,
      defaults      = { input = nil, output = nil, system_output = nil },
      devices       = {},
      busy          = action_in_flight or in_flight,
      pending_label = pending_label,
      error         = last_error,
    }
  end

  local uid_ord = {}
  local vdevs   = {}
  for i, dev in ipairs(confirmed_state.devices) do
    uid_ord[dev.uid] = i
    vdevs[i] = {
      ordinal    = i,
      name       = dev.name,
      directions = {
        input  = dev.directions.input  or false,
        output = dev.directions.output or false,
      },
      roles = {
        input         = dev.roles.input         or false,
        output        = dev.roles.output        or false,
        system_output = dev.roles.system_output or false,
      },
      input  = copy_dir(dev.input),
      output = copy_dir(dev.output),
    }
  end

  local vdefs = {}
  for _, role in ipairs({ "input", "output", "system_output" }) do
    local uid = confirmed_state.defaults[role]
    if uid and uid_ord[uid] then
      local ord = uid_ord[uid]
      vdefs[role] = { ordinal = ord, name = vdevs[ord].name }
    end
  end

  return {
    confirmed     = true,
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

local function finish_action(token, exit_code, predicate, callback)
  if not action_in_flight or token ~= generation then return end
  action_in_flight = false
  pending_label = nil
  M.refresh(function(_, refreshed, rerr)
    local ok = refreshed and exit_code == 0 and predicate()
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
  local token = next_gen()
  notify()
  shell.exec(argv, function(_, exit_code)
    -- Response body deliberately ignored; fresh read follows.
    if not action_in_flight or token ~= generation then return end
    finish_action(token, exit_code, predicate, callback)
  end)
  return true
end

local function set_default_internal(role, uid, callback)
  if not confirmed_state or not confirmed_state.by_uid[uid] then
    if type(callback) == "function" then
      callback(false, "The selected audio device is unavailable")
    end
    return false
  end
  local label = role == "input"         and "Changing microphone…"
             or role == "system_output" and "Changing system alerts…"
             or "Changing sound output…"
  return begin_action(
    { settings.paths.system_controls, "audio", "set-default", role, uid },
    label,
    function()
      return confirmed_state and confirmed_state.defaults[role] == uid
    end,
    callback
  )
end

-- ── Resolve internal role (private; returns UID-bearing objects) ──────

local function resolve_role(role)
  if not confirmed_state then return nil, nil end
  local uid = confirmed_state.defaults[role]
  local dev = uid and confirmed_state.by_uid[uid] or nil
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

function M.refresh(callback)
  if type(callback) == "function" then
    if #waiters >= 64 then
      callback(build_view(), false, "Audio refresh queue is full")
      return false
    end
    waiters[#waiters + 1] = callback
  end
  if action_in_flight or in_flight then return false end
  in_flight = true
  local token = next_gen()
  shell.exec(
    { settings.paths.system_controls, "audio", "state" },
    function(output, exit_code)
      if not in_flight or token ~= generation then return end
      local parsed = exit_code == 0 and parse_state(output) or nil
      if parsed then
        confirmed_state = parsed
        last_error      = nil
      else
        last_error = safe_error(exit_code)
      end
      in_flight = false
      local batch = waiters
      waiters = {}
      notify()
      local view = build_view()
      local ok   = parsed ~= nil
      for _, w in ipairs(batch) do w(view, ok, last_error) end
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
  return confirmed_state ~= nil and confirmed_state.default_settable[role] == true
end

function M.choices(role)
  if not M.role_settable(role) then return {} end
  if not confirmed_state then return {} end
  local dk    = role == "input" and "input" or "output"
  local token = generation
  local result = {}
  for i, dev in ipairs(confirmed_state.devices) do
    if dev.directions[dk] then
      local captured_uid = dev.uid
      result[#result + 1] = {
        ordinal = i,
        name    = dev.name,
        invoke  = function(cb)
          if token ~= generation then
            if type(cb) == "function" then
              cb(false, "Audio state changed; refresh choices")
            end
            return false
          end
          return set_default_internal(role, captured_uid, cb)
        end,
      }
    end
  end
  return result
end

function M.set_volume(role, value, callback)
  if role ~= "input" and role ~= "output" then return false end
  if not finite_number(value) then return false end
  value = math.floor(math.max(0, math.min(100, value)) + 0.5)
  local dev, dir = resolve_role(role)
  if not dev or not dir
     or not dir.volume.available or not dir.volume.settable then
    if type(callback) == "function" then
      callback(false, "Level is controlled by the device")
    end
    return false
  end
  local cap_uid = dev.uid
  local old_value = dir.volume.value
  local dk = role == "input" and "input" or "output"
  return begin_action(
    { settings.paths.system_controls, "audio", "set-volume",
      role, string.format("%.0f", value) },
    role == "input" and "Changing microphone level…"
                     or "Changing output level…",
    function()
      if not confirmed_state or confirmed_state.defaults[role] ~= cap_uid then return false end
      local cur = confirmed_state.by_uid[cap_uid]
      local cap = cur and cur[dk] and cur[dk].volume
      -- CoreAudio scalar controls can quantize.  Match the native helper's
      -- reviewed ±2-point tolerance, but never accept an unchanged old value.
      return cap and cap.available
        and math.abs(cap.value - value) <= 2.0
        and (math.abs(old_value - value) <= 0.001
          or math.abs(cap.value - old_value) > 0.001)
    end,
    callback
  )
end

function M.set_mute(role, value, callback)
  if role ~= "input" and role ~= "output" then return false end
  if type(value) ~= "boolean" then return false end
  local dev, dir = resolve_role(role)
  if not dev or not dir
     or not dir.mute.available or not dir.mute.settable then
    local reason = role == "input"
      and "Microphone mute is not supported by this device"
       or "Mute is not supported by this device"
    if type(callback) == "function" then callback(false, reason) end
    return false
  end
  local cap_uid = dev.uid
  local dk = role == "input" and "input" or "output"
  return begin_action(
    { settings.paths.system_controls, "audio", "set-mute",
      role, value and "on" or "off" },
    role == "input" and "Changing microphone mute…"
                     or "Changing output mute…",
    function()
      if not confirmed_state or confirmed_state.defaults[role] ~= cap_uid then return false end
      local cur = confirmed_state.by_uid[cap_uid]
      local cap = cur and cur[dk] and cur[dk].mute
      return cap and cap.available and cap.value == value
    end,
    callback
  )
end

return M
