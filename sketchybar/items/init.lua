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

-- Left island: native Spaces at the outside edge, then focused context.
require("items.workspaces")
require("items.media") -- fixed public-unavailable containment surface
require("items.front_window")

-- Right island creation is reversed by SketchyBar: create the outer controls
-- first so time remains at the inner edge of the island.
require("items.connectivity")
require("items.audio")
require("items.microphone")
require("items.battery")
require("items.status")
require("items.calendar")

sbar.add("bracket", "system.bracket", { "wifi", "bluetooth", "audio", "microphone", "battery", "status" }, {
  background = {
    drawing = true,
    color = colors.right_system,
    height = 26,
    corner_radius = 0,
    border_width = 0,
    border_color = colors.transparent,
    shadow = { drawing = false },
  },
})
