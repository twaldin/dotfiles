local colors = require("colors")
local settings = require("settings")

sbar.bar({
  position = "top",
  height = settings.bar_height,
  color = colors.bar,
  display = "all",
  topmost = false,
  sticky = true,
  padding_left = 8,
  padding_right = 8,
  margin = 0,
  y_offset = 0,
  corner_radius = 0,
  border_width = 0,
  border_color = colors.transparent,
  blur_radius = 0,
  shadow = false,
  font_smoothing = true,
})
