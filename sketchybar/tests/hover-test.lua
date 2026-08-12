package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. package.path

local delayed = {}
local popup = { close_count = 0 }
function popup.is_open() return false end
function popup.schedule_close() popup.close_count = popup.close_count + 1 end
package.loaded["lib.popup"] = popup
package.loaded.colors = {
  primary = 1, surface = 2, surface2 = 3, border = 4, accent = 5, hover = 6,
  right_hover = 6, warning = 7, critical = 8, red = 11,
  state = { actionable = 10 },
}
sbar = {
  delay = function(seconds, callback)
    delayed[#delayed + 1] = { seconds = seconds, callback = callback, ran = false }
  end,
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do result[key] = copy(child) end
  return result
end

local function merge(target, source)
  for key, child in pairs(source or {}) do
    if type(child) == "table" then
      target[key] = type(target[key]) == "table" and target[key] or {}
      merge(target[key], child)
    else
      target[key] = child
    end
  end
end

local function fake(name)
  local item = { name = name, properties = {}, history = {}, subscriptions = {} }
  function item:set(update)
    item.history[#item.history + 1] = copy(update)
    merge(item.properties, update)
  end
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

local function run_delay(index)
  local entry = assert(delayed[index], "missing synthetic delayed callback")
  assert(not entry.ran, "synthetic delayed callback ran twice")
  entry.ran = true
  entry.callback()
end

local function equal(actual, expected, label)
  assert(actual == expected, label)
end

package.loaded["lib.hover"] = nil
local hover = require("lib.hover")
local colors = require("colors")

-- The legacy item API keeps its existing immediate item-background behavior.
local legacy = fake("legacy")
hover.bind(legacy, { idle_color = 9 })
equal(legacy.properties.background.drawing, false, "legacy idle background")
fire(legacy, "mouse.entered")
equal(hover.is_active(legacy), true, "legacy active owner")
equal(legacy.properties.background.color, colors.hover, "legacy hover fill")
equal(legacy.properties.icon.color, colors.primary, "legacy hover icon")
equal(hover.foreground(legacy, 9), colors.primary, "provider render preserves normal hover foreground")
equal(hover.foreground(legacy, colors.warning), colors.warning, "warning survives hover")
equal(hover.foreground(legacy, colors.critical), colors.critical, "critical survives hover")
equal(hover.foreground(legacy, colors.state.actionable), colors.state.actionable,
  "actionable safety state survives hover")
equal(hover.foreground(legacy, colors.red), colors.red, "red safety state survives hover")
equal(hover.foreground(legacy, 12), colors.primary,
  "ordinary domain color keeps the shared hover cue")
equal(hover.foreground(legacy, 12, true), 12,
  "explicit semantic role preserves its idle color")
local semantic = fake("semantic")
hover.bind(semantic, { idle_color = 12, preserve_hover_color = true })
fire(semantic, "mouse.entered")
equal(semantic.properties.icon.color, 12,
  "role-bound semantic color survives hover repaint")
fire(semantic, "mouse.exited")
for _, update in ipairs(legacy.history) do
  if update.background then
    equal(update.background.border_color, nil, "legacy hover never changes border")
    equal(update.background.height, nil, "legacy hover never changes height")
    equal(update.background.corner_radius, nil, "legacy hover never changes radius")
  end
end
fire(legacy, "mouse.exited")
equal(hover.is_active(legacy), false, "legacy immediate exit")
equal(legacy.properties.background.drawing, false, "legacy reset drawing")
equal(legacy.properties.icon.color, 9, "legacy reset icon")

-- Popup-open and pointer hover use one reducer. Popup fill has priority, and a
-- click-close while the pointer remains on the host returns to hover fill.
fire(legacy, "mouse.entered")
equal(hover.set_popup_open(legacy, true), true, "bound popup host accepts open state")
equal(legacy.properties.background.color, colors.right_hover, "open popup owns active host fill")
fire(legacy, "mouse.exited")
equal(legacy.properties.background.color, colors.right_hover, "open popup survives host hover reset")
equal(legacy.properties.background.drawing, true, "open popup host remains drawn")
fire(legacy, "mouse.entered")
hover.set_popup_open(legacy, false)
equal(legacy.properties.background.color, colors.hover, "close while hovered restores hover fill")
fire(legacy, "mouse.exited")
equal(legacy.properties.background.drawing, false, "closed unhovered popup host restores idle drawing")

local event_item, date_item = fake("calendar.next"), fake("calendar")
local event_surface, date_surface = fake("calendar.event.bracket"), fake("calendar.date.bracket")
local event_idle, date_idle = 20, 21
hover.bind_surface(event_item, event_surface, { idle_surface = function() return event_idle end })
hover.bind_surface(date_item, date_surface, { idle_surface = function() return date_idle end })
equal(event_surface.properties.background.drawing, true, "event surface always drawn")
equal(date_surface.properties.background.drawing, true, "date surface always drawn")
equal(event_surface.properties.background.color, event_idle, "event dynamic idle fill")
equal(date_surface.properties.background.color, date_idle, "date dynamic idle fill")
equal(event_surface.properties.background.border_color, colors.border, "idle border cue")
equal(#event_item.history, 0, "surface binding never paints event child")
equal(#date_item.history, 0, "surface binding never paints date child")

-- Entry and repeated entry own and paint the whole event surface once.
fire(event_item, "mouse.entered")
equal(hover.is_active(event_item), true, "event logical owner")
equal(event_surface.properties.background.color, colors.hover, "event hover fill")
equal(event_surface.properties.background.border_color, colors.border, "event hover border stays stable")
local event_history_after_enter = #event_surface.history
fire(event_item, "mouse.entered")
equal(#event_surface.history, event_history_after_enter, "repeated event entry is idempotent")

-- A local exit is deferred. Transfer invalidates its callback before it runs.
fire(event_item, "mouse.exited")
equal(delayed[#delayed].seconds, 0.05, "bounded local exit delay")
local stale_event_leave = #delayed
equal(event_surface.properties.background.color, colors.hover, "event stays highlighted during deferred exit")
fire(date_item, "mouse.entered")
equal(hover.is_active(date_item), true, "date owns after transfer")
equal(event_surface.properties.background.color, event_idle, "event resets on owner transfer")
equal(date_surface.properties.background.color, colors.hover, "date highlights on transfer")
local date_history_before_stale = #date_surface.history
run_delay(stale_event_leave)
equal(hover.is_active(date_item), true, "stale event callback keeps date owner")
equal(#date_surface.history, date_history_before_stale, "stale event callback does not repaint date")

-- clear(except) uses logical item owners and dynamic idle values are read at reset.
hover.clear(date_item)
equal(hover.is_active(date_item), true, "clear except preserves date")
date_idle = 31
hover.clear(event_item)
equal(hover.is_active(date_item), false, "clear other resets date")
equal(date_surface.properties.background.color, date_idle, "dynamic date idle fill reevaluated")

-- Re-entry cancels the current local leave; an old callback cannot reset it.
fire(event_item, "mouse.entered")
fire(event_item, "mouse.exited")
local canceled_leave = #delayed
fire(event_item, "mouse.entered")
run_delay(canceled_leave)
equal(hover.is_active(event_item), true, "re-entry invalidates local leave")
equal(event_surface.properties.background.color, colors.hover, "re-entry keeps hover fill")

-- Refreshing warning content during hover is not changed by the surface API.
event_item:set({ icon = { color = 99 }, label = { color = 99 } })
local child_history = #event_item.history
fire(event_item, "mouse.entered")
equal(#event_item.history, child_history, "surface hover never hides warning colors")

-- A broadcast global exit resets the one active owner and schedules one close.
popup.close_count = 0
fire(event_item, "mouse.exited.global")
fire(date_item, "mouse.exited.global")
equal(hover.active, nil, "global exit clears owner")
equal(event_surface.properties.background.color, event_idle, "global exit restores event")
equal(popup.close_count, 0, "calendar surface hover never schedules popup close")

-- Targeted synthetic events affect only the named one-member group.
fire(date_item, "sketchybar_test_hover", { TARGET = "calendar.next" })
equal(hover.active, nil, "wrong synthetic target ignored")
fire(date_item, "sketchybar_test_hover", { TARGET = "calendar" })
equal(hover.is_active(date_item), true, "date synthetic target enters")
fire(event_item, "sketchybar_test_hover", { TARGET = "calendar.next" })
equal(hover.is_active(event_item), true, "synthetic target transfers owner")
equal(date_surface.properties.background.color, date_idle, "synthetic transfer resets date")
fire(event_item, "sketchybar_test_hover_exit", { TARGET = "calendar.next" })
equal(hover.active, nil, "synthetic target exits")

print("SketchyBar hover surface state passed")
