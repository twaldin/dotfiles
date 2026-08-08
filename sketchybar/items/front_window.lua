local colors = require("colors")
local settings = require("settings")
local popup = require("lib.popup")
local hover = require("lib.hover")

local item = sbar.add("item", "front_window", {
  position = "left",
  updates = false,
  width = 100,
  align = "right",
  padding_left = 8,
  padding_right = 0,
  icon = { string = "󰖲", drawing = true, color = colors.muted, width = 22, padding_left = 4, padding_right = 0, font = { family = settings.app_font, style = "Regular", size = 15.0 } },
  label = { string = "WINDOW", color = colors.muted, max_chars = 11, width = 74, align = "left", padding_left = 4, padding_right = 6 },
  background = { drawing = true, color = colors.surface, height = 26, corner_radius = 0 },
})

hover.bind(item, { idle_background = true, idle_color = colors.muted })

popup.bind(item, {
  align = "left",
  idle_background = colors.surface,
  build = function(token)
    popup.row(item, token, "heading", { label = { string = "FRONT WINDOW", color = colors.primary } })
    popup.row(item, token, "identity", { label = { string = "App / title  Native privacy view", color = colors.muted } })
    popup.row(item, token, "inventory", { label = { string = "Window list  Native privacy view", color = colors.muted } })
    popup.row(item, token, "focus", { label = { string = "Focus window  Provider unavailable", color = colors.dim } })
    popup.row(item, token, "layout", { label = { string = "Move / swap / resize  Unavailable", color = colors.dim } })
    popup.row(item, token, "state", { label = { string = "Close / minimize / zoom  Unavailable", color = colors.dim } })
    popup.row(item, token, "topology", { label = { string = "Space / display actions  Unavailable", color = colors.dim } })
  end,
})

settings.on_q_layout(function(layout)
  item:set({ drawing = layout.front ~= "hidden" })
end)

return item
