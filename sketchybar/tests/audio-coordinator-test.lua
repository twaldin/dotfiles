local source = debug.getinfo(1, "S").source
local script = source:sub(1, 1) == "@" and source:sub(2) or source
local config_dir = script:match("^(.*)/tests/[^/]+$")
  or os.getenv("SKETCHYBAR_CONFIG_DIR")
if not config_dir or config_dir == "" then error("cannot determine SketchyBar config directory") end
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path

-- ── Minimal sbar mock ─────────────────────────────────────────────────
-- Captures every exec call; tests drive callbacks manually.

local exec_calls = {}
sbar = {
  exec = function(command, callback)
    exec_calls[#exec_calls + 1] = { command = command, callback = callback }
  end,
}

local settings = { paths = { audio_state = "/fixed/audio-state" } }
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

local KEYS = { string.rep("a", 64), string.rep("b", 64) }
local OTHER_KEY = string.rep("c", 64)
local CORE_IDS = { "CoreAudio raw output identity", "CoreAudio raw input identity" }

local function make_doc(overrides)
  local doc = {
    schema = 1, ok = true, warning_count = 0,
    defaults = { output = KEYS[1], system_output = KEYS[1], input = KEYS[2] },
    default_settable = { output = true, system_output = true, input = true },
    devices = {
      {
        key = KEYS[1], name = "Test Speakers",
        directions = { "output" },
        eligible_roles = { "output", "system_output" },
        roles      = { "output", "system_output" },
        output = {
          volume = { available = true, settable = true, value = 50 },
          mute   = { available = true, settable = true, value = false },
        },
      },
      {
        key = KEYS[2], name = "Test Microphone",
        directions = { "input" },
        eligible_roles = { "input" },
        roles      = { "input" },
        input = {
          volume = { available = true, settable = true, value = 80 },
          mute   = { available = true, settable = true, value = false },
          active = false,
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
    key = OTHER_KEY, name = "Other output",
    directions = { "output" }, eligible_roles = { "output", "system_output" }, roles = {},
    output = {
      volume = { available = true, settable = true, value = 25 },
      mute = { available = true, settable = true, value = false },
    },
  }
  return doc
end

local function select_other_output(doc)
  doc.defaults.output = OTHER_KEY
  doc.devices[1].roles = { "system_output" }
  doc.devices[3].roles = { "output" }
  return doc
end

local function complete(index, doc, code)
  exec_calls[index].callback(doc, code or 0)
end

local function write_doc(action, role, key, observed)
  local doc = { schema = 1, ok = true, action = action, role = role, key = key }
  if action == "set_volume" then doc.volume = observed end
  if action == "set_mute" then doc.mute = observed end
  return doc
end

-- Deep scanner: rejects handle strings and "key"/"by_key" keys.
local function deep_no_key(value, handles, path, visited)
  visited = visited or {}
  path    = path or "root"
  if type(value) == "string" then
    for _, key in ipairs(handles) do
      check(value ~= key, "handle leaked as value at " .. path .. ": " .. value)
    end
  elseif type(value) == "table" and not visited[value] then
    visited[value] = true
    for k, v in pairs(value) do
      if type(k) == "string" then
        check(k ~= "key" and k ~= "by_key",
              "handle key '" .. k .. "' found at " .. path)
      end
      if type(v) ~= "function" then
        deep_no_key(v, handles, path .. "." .. tostring(k), visited)
      end
    end
  end
end

-- ══════════════════════════════════════════════════════════════════════
-- 1. Hostile schema rejection
-- ══════════════════════════════════════════════════════════════════════

local hostile_mutations = {
  { tag = "non-Boolean default capability", mutate = function(d)
      d.default_settable.output = "true"
    end },
  { tag = "missing default_settable", mutate = function(d)
      d.default_settable = nil
    end },
  { tag = "wrong schema", mutate = function(d) d.schema = 2 end },
  { tag = "ok=false", mutate = function(d) d.ok = false end },
  { tag = "float warning_count", mutate = function(d) d.warning_count = 1.5 end },
  { tag = "duplicate handles", mutate = function(d)
      d.devices[2].key = KEYS[1]
    end },
  { tag = "settable without available", mutate = function(d)
      d.devices[1].output.volume = {
        available = false, settable = true, value = nil,
      }
    end },
  { tag = "volume > 100", mutate = function(d)
      d.devices[1].output.volume.value = 101
    end },
  { tag = "direction declared, data missing", mutate = function(d)
      d.devices[1].output = nil
    end },
  { tag = "default references missing device", mutate = function(d)
      d.defaults.output = OTHER_KEY
    end },
  { tag = "default direction mismatch", mutate = function(d)
      d.defaults.output = KEYS[2]
    end },
  { tag = "available but value nil", mutate = function(d)
      d.devices[1].output.volume.value = nil
    end },
  { tag = "NaN volume", mutate = function(d)
      d.devices[1].output.volume.value = 0/0
    end },
  { tag = "duplicate direction entry", mutate = function(d)
      d.devices[1].directions = { "output", "output" }
    end },
  { tag = "undeclared direction data present", mutate = function(d)
      d.devices[1].input = d.devices[2].input
    end },
  { tag = "control char in handle", mutate = function(d)
      d.devices[1].key = "a\tb"
    end },
  { tag = "mute value is number", mutate = function(d)
      d.devices[1].output.mute.value = 1
    end },
  { tag = "active use is number", mutate = function(d)
      d.devices[2].input.active = 1
    end },
  { tag = "active use on output", mutate = function(d)
      d.devices[1].output.active = false
    end },
  { tag = "active use on duplex device", mutate = function(d)
      d.devices[2].directions = { "input", "output" }
      d.devices[2].output = {
        volume = { available = true, settable = true, value = 25 },
        mute = { available = true, settable = true, value = false },
      }
    end },
  { tag = "empty handle", mutate = function(d)
      d.devices[1].key = ""
    end },
  { tag = "negative volume", mutate = function(d)
      d.devices[1].output.volume.value = -1
    end },
  { tag = "non-array devices (hash key)", mutate = function(d)
      d.devices.extra = d.devices[1]
    end },
}

for _, case in ipairs(hostile_mutations) do
  local doc = make_doc()
  case.mutate(doc)
  local audio = fresh()
  audio.refresh()
  complete(1, doc, 0)
  check(not audio.view().confirmed,
        "single-mutation hostile schema must reject: " .. case.tag)
end

local hostile_documents = {
  { tag = "non-table document", doc = "not a table" },
  { tag = "nil document", doc = nil },
}

for _, case in ipairs(hostile_documents) do
  local audio = fresh()
  audio.refresh()
  complete(1, case.doc, 0)
  check(not audio.view().confirmed,
        "primitive hostile document must reject: " .. case.tag)
end

local targeted_hostile = {
  { tag = "raw CoreAudio identity in handle field", mutate = function(d)
      d.devices[1].key = CORE_IDS[1]
    end },
  { tag = "unknown document field", mutate = function(d) d.extra = true end },
  { tag = "unknown defaults field", mutate = function(d) d.defaults.extra = true end },
  { tag = "unknown device field", mutate = function(d) d.devices[1].extra = true end },
  { tag = "unknown direction field", mutate = function(d) d.devices[1].output.extra = true end },
  { tag = "unknown capability field", mutate = function(d) d.devices[1].output.volume.extra = true end },
  { tag = "eligibility direction mismatch", mutate = function(d)
      d.devices[2].eligible_roles = { "output" }
    end },
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
-- 2. Private handle boundary
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  -- View state must contain zero handles.
  local v = audio.view()
  deep_no_key(v, KEYS, "view")
  check(v.confirmed, "view must be confirmed after valid doc")
  check(v.defaults.output and v.defaults.output.ordinal == 1, "default output ordinal")
  check(v.defaults.input  and v.defaults.input.ordinal  == 2, "default input ordinal")
  check(v.devices[1].name == "Test Speakers", "device 1 name")
  check(v.devices[2].name == "Test Microphone", "device 2 name")
  check(v.devices[1].output.mute.value == false, "confirmed false mute must be preserved")
  check(v.devices[2].input.active == false,
        "confirmed false input active-use state must be preserved")

  -- Choice objects must contain zero handles.
  local choices = audio.choices("output")
  for _, c in ipairs(choices) do
    deep_no_key({ ordinal = c.ordinal, name = c.name }, KEYS, "choice")
  end

  -- Listener receives handle-free view.
  local seen = nil
  audio.subscribe(function(view) seen = view end)
  check(seen ~= nil, "subscriber must receive initial view")
  deep_no_key(seen, KEYS, "listener-view")

  -- Module table itself must not leak state.
  for k, v in pairs(audio) do
    check(type(v) == "function", "module key '" .. k .. "' must be a function")
  end
end

do
  local document = make_doc()
  document.devices[1].name = "Output " .. KEYS[1]
  document.devices[2].name = KEYS[1] .. " input"
  local audio = fresh()
  audio.refresh()
  complete(1, document, 0)
  local view = audio.view()
  check(view.confirmed, "handle-bearing names must not invalidate otherwise valid state")
  check(view.devices[1].name == "Unnamed audio device", "own handle in name must be redacted")
  check(view.devices[2].name == "Unnamed audio device", "other device handle in name must be redacted")
  deep_no_key(view, KEYS, "redacted-view")
end

do
  local audio = fresh()
  local doc = make_doc()
  doc.devices[2].input.active = true
  audio.refresh()
  complete(1, doc, 0)
  check(audio.view().devices[2].input.active == true,
        "confirmed true input active-use state must be preserved")
end

do
  local audio = fresh()
  local doc = make_doc()
  doc.devices[2].input.active = nil
  audio.refresh()
  complete(1, doc, 0)
  check(audio.view().confirmed
        and audio.view().devices[2].input.active == nil,
        "absent input active-use state must remain omitted")
end

print("  opaque handle and active-use boundary: passed")

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

do
  local audio = fresh()
  local doc = make_doc_with_other_output()
  doc.devices[3].eligible_roles = {}
  audio.refresh()
  complete(1, doc, 0)
  local choices = audio.choices("output")
  check(#choices == 1 and choices[1].name == "Test Speakers",
        "ineligible output devices must not render as choices")
end

do
  local audio = fresh()
  local doc = make_doc_with_other_output()
  doc.defaults.system_output = nil
  doc.devices[1].roles = { "output" }
  audio.refresh()
  complete(1, doc, 0)
  check(audio.role_settable("system_output"),
        "unknown default must remain distinct from an unsettable role")
  local unavailable = audio.choices("system_output")
  check(#unavailable == 2,
        "unknown default must keep eligible recovery devices visible")
  for _, choice in ipairs(unavailable) do
    check(choice.available == false and choice.invoke == nil
          and choice.reason == "current system alert device unavailable",
          "unknown default recovery choice must be disabled with an exact reason")
  end
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
  audio.refresh()
  check(audio.refresh(nil, true) == false,
        "busy freshness request must coalesce")
  complete(1, make_doc(), 0)
  check(#exec_calls == 2
        and exec_calls[2].command == shell.command(
          { settings.paths.audio_state, "audio", "state" }),
        "coalesced freshness request must retry immediately")
  complete(2, make_doc(), 0)
  check(#exec_calls == 2 and audio.view().confirmed,
        "freshness retry must settle without a loop")
end

do
  local audio = fresh()
  local doc = make_doc()
  doc.devices[2].input.active = true
  audio.refresh()
  complete(1, doc, 0)
  audio.refresh()
  check(audio.refresh(nil, true) == false,
        "busy time-sensitive refresh must coalesce")
  local cleared = audio.view()
  check(cleared.confirmed and cleared.devices[2].name == "Test Microphone"
        and cleared.devices[2].input.active == nil,
        "busy freshness tick must hide only the time-sensitive claim")
  complete(2, doc, 0)
  check(#exec_calls == 3 and audio.view().devices[2].input.active == true,
        "completed read must restore confirmed active-use state and retry")
  complete(3, doc, 0)
  check(#exec_calls == 3 and audio.view().devices[2].input.active == true,
        "busy freshness retry must settle with confirmed state")
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
do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local choice = audio.choices("output")[1]
  local controls = audio.controls("output")
  check(choice ~= nil and controls ~= nil, "confirmed actions must be available")
  audio.refresh()
  local before = #exec_calls
  local choice_ok, choice_error
  local control_ok, control_error
  choice.invoke(function(ok, err) choice_ok = ok; choice_error = err end)
  controls.set_volume(60, function(ok, err) control_ok = ok; control_error = err end)
  check(#exec_calls == before, "actions during a poll must not start another command")
  check(choice_ok == false and choice_error == "Audio controls are busy",
        "choice during a poll must report busy, not stale")
  check(control_ok == false and control_error == "Audio controls are busy",
        "control during a poll must report busy, not stale")
  complete(2, make_doc(), 0)
  local stale_ok, stale_error
  check(controls.set_volume(60, function(ok, err)
          stale_ok = ok; stale_error = err
        end) == false,
        "a control must become stale after confirmed state replacement")
  check(stale_ok == false and stale_error:find("refresh", 1, true),
        "confirmed state replacement must retain the stale-control guard")
end
print("  coalescing and in-flight action classification: passed")

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
    { settings.paths.audio_state, "audio", "state", "begin" })
  check(exec_calls[1].command == expect_refresh, "refresh argv mismatch")
  complete(1, make_doc(), 0)

  -- set_volume
  audio.set_volume("output", 75)
  local expect_vol = shell.command(
    { settings.paths.audio_state, "audio", "set-volume", "output", "75", KEYS[1] })
  check(exec_calls[2].command == expect_vol,
        "set_volume argv mismatch: got " .. exec_calls[2].command)

  -- Complete write, then complete post-write refresh.
  complete(2, write_doc("set_volume", "output", KEYS[1], 75), 0)
  complete(3, make_doc({ devices = {
    { key = KEYS[1], name = "Test Speakers", directions = { "output" },
      eligible_roles = { "output", "system_output" },
      roles = { "output", "system_output" },
      output = { volume = { available = true, settable = true, value = 75 },
                 mute = { available = true, settable = true, value = false } } },
    { key = KEYS[2], name = "Test Microphone", directions = { "input" },
      eligible_roles = { "input" },
      roles = { "input" },
      input = { volume = { available = true, settable = true, value = 80 },
                mute = { available = true, settable = true, value = false } } },
  } }), 0)

  -- set_mute
  audio.set_mute("input", true)
  local expect_mute = shell.command(
    { settings.paths.audio_state, "audio", "set-mute", "input", "on", KEYS[2] })
  check(exec_calls[4].command == expect_mute,
        "set_mute argv mismatch: got " .. exec_calls[4].command)
end
print("  exact opaque argv: passed")

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
do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local controls = audio.controls("output")
  check(controls ~= nil, "output controls must bind to the confirmed generation")
  audio.refresh()
  complete(2, make_doc(), 0)
  local stale_ok, stale_error
  local before = #exec_calls
  local started = controls.set_volume(60, function(ok, err)
    stale_ok = ok; stale_error = err
  end)
  check(started == false and #exec_calls == before,
        "stale volume control must reject before command execution")
  check(stale_ok == false and type(stale_error) == "string"
        and stale_error:find("refresh"), "stale control must request refresh")
end
print("  stale choice and control rejection: passed")

-- ══════════════════════════════════════════════════════════════════════
-- 7. Duplicate action
-- ══════════════════════════════════════════════════════════════════════

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)

  local choices = audio.choices("output")
  local controls = audio.controls("output")
  local started1 = choices[1].invoke()
  check(started1, "first action must be accepted")

  -- Closures captured before the action remain tied to the same confirmed state.
  local choice_ok, choice_error, control_ok, control_error
  local choice_started = choices[1].invoke(function(ok, err)
    choice_ok = ok; choice_error = err
  end)
  local control_started = controls.set_volume(30, function(ok, err)
    control_ok = ok; control_error = err
  end)
  check(choice_started == false and choice_ok == false
        and choice_error == "Audio controls are busy",
        "captured choice during an action must report busy, not stale")
  check(control_started == false and control_ok == false
        and control_error == "Audio controls are busy",
        "captured control during an action must report busy, not stale")

  -- A newly resolved control must report the same single-action gate.
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
  complete(2, write_doc("set_volume", "output", KEYS[1], 75), 0)
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

  -- A malformed write body still causes a fresh read, but cannot confirm success.
  complete(2, "garbage body that must be ignored", 0)
  check(#exec_calls == 3, "post-write refresh must auto-trigger")

  -- The post-write refresh is a full state read in the established session.
  check(exec_calls[3].command == shell.command(
          { settings.paths.audio_state, "audio", "state" }),
        "post-write refresh must reuse the established opaque session")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 51, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, write_doc("set_volume", "output", KEYS[1], 51), 0)
  complete(3, make_doc(), 0)
  check(result_ok == false and result_error == "Audio state changed externally",
        "unchanged helper-observed readback must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 75, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, write_doc("set_volume", "output", KEYS[1], 73), 0)
  local document = make_doc()
  document.devices[1].output.volume.value = 73
  complete(3, document, 0)
  check(result_ok == true and result_error == nil,
        "exact helper-observed device quantization must confirm")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 75, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, write_doc("set_volume", "output", KEYS[1], 73), 0)
  local document = make_doc()
  document.devices[1].output.volume.value = 72
  complete(3, document, 0)
  check(result_ok == false and result_error == "Audio state changed externally",
        "readback different from helper-observed quantization must fail")
end

do
  local audio = fresh()
  audio.refresh()
  complete(1, make_doc(), 0)
  local result_ok, result_error
  audio.set_volume("output", 75, function(ok, err) result_ok = ok; result_error = err end)
  complete(2, write_doc("set_volume", "output", KEYS[1], 75), 0)
  local document = make_doc()
  document.defaults.output = OTHER_KEY
  document.devices[1].roles = { "system_output" }
  document.devices[1].output.volume.value = 75
  document.devices[#document.devices + 1] = {
    key = OTHER_KEY, name = "Other output",
    directions = { "output" }, eligible_roles = { "output" }, roles = { "output" },
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
  check(v1.confirmed and v1.actions_available, "initial state must be actionable")
  check(#v1.devices == 2, "initial device count")
  local prior_choice = audio.choices("output")[1]
  local prior_controls = audio.controls("output")

  -- Second refresh fails (bad exit code).
  audio.refresh()
  complete(2, nil, 99)

  local v2 = audio.view()
  check(v2.confirmed, "confirmed must persist after failed refresh")
  check(#v2.devices == 2, "devices must persist after failed refresh")
  check(type(v2.error) == "string", "error must be set after failure")
  check(v2.devices[1].name == "Test Speakers",
        "device data must survive failure")
  check(v2.devices[2].input.active == nil,
        "failed refresh must clear stale microphone active-use claims")
  check(v2.actions_available == false and #audio.choices("output") == 0
        and audio.controls("output") == nil,
        "failed refresh must disable newly resolved actions until session recovery")
  local before = #exec_calls
  local choice_ok, choice_error, control_ok, control_error
  check(prior_choice.invoke(function(ok, err)
          choice_ok = ok; choice_error = err
        end) == false,
        "choice captured before failed refresh must be refused")
  check(prior_controls.set_volume(60, function(ok, err)
          control_ok = ok; control_error = err
        end) == false,
        "control captured before failed refresh must be refused")
  check(#exec_calls == before and choice_ok == false and control_ok == false
        and choice_error:find("refresh", 1, true)
        and control_error:find("refresh", 1, true),
        "failed refresh must invalidate old-session action surfaces before writes")
  audio.refresh()
  check(exec_calls[3].command == shell.command(
          { settings.paths.audio_state, "audio", "state", "begin" }),
        "a failed refresh must force a fresh opaque session")
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
    { settings.paths.audio_state, "audio", "set-default",
      "system_output", KEYS[1], KEYS[1] })
  check(exec_calls[2].command == expect,
        "set-default argv must carry the opaque handle only")
  complete(2, write_doc("set_default", "system_output", KEYS[1]), 0)
  complete(3, make_doc(), 0)
  check(default_ok == true and default_error == nil,
        "same-default readback must confirm set-default")

  local mute_ok, mute_error
  audio.set_mute("output", true, function(ok, err) mute_ok = ok; mute_error = err end)
  complete(4, write_doc("set_mute", "output", KEYS[1], true), 0)
  local muted = make_doc()
  muted.devices[1].output.mute.value = true
  complete(5, muted, 0)
  check(mute_ok == true and mute_error == nil, "mute readback must confirm success")

  local mismatch_ok, mismatch_error
  audio.set_mute("output", false, function(ok, err)
    mismatch_ok = ok; mismatch_error = err
  end)
  complete(6, write_doc("set_mute", "output", KEYS[1], false), 0)
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
  complete(2, write_doc("set_default", "output", OTHER_KEY), 0)
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
  complete(2, write_doc("set_default", "output", OTHER_KEY), 0)
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
  complete(2, write_doc("set_mute", "input", KEYS[2], true), 0)
  complete(3, nil, 99)
  check(failed_ok == false and failed_error == "Audio state unavailable",
        "failed mute refresh must return a safe error")
  check(audio.view().confirmed, "failed mute refresh must preserve confirmed state")
end
print("  choice and mute readback: passed")

-- ══════════════════════════════════════════════════════════════════════

print("")
print("Audio coordinator contract tests passed")
