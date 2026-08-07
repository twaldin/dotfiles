local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
local config_dir = script:match("^(.*)/tests/[^/]+$")
  or os.getenv("SKETCHYBAR_CONFIG_DIR")
assert(config_dir and config_dir ~= "", "cannot determine SketchyBar config directory")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

-- ── Minimal sbar mock ─────────────────────────────────────────────────
-- Captures every exec call; tests drive callbacks manually.

local exec_calls = {}
sbar = {
  exec = function(command, callback)
    exec_calls[#exec_calls + 1] = { command = command, callback = callback }
  end,
}

local settings = { paths = { system_controls = "/fixed/system-controls" } }
package.loaded["settings"] = settings
local shell = require("lib.shell")

local function check(cond, msg)
  if not cond then error(msg, 2) end
end

-- ── Helpers ───────────────────────────────────────────────────────────

local function fresh()
  package.loaded["lib.audio"] = nil
  exec_calls = {}
  return require("lib.audio")
end

local UIDS = { "UID-OUT-001", "UID-MIC-002" }

local function make_doc(overrides)
  local doc = {
    schema = 1, ok = true, warning_count = 0,
    defaults = { output = UIDS[1], system_output = UIDS[1], input = UIDS[2] },
    default_settable = { output = true, system_output = true, input = true },
    devices = {
      {
        uid = UIDS[1], name = "Test Speakers",
        directions = { "output" },
        roles      = { "output", "system_output" },
        output = {
          volume = { available = true, settable = true, value = 50 },
          mute   = { available = true, settable = true, value = false },
        },
      },
      {
        uid = UIDS[2], name = "Test Microphone",
        directions = { "input" },
        roles      = { "input" },
        input = {
          volume = { available = true, settable = true, value = 80 },
          mute   = { available = true, settable = true, value = false },
        },
      },
    },
  }
  if overrides then
    for k, v in pairs(overrides) do doc[k] = v end
  end
  return doc
end

local function make_doc_with_other_output()
  local doc = make_doc()
  doc.devices[#doc.devices + 1] = {
    uid = "UID-OTHER-003", name = "Other output",
    directions = { "output" }, roles = {},
    output = {
      volume = { available = true, settable = true, value = 25 },
      mute = { available = true, settable = true, value = false },
    },
  }
  return doc
end

local function select_other_output(doc)
  doc.defaults.output = "UID-OTHER-003"
  doc.devices[1].roles = { "system_output" }
  doc.devices[3].roles = { "output" }
  return doc
end

local function complete(index, doc, code)
  exec_calls[index].callback(doc, code or 0)
end

-- Deep scanner: rejects UID strings and "uid"/"by_uid" keys.
local function deep_no_uid(value, uids, path, visited)
  visited = visited or {}
  path    = path or "root"
  if type(value) == "string" then
    for _, uid in ipairs(uids) do
      check(value ~= uid, "UID leaked as value at " .. path .. ": " .. value)
    end
  elseif type(value) == "table" and not visited[value] then
    visited[value] = true
    for k, v in pairs(value) do
      if type(k) == "string" then
        check(k ~= "uid" and k ~= "by_uid",
              "UID key '" .. k .. "' found at " .. path)
      end
      if type(v) ~= "function" then
        deep_no_uid(v, uids, path .. "." .. tostring(k), visited)
      end
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════
-- 1. Hostile schema rejection
-- ══════════════════════════════════════════════════════════════════════

local invalid_default_capability = make_doc()
invalid_default_capability.default_settable.output = "true"

local hostile = {
  { tag = "non-Boolean default capability", doc = invalid_default_capability },
  { tag = "wrong schema",           doc = { schema = 2, ok = true, warning_count = 0, defaults = {}, devices = {} } },
  { tag = "ok=false",               doc = { schema = 1, ok = false, warning_count = 0, defaults = {}, devices = {} } },
  { tag = "float warning_count",    doc = { schema = 1, ok = true, warning_count = 1.5, defaults = {}, devices = {} } },
  { tag = "non-table document",     doc = "not a table" },
  { tag = "nil document",           doc = nil },
  { tag = "duplicate UIDs",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "dup", name = "A", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = false } } },
              { uid = "dup", name = "B", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "settable without available",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = false, settable = true, value = nil },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "volume > 100",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 101 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "direction declared, data missing",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "input" }, roles = { "input" } },
            } } },
  { tag = "default references missing device",
    doc = { schema = 1, ok = true, warning_count = 0,
            defaults = { output = "ghost" }, devices = {} } },
  { tag = "default direction mismatch",
    doc = { schema = 1, ok = true, warning_count = 0,
            defaults = { output = "x" },
            devices = {
              { uid = "x", name = "X", directions = { "input" }, roles = { "input" },
                input = { volume = { available = true, settable = true, value = 50 },
                          mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "available but value nil",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = nil },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "NaN volume",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 0/0 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "duplicate direction entry",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output", "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "undeclared direction data present",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                input = { volume = { available = true, settable = true, value = 50 },
                          mute = { available = true, settable = true, value = false } },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "control char in UID",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "a\tb", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "mute value is number",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = 1 } } },
            } } },
  { tag = "empty UID",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = 50 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "negative volume",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = {
              { uid = "x", name = "X", directions = { "output" }, roles = { "output" },
                output = { volume = { available = true, settable = true, value = -1 },
                           mute = { available = true, settable = true, value = false } } },
            } } },
  { tag = "non-array devices (hash key)",
    doc = { schema = 1, ok = true, warning_count = 0, defaults = {},
            devices = { foo = "bar" } } },
}

