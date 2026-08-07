local colors = require("colors")
local settings = require("settings")

sbar.default({
  updates = "when_shown",
  padding_left = 0,
  padding_right = 0,
  background = {
    drawing = false,
    color = colors.transparent,
    border_width = 0,
    border_color = colors.transparent,
    corner_radius = 0,
  },
  icon = {
    color = colors.normal,
    highlight_color = colors.active,
    padding_left = 3,
    padding_right = 3,
    font = { family = settings.font, style = "Regular", size = 14.0 },
    background = { drawing = false },
    shadow = { drawing = false },
  },
  label = {
    color = colors.normal,
    highlight_color = colors.active,
    padding_left = 2,
    padding_right = 3,
    font = { family = settings.font, style = "Regular", size = 11.0 },
    background = { drawing = false },
    shadow = { drawing = false },
  },
  popup = {
    align = "left",
    y_offset = 0,
    blur_radius = 0,
    background = {
      color = colors.popup,
      border_width = 1,
      border_color = colors.border,
      corner_radius = 12,
      shadow = { drawing = false },
    },
  },
})
-- Shadow colors can implicitly enable SketchyBar shadows. Apply drawing-only
-- overrides after every visual default so live bounds equal configured widths.
sbar.default({
  icon = { shadow = { drawing = false } },
  label = { shadow = { drawing = false } },
  popup = { background = { shadow = { drawing = false } } },
})
