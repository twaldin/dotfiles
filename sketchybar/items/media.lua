local colors = require("colors")
local settings = require("settings")
local popup = require("lib.popup")
local hover = require("lib.hover")

local item = sbar.add("item", "media", {
  position = "left",
  drawing = true,
  updates = false,
  width = settings.control_width,
  icon = { string = "󰎈", color = colors.muted, width = settings.control_width, align = "center", padding_left = 0, padding_right = 0 },
  label = { drawing = false },
  background = { drawing = false },
})

hover.bind(item, { idle_color = colors.muted })

popup.bind(item, {
  align = "left",
  build = function(token)
    popup.row(item, token, "heading", { label = { string = "MEDIA", color = colors.primary } })
    popup.row(item, token, "now_playing", { label = { string = "Now Playing  Public API unavailable", color = colors.muted } })
    popup.row(item, token, "state", { label = { string = "Playback state  Unavailable", color = colors.muted } })
    popup.row(item, token, "play", { label = { string = "Play / Pause  Use the media app", color = colors.dim } })
    popup.row(item, token, "tracks", { label = { string = "Previous / Next  Use the media app", color = colors.dim } })
    popup.row(item, token, "scope", { label = { string = "App controls  Open the media app", color = colors.dim } })
  end,
})

return item