for _, case in ipairs(hostile) do
  local audio = fresh()
  audio.refresh()
  complete(1, case.doc, 0)
  local v = audio.view()
  check(not v.confirmed, "hostile schema must reject: " .. case.tag)
end

local targeted_hostile = {
  { tag = "unknown document field", mutate = function(d) d.extra = true end },
  { tag = "unknown defaults field", mutate = function(d) d.defaults.extra = true end },
  { tag = "unknown device field", mutate = function(d) d.devices[1].extra = true end },
  { tag = "unknown direction field", mutate = function(d) d.devices[1].output.extra = true end },
  { tag = "unknown capability field", mutate = function(d) d.devices[1].output.volume.extra = true end },
  { tag = "sparse devices array", mutate = function(d)
      d.devices = { [1] = d.devices[1], [3] = d.devices[2] }
    end },
  { tag = "non-string name", mutate = function(d) d.devices[1].name = 42 end },
  { tag = "unavailable volume carries value", mutate = function(d)
      d.devices[1].output.volume = { available = false, settable = false, value = 12 }
    end },
  { tag = "unavailable mute carries value", mutate = function(d)
      d.devices[1].output.mute = { available = false, settable = false, value = false }
    end },
  { tag = "negative warning count", mutate = function(d) d.warning_count = -1 end },
  { tag = "excessive warning count", mutate = function(d) d.warning_count = 10001 end },
  { tag = "default role flag missing", mutate = function(d)
      d.devices[1].roles = { "system_output" }
    end },
  { tag = "extra role flag without default", mutate = function(d)
      d.defaults.system_output = nil
    end },
}

for _, case in ipairs(targeted_hostile) do
  local document = make_doc()
  case.mutate(document)
  local audio = fresh()
  audio.refresh()
  complete(1, document, 0)
  check(not audio.view().confirmed, "targeted hostile schema must reject: " .. case.tag)
