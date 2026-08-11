local colors = require("colors")
local settings = require("settings")

-- A hidden content-free source fingerprint makes the live release probe reject
-- a stale pre-hotload configuration without reading any user content.
sbar.add("item", "release.probe", {
  drawing = false,
  updates = false,
  icon = { drawing = false },
  label = { drawing = false, string = settings.release_fingerprint },
})

-- Left island: native Spaces, focused context, then compact device controls.
require("items.workspaces")
require("items.front_window")

-- Keep the six compact device controls left so the six stats stay clear of the notch.
require("items.connectivity")
require("items.display")
require("items.audio")
require("items.microphone")
require("items.battery")

-- Right-position items render in reverse creation order: Calendar is outermost,
-- then the six stats stay in the center of the right half.
require("items.calendar")
require("items.status")

sbar.add("bracket", "system.bracket", { "wifi", "bluetooth", "display", "audio", "microphone", "battery" }, {
  background = {
    drawing = true,
    color = colors.right_system,
    height = settings.surface_height,
    corner_radius = 0,
    border_width = 0,
    border_color = colors.transparent,
    shadow = { drawing = false },
  },
})
