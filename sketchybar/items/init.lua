local colors = require("colors")

-- Left island: native Spaces at the outside edge, then focused context.
require("items.workspaces")
require("items.media") -- provider remains available but is hidden at rest
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
    color = colors.surface,
    height = 26,
    corner_radius = 9,
    border_width = 1,
    border_color = colors.border,
    shadow = { drawing = false },
  },
})