end
print("  hostile schema rejection: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 2. Private UID boundary
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  -- View state must contain zero UIDs.
  local v = audio.view()
  deep_no_uid(v, UIDS, "view")
  check(v.confirmed, "view must be confirmed after valid doc")
  check(v.defaults.output and v.defaults.output.ordinal == 1, "default output ordinal")
  check(v.defaults.input  and v.defaults.input.ordinal  == 2, "default input ordinal")
  check(v.devices[1].name == "Test Speakers", "device 1 name")
  check(v.devices[2].name == "Test Microphone", "device 2 name")
  check(v.devices[1].output.mute.value == false, "confirmed false mute must be preserved")

  -- Choice objects must contain zero UIDs.
  local choices = audio.choices("output")
  for _, c in ipairs(choices) do
    deep_no_uid({ ordinal = c.ordinal, name = c.name }, UIDS, "choice")
  end

  -- Listener receives UID-free view.
  local seen = nil
  audio.subscribe(function(view) seen = view end)
  check(seen ~= nil, "subscriber must receive initial view")
  deep_no_uid(seen, UIDS, "listener-view")

  -- Module table itself must not leak state.
  for k, v in pairs(audio) do
    check(type(v) == "function", "module key '" .. k .. "' must be a function")
  end
end

do
  local document = make_doc()
  document.devices[1].name = "Output " .. UIDS[1]
  document.devices[2].name = UIDS[1] .. " input"
  local audio = fresh()
  audio.refresh()
  complete(1, document, 0)
  local view = audio.view()
  check(view.confirmed, "UID-bearing names must not invalidate otherwise valid state")
  check(view.devices[1].name == "Unnamed audio device", "own UID in name must be redacted")
  check(view.devices[2].name == "Unnamed audio device", "other device UID in name must be redacted")
  deep_no_uid(view, UIDS, "redacted-view")
end

do
  local long_uid = string.rep("L", 100)
  local document = make_doc()
  document.defaults.output = long_uid
  document.defaults.system_output = long_uid
  document.devices[1].uid = long_uid
  document.devices[1].name = long_uid
  local audio = fresh()
  audio.refresh()
  complete(1, document, 0)
  local view = audio.view()
  check(view.confirmed and view.devices[1].name == "Unnamed audio device",
        "long UID name must be redacted before truncation")
end

do
  local raw_uid = "opaque\\selector"
  local document = make_doc()
  document.defaults.output = raw_uid
  document.defaults.system_output = raw_uid
  document.devices[1].uid = raw_uid
  document.devices[1].name = "opaque/selector"
  local audio = fresh()
  audio.refresh()
  complete(1, document, 0)
  local view = audio.view()
  check(view.confirmed and view.devices[1].name == "Unnamed audio device",
        "normalized UID name must be redacted")
end
print("  private UID boundary: passed")

do
  local audio = fresh()
  local doc = make_doc()
  doc.default_settable.output = false
  audio.refresh()
  complete(1, doc, 0)
  check(not audio.role_settable("output"), "unsettable output role must fail closed")
  check(#audio.choices("output") == 0, "unsettable output role must expose no choices")
  check(audio.role_settable("input") and #audio.choices("input") == 1,
        "settable input role must retain its captured choice")
end

-- ══════════════════════════════════════════════════════════════════════
-- 3. Coalescing
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  local called = { a = 0, b = 0 }
  audio.refresh(function() called.a = called.a + 1 end)
  local coalesced = audio.refresh(function() called.b = called.b + 1 end)
  check(coalesced == false, "second refresh must coalesce (return false)")
  check(#exec_calls == 1, "coalesced to one exec call")
  complete(1, make_doc(), 0)
  check(called.a == 1 and called.b == 1, "both waiters called exactly once")
end

do
  local audio = fresh()
  local admitted = 0
  audio.refresh(function() admitted = admitted + 1 end)
  for _ = 1, 63 do audio.refresh(function() admitted = admitted + 1 end) end
  local overflow = 0
  local accepted = audio.refresh(function(ok_view, ok, reason)
    overflow = overflow + 1
    check(type(ok_view) == "table" and ok == false, "overflow callback shape")
    check(reason == "Audio refresh queue is full", "overflow safe reason")
  end)
  check(accepted == false and overflow == 1, "overflow callback must fail exactly once")
  check(#exec_calls == 1, "overflow must not start another command")
  complete(1, make_doc(), 0)
  check(admitted == 64, "all admitted waiters must run exactly once")
end
print("  coalescing: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 4. Stale callback guard
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  local first_called = false
  audio.refresh(function() first_called = true end)
  local stale_cb = exec_calls[1].callback
  -- Complete first refresh normally so in_flight clears.
  complete(1, make_doc(), 0)
  check(first_called, "first refresh callback must fire")
  first_called = false

  -- Start a new refresh (bumps generation).
  audio.refresh()
  check(#exec_calls == 2, "second refresh exec issued")

  -- Fire the OLD (stale) callback: must be silently ignored.
  stale_cb(make_doc(), 0)
  -- The second refresh is still in flight; first_called must stay false
  -- because the stale callback does nothing.
  check(not first_called, "stale callback must be ignored")
end
print("  stale callback guard: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 5. Exact argv
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  local expect_refresh = shell.command(
    { settings.paths.system_controls, "audio", "state" })
  check(exec_calls[1].command == expect_refresh, "refresh argv mismatch")
  complete(1, make_doc(), 0)

  -- set_volume
  audio.set_volume("output", 75)
  local expect_vol = shell.command(
    { settings.paths.system_controls, "audio", "set-volume", "output", "75" })
  check(exec_calls[2].command == expect_vol,
        "set_volume argv mismatch: got " .. exec_calls[2].command)

  -- Complete write, then complete post-write refresh.
  complete(2, nil, 0)
  complete(3, make_doc({ devices = {
    { uid = UIDS[1], name = "Test Speakers", directions = { "output" },
      roles = { "output", "system_output" },
      output = { volume = { available = true, settable = true, value = 75 },
                 mute = { available = true, settable = true, value = false } } },
    { uid = UIDS[2], name = "Test Microphone", directions = { "input" },
      roles = { "input" },
      input = { volume = { available = true, settable = true, value = 80 },
                mute = { available = true, settable = true, value = false } } },
  } }), 0)

  -- set_mute
  audio.set_mute("input", true)
  local expect_mute = shell.command(
    { settings.paths.system_controls, "audio", "set-mute", "input", "on" })
  check(exec_calls[4].command == expect_mute,
        "set_mute argv mismatch: got " .. exec_calls[4].command)
end
print("  exact argv: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 6. Stale choice
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  local choices = audio.choices("output")
  check(#choices >= 1, "must produce at least one output choice")

  -- Trigger a refresh so generation advances.
  audio.refresh()
  complete(2, make_doc(), 0)

  -- Now invoke the stale choice.
  local stale_ok, stale_err
  local started = choices[1].invoke(function(ok, err)
    stale_ok = ok; stale_err = err
  end)
  check(started == false, "stale choice invoke must return false")
  check(stale_ok == false, "stale choice callback must report failure")
  check(type(stale_err) == "string" and stale_err:find("refresh"),
        "stale choice error must mention refresh")
end
print("  stale choice rejection: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 7. Duplicate action
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  local choices = audio.choices("output")
  local started1 = choices[1].invoke()
  check(started1, "first action must be accepted")

  -- While first action is in flight, try another.
  local dup_ok, dup_err
  local started2 = audio.set_volume("output", 30, function(ok, err)
    dup_ok = ok; dup_err = err
  end)
  check(started2 == false, "duplicate action must return false")
  check(dup_ok == false and dup_err == "Audio controls are busy",
        "duplicate action must report busy")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local action_ok, action_error, queued = nil, nil, 0
  audio.set_volume("output", 75, function(ok, err) action_ok = ok; action_error = err end)
  local started = audio.refresh(function() queued = queued + 1 end)
  check(started == false and #exec_calls == 2,
        "refresh during action must queue without invalidating the write token")
  complete(2, nil, 0)
  check(#exec_calls == 3, "write completion must start one shared readback")
  local document = make_doc()
  document.devices[1].output.volume.value = 75
  complete(3, document, 0)
  check(action_ok == true and action_error == nil, "queued refresh must not strand action")
  check(queued == 1 and audio.view().busy == false,
        "queued waiter must run once and busy must clear")
end
print("  duplicate action rejection: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 8. Post-write refresh
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  audio.set_volume("output", 42)
  check(#exec_calls == 2, "write exec must fire")

  -- Complete the write (body deliberately ignored).
  complete(2, "garbage body that must be ignored", 0)
  check(#exec_calls == 3, "post-write refresh must auto-trigger")

  -- The post-write refresh is a full 'audio state' read.
  check(exec_calls[3].command == exec_calls[1].command,
        "post-write refresh must use identical state-read argv")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 51, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, nil, 0)
  complete(3, make_doc(), 0)
  check(result_ok == false and result_error == "Audio state changed externally",
        "unchanged overlapping-tolerance readback must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 75, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, nil, 0)
  local document = make_doc()
  document.devices[1].output.volume.value = 73
  complete(3, document, 0)
  check(result_ok == true and result_error == nil,
        "documented two-point device quantization must confirm")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 75, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, nil, 0)
  local document = make_doc()
  document.devices[1].output.volume.value = 72
  complete(3, document, 0)
  check(result_ok == false and result_error == "Audio state changed externally",
        "readback outside documented quantization tolerance must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 75, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, nil, 0)
  local document = make_doc()
  document.defaults.output = "UID-OTHER-003"
  document.devices[1].roles = { "system_output" }
  document.devices[1].output.volume.value = 75
  document.devices[#document.devices + 1] = {
    uid = "UID-OTHER-003", name = "Other output",
    directions = { "output" }, roles = { "output" },
    output = {
      volume = { available = true, settable = true, value = 75 },
      mute = { available = true, settable = true, value = false },
    },
  }
  complete(3, document, 0)
  check(result_ok == false and result_error == "Audio state changed externally",
        "changed default during readback must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 42, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, nil, 75)
  local document = make_doc()
  document.devices[1].output.volume.value = 42
  complete(3, document, 0)
  check(result_ok == false and result_error == "Audio state changed externally",
        "nonzero write exit must not be converted to success")
end
print("  post-write refresh: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 9. Preserve confirmed state on failure
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  local v1 = audio.view()
  check(v1.confirmed, "initial state must be confirmed")
  check(#v1.devices == 2, "initial device count")

  -- Second refresh fails (bad exit code).
  audio.refresh()
  complete(2, nil, 99)

  local v2 = audio.view()
  check(v2.confirmed, "confirmed must persist after failed refresh")
  check(#v2.devices == 2, "devices must persist after failed refresh")
  check(type(v2.error) == "string", "error must be set after failure")
  check(v2.devices[1].name == "Test Speakers",
        "device data must survive failure")
end
print("  confirmed state preserved on failure: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 10. Choice set-default exact argv
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  local choices = audio.choices("system_output")
  check(#choices >= 1, "system_output must produce choices")
  local default_ok, default_error
  choices[1].invoke(function(ok, err) default_ok = ok; default_error = err end)

  local expect = shell.command(
    { settings.paths.system_controls, "audio", "set-default",
      "system_output", UIDS[1] })
  check(exec_calls[2].command == expect,
        "set-default argv must carry the private UID internally")
  complete(2, nil, 0)
  complete(3, make_doc(), 0)
  check(default_ok == true and default_error == nil,
        "same-default readback must confirm set-default")

  local mute_ok, mute_error
  audio.set_mute("output", true, function(ok, err) mute_ok = ok; mute_error = err end)
  complete(4, nil, 0)
  local muted = make_doc()
  muted.devices[1].output.mute.value = true
  complete(5, muted, 0)
  check(mute_ok == true and mute_error == nil, "mute readback must confirm success")

  local mismatch_ok, mismatch_error
  audio.set_mute("output", false, function(ok, err)
    mismatch_ok = ok; mismatch_error = err
  end)
  complete(6, nil, 0)
  complete(7, muted, 0)
  check(mismatch_ok == false and mismatch_error == "Audio state changed externally",
        "unchanged mute readback must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc_with_other_output(), 0)
  local choices = audio.choices("output")
  check(#choices == 2, "two output choices required for set-default readback")
  local wrong_ok, wrong_error
  choices[2].invoke(function(ok, err) wrong_ok = ok; wrong_error = err end)
  complete(2, nil, 0)
  complete(3, make_doc_with_other_output(), 0)
  check(wrong_ok == false and wrong_error == "Audio state changed externally",
        "unchanged default readback must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc_with_other_output(), 0)
  local choices = audio.choices("output")
  local changed_ok, changed_error
  choices[2].invoke(function(ok, err) changed_ok = ok; changed_error = err end)
  complete(2, nil, 0)
  complete(3, select_other_output(make_doc_with_other_output()), 0)
  check(changed_ok == true and changed_error == nil,
        "changed default readback must confirm success")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc_with_other_output(), 0)
  local choices = audio.choices("output")
  local failed_ok, failed_error
  choices[2].invoke(function(ok, err) failed_ok = ok; failed_error = err end)
  complete(2, nil, 75)
  complete(3, select_other_output(make_doc_with_other_output()), 0)
  check(failed_ok == false and failed_error == "Audio state changed externally",
        "nonzero set-default write must fail despite desired readback")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local failed_ok, failed_error
  audio.set_mute("input", true, function(ok, err) failed_ok = ok; failed_error = err end)
  complete(2, nil, 0)
  complete(3, nil, 99)
  check(failed_ok == false and failed_error == "Audio state unavailable",
        "failed mute refresh must return a safe error")
  check(audio.view().confirmed, "failed mute refresh must preserve confirmed state")
end
print("  choice and mute readback: passed")

-- ══════════════════════════════════════════════════════════════════════

print("")
print("Audio coordinator contract tests passed")
