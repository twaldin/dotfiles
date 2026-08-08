local colors = require("colors")
local settings = require("settings")
local popup = require("lib.popup")
local hover = require("lib.hover")

local item = sbar.add("item", "battery", {
  position = "right",
  updates = false,
  width = settings.control_width,
  icon = { string = "󰂑", color = colors.muted, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 15.0 } },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 0 },
})

hover.bind(item, { idle_color = colors.muted })

popup.bind(item, {
  align = "right",
  build = function(token)
    popup.row(item, token, "heading", { label = { string = "BATTERY / POWER", color = colors.primary } })
    popup.row(item, token, "state", { label = { string = "State  Unavailable", color = colors.muted } })
    popup.row(item, token, "charge", { label = { string = "Charge / source  Public v2 pending", color = colors.muted } })
    popup.row(item, token, "time", { label = { string = "Time estimates  Public v2 pending", color = colors.muted } })
    popup.row(item, token, "health", { label = { string = "Health / capacity  Detail pending", color = colors.muted } })
    popup.row(item, token, "cycles", { label = { string = "Cycles / electrical  Detail pending", color = colors.muted } })
    popup.row(item, token, "adapter", { label = { string = "Adapter  Detail provider pending", color = colors.muted } })
    popup.row(item, token, "low_power", { label = { string = "Low Power  Unavailable", color = colors.muted } })
    popup.row(item, token, "energy", { label = { string = "Energy modes  Manage in Settings", color = colors.dim } })
    popup.row(item, token, "charging", { label = { string = "Charge controls  Settings only", color = colors.dim } })
    popup.row(item, token, "history", { label = { string = "Usage history  Settings only", color = colors.dim } })
    popup.row(item, token, "keep_awake", { label = { string = "Keep Awake  Public provider pending", color = colors.dim } })
    popup.row(item, token, "sleep", { label = { string = "Sleep actions  Apple menu / Settings", color = colors.dim } })
    popup.row(item, token, "lock", { label = { string = "Lock state / action  Unavailable", color = colors.dim } })
    popup.row(item, token, "settings", { label = { string = "Settings  Sealed launcher unavailable", color = colors.dim } })
  end,
})

return item
