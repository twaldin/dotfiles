package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path

package.loaded.colors = {
  transparent = 0, popup = 1, surface = 2, surface2 = 3, right_hover = 4,
  border = 5, primary = 6, muted = 7, normal = 6, active = 6, accent = 8,
}
package.loaded.settings = { popup_width = 280, font = "Test" }

local hover_state = setmetatable({}, { __mode = "k" })
package.loaded["lib.hover"] = {
  set_popup_open = function(item, open)
    hover_state[item] = open == true
    return true
  end,
}

local function merge(target, source)
  for key, value in pairs(source or {}) do
    if type(value) == "table" then
      target[key] = type(target[key]) == "table" and target[key] or {}
      merge(target[key], value)
    else
      target[key] = value
    end
  end
end

local function fake(name, properties)
  local item = { name = name, properties = properties or {}, subscriptions = {}, removed = false }
  function item:set(update) merge(item.properties, update) end
  function item:subscribe(events, callback)
    if type(events) ~= "table" then events = { events } end
    for _, event in ipairs(events) do
      item.subscriptions[event] = item.subscriptions[event] or {}
      item.subscriptions[event][#item.subscriptions[event] + 1] = callback
    end
  end
  return item
end

local function fire(item, event, env)
  for _, callback in ipairs(item.subscriptions[event] or {}) do callback(env or {}) end
end

local now, delayed = 0, {}
local function advance(seconds)
  local target = now + seconds
  while true do
    local selected, due
    for index, entry in ipairs(delayed) do
      if not entry.ran and entry.due <= target and (not due or entry.due < due) then
        selected, due = index, entry.due
      end
    end
    if not selected then break end
    now = delayed[selected].due
    delayed[selected].ran = true
    delayed[selected].callback()
  end
  now = target
end

local items = {}
local dynamic_count, minimum_dynamic_count, remove_count = 0, math.huge, 0
sbar = {
  add = function(kind, name, width_or_properties, properties)
    local value = properties or width_or_properties
    local item = fake(name, value)
    item.kind = kind
    items[name] = item
    if name:match("^popup%.") and name ~= "popup.controller" then
      dynamic_count = dynamic_count + 1
      minimum_dynamic_count = math.min(minimum_dynamic_count, dynamic_count)
    end
    return item
  end,
  remove = function(item)
    assert(item and not item.removed, "popup item removed once")
    item.removed = true
    remove_count = remove_count + 1
    dynamic_count = dynamic_count - 1
    minimum_dynamic_count = math.min(minimum_dynamic_count, dynamic_count)
  end,
  delay = function(seconds, callback)
    delayed[#delayed + 1] = { due = now + seconds, callback = callback, ran = false }
  end,
}

package.loaded["lib.popup"] = nil
local popup = require("lib.popup")
local colors = require("colors")

local external_state = nil
local host = fake("host", { background = { drawing = false, color = colors.transparent } })
popup.bind(host, {
  align = "right",
  right_click = function() external_state = popup.is_open(host) end,
  build = function(token)
    popup.row(host, token, "heading", { label = { string = "TEST" } })
    local action = popup.row(host, token, "action", { label = { string = "Action" } })
    popup.action(action, { idle_color = colors.muted })
  end,
})

fire(host, "mouse.clicked", { BUTTON = "left" })
assert(popup.is_open(host), "popup host opens")
assert(host.properties.popup.drawing == true, "popup draws")
assert(hover_state[host] == true, "open state reaches one host visual reducer")
assert(items["popup.host.heading"].properties.display == "active", "documented display property is used")
local token = popup.generation
local action = items["popup.host.action"]
local heading = items["popup.host.heading"]

-- A host leave starts one bounded ticket. Re-entry before its deadline cancels it.
fire(host, "mouse.exited")
advance(0.129)
assert(popup.is_open(host), "popup stays open before handoff deadline")
fire(host, "mouse.entered")
advance(0.01)
assert(popup.is_open(host), "host re-entry cancels close")

-- Direct transfer into any popup row owns the complete popup region.
fire(host, "mouse.exited")
fire(action, "mouse.entered")
fire(host, "mouse.exited.global")
fire(host, "mouse.exited")
advance(0.2)
assert(popup.is_open(host), "late host exits cannot close an entered popup row")
local ticket_before_row_exit = popup.debug_state().close_ticket
fire(action, "mouse.exited")
fire(host, "mouse.entered")
advance(0.2)
assert(popup.is_open(host), "popup-to-host transfer stays open")
assert(popup.debug_state().close_ticket > ticket_before_row_exit, "host entry invalidates prior tickets")

-- A local row exit can mean row-to-row or row-to-background and never closes.
fire(host, "mouse.exited")
fire(action, "mouse.entered")
local ticket_before_background = popup.debug_state().close_ticket
fire(action, "mouse.exited")
advance(0.2)
assert(popup.is_open(host), "row exit to popup background stays open")
assert(popup.debug_state().close_ticket == ticket_before_background, "local row exit does not create close ticket")

-- A row-global exit independently covers popup-to-outside. A duplicate host
-- global delivery cannot create a second ticket.
fire(action, "mouse.exited.global")
local union_exit_ticket = popup.debug_state().close_ticket
fire(host, "mouse.exited.global")
assert(popup.debug_state().close_ticket == union_exit_ticket, "duplicate union leave creates one close ticket")
advance(0.131)
assert(not popup.is_open(host), "row-global union exit closes after dwell")
assert(hover_state[host] == false, "close state reaches host visual reducer")

-- A row-to-background transition stays owned until a host-local exit proves the
-- pointer moved to a different bar item.
popup.open(host, {
  build = function(current_token)
    local row = popup.row(host, current_token, "action", { label = { string = "One" } })
    popup.action(row, {})
  end,
})
action = items["popup.host.action"]
fire(action, "mouse.entered")
fire(action, "mouse.exited")
fire(host, "mouse.exited")
advance(0.131)
assert(not popup.is_open(host), "host-local exit closes after leaving popup background")

-- Reconciliation keeps item identity and never removes children from an open popup.
popup.open(host, {
  build = function(current_token)
    popup.row(host, current_token, "heading", { label = { string = "TEST" } })
    local row = popup.row(host, current_token, "action", { label = { string = "One" } })
    popup.action(row, { selected = true, selected_color = 42, idle_color = colors.primary })
  end,
})
token = popup.generation
action = items["popup.host.action"]
heading = items["popup.host.heading"]
local remove_before_reconcile = remove_count
local child_count_before = dynamic_count
minimum_dynamic_count = dynamic_count
popup.rebuild(host, token, function(current_token)
  popup.row(host, current_token, "heading", { label = { string = "TEST 2" } })
  local row = popup.row(host, current_token, "action", { label = { string = "Two" } })
  popup.action(row, { selected = true, selected_color = 42, idle_color = colors.primary })
end)
assert(items["popup.host.action"] == action, "unchanged keyed row keeps object identity")
assert(items["popup.host.heading"] == heading, "stable heading keeps object identity")
assert(remove_count == remove_before_reconcile, "reconcile removes no popup children")
assert(dynamic_count == child_count_before, "reconcile keeps popup child count")
fire(action, "mouse.entered")
fire(action, "mouse.exited")
assert(action.properties.background.drawing == true, "selected action restores selected surface")
assert(action.properties.background.color == 42, "selected action restores selected color")

-- Obsolete rows become hidden. New rows are added before any close-time removal.
popup.rebuild(host, token, function(current_token)
  popup.row(host, current_token, "heading", { label = { string = "TEST 3" } })
  popup.row(host, current_token, "replacement", { label = { string = "Replacement" } })
end)
assert(action.properties.drawing == false, "obsolete keyed row is hidden")
assert(remove_count == remove_before_reconcile, "obsolete open-session rows are not removed")
assert(dynamic_count >= child_count_before, "replacement is added without zero-child transition")
assert(minimum_dynamic_count > 0, "open popup never reached zero children")

-- Stable click metadata is replaced by the latest render, without new subscriptions.
local clicks = 0
popup.rebuild(host, token, function(current_token)
  popup.row(host, current_token, "heading", {})
  local row = popup.row(host, current_token, "replacement", {})
  popup.action(row, {})
  popup.on_click(row, function() clicks = clicks + 10 end)
end)
local replacement = items["popup.host.replacement"]
fire(replacement, "mouse.clicked", { BUTTON = "left" })
assert(clicks == 10, "current stable click metadata runs once")
popup.rebuild(host, token, function(current_token)
  popup.row(host, current_token, "heading", {})
  local row = popup.row(host, current_token, "replacement", {})
  popup.action(row, {})
  popup.on_click(row, function() clicks = clicks + 1 end)
end)
fire(replacement, "mouse.clicked", { BUTTON = "left" })
assert(clicks == 11, "reconcile replaces rather than stacks click callback")

-- A timer from generation N cannot close a replacement popup in generation N+1.
fire(host, "mouse.exited.global")
local other = fake("other", {})
popup.open(other, { build = function(current_token) popup.row(other, current_token, "heading", {}) end })
advance(0.2)
assert(popup.is_open(other), "stale generation timer cannot close replacement host")
popup.close()

-- External right-click actions close the current popup before launch.
fire(host, "mouse.clicked", { BUTTON = "left" })
assert(popup.is_open(host), "host reopened")
fire(host, "mouse.clicked", { BUTTON = "right" })
assert(external_state == false, "right-click callback observes popup already closed")
assert(not popup.is_open(host), "right-click leaves no popup")

print("SketchyBar popup persistent ownership and reconciliation passed")
