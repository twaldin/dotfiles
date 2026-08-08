local colors = require("colors")
local settings = require("settings")
local popup = require("lib.popup")
local hover = require("lib.hover")

local wifi = sbar.add("item", "wifi", {
  position = "right",
  updates = false,
  width = settings.control_width,
  icon = { string = "󰤨", color = colors.muted, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0, font = { family = settings.font, style = "Regular", size = 12.0 } },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 0 },
})
hover.bind(wifi, { idle_color = colors.muted })

popup.bind(wifi, {
  align = "right",
  build = function(token)
    popup.row(wifi, token, "heading", { label = { string = "WI-FI", color = colors.primary } })
    popup.row(wifi, token, "state", { label = { string = "State  Unavailable", color = colors.muted } })
    popup.row(wifi, token, "current", { label = { string = "Current  Native privacy view", color = colors.muted } })
    popup.row(wifi, token, "known", { label = { string = "Known  Native privacy view", color = colors.muted } })
    popup.row(wifi, token, "available", { label = { string = "Available  Native privacy view", color = colors.muted } })
    popup.row(wifi, token, "hidden", { label = { string = "Hidden join  Native privacy view", color = colors.muted } })
    popup.row(wifi, token, "actions", { label = { string = "Join / Forget  Provider unavailable", color = colors.dim } })
    popup.row(wifi, token, "unsafe", { label = { string = "Power / Disconnect  No safe rollback", color = colors.dim } })
    popup.row(wifi, token, "settings", { label = { string = "Settings  Sealed launcher unavailable", color = colors.dim } })
  end,
})

local bluetooth = sbar.add("item", "bluetooth", {
  position = "right",
  drawing = true,
  updates = false,
  width = settings.control_width,
  icon = { string = "󰂯", color = colors.muted, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0 },
  label = { drawing = false },
  background = { drawing = false, color = colors.surface2, height = 26, corner_radius = 0 },
})
hover.bind(bluetooth, { idle_color = colors.muted })

popup.bind(bluetooth, {
  align = "right",
  build = function(token)
    popup.row(bluetooth, token, "heading", { label = { string = "BLUETOOTH", color = colors.primary } })
    popup.row(bluetooth, token, "state", { label = { string = "Radio state  Unavailable", color = colors.muted } })
    popup.row(bluetooth, token, "paired", { label = { string = "Paired  Native privacy view", color = colors.muted } })
    popup.row(bluetooth, token, "connected", { label = { string = "Connected  Native privacy view", color = colors.muted } })
    popup.row(bluetooth, token, "new", { label = { string = "New devices  Native privacy view", color = colors.muted } })
    popup.row(bluetooth, token, "discovery", { label = { string = "Discovery  Provider unavailable", color = colors.dim } })
    popup.row(bluetooth, token, "actions", { label = { string = "Pair / Connect / Disconnect  Disabled", color = colors.dim } })
    popup.row(bluetooth, token, "unsafe", { label = { string = "Power / Unpair  No safe rollback", color = colors.dim } })
    popup.row(bluetooth, token, "settings", { label = { string = "Settings  Sealed launcher unavailable", color = colors.dim } })
  end,
})

return { wifi = wifi, bluetooth = bluetooth }
