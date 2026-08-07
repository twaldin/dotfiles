local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local generation = 0
local latest = nil
local text_allowed = true

local item = sbar.add("item", "media", {
  position = "left",
  drawing = false,
  updates = false,
  width = 68,
  icon = { string = "󰎈", color = colors.soft, width = 18 },
  label = { string = "", color = colors.normal, max_chars = 7, width = 48, align = "left" },
  background = { drawing = false },
})

local function render(info)
  if type(info) == "table" then
    info.title = shell.display(info.title)
    info.artist = shell.display(info.artist)
  end
  latest = info
  local meaningful = type(info) == "table" and type(info.title) == "string" and info.title ~= ""
  if not meaningful then item:set({ drawing = false }); return end
  local text = info.artist and info.artist ~= "" and (info.artist .. " · " .. info.title) or info.title
  item:set({
    drawing = false,
    icon = { string = info.playing and "󰏤" or "󰐊", color = info.playing and colors.active or colors.soft },
    label = { string = text, drawing = text_allowed },
    width = text_allowed and 68 or 20,
  })
end

local function refresh()
  generation = generation + 1
  local token = generation
  shell.exec({ settings.paths.media, "get", "--no-artwork" }, function(info, exit_code)
    if token ~= generation then return end
    if exit_code == 0 then render(info) else render(nil) end
  end)
end

item:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then shell.exec({ settings.paths.media, "next-track" })
  elseif env.BUTTON == "middle" then shell.exec({ settings.paths.media, "previous-track" })
  else shell.exec({ settings.paths.media, "toggle-play-pause" }) end
  sbar.delay(0.25, refresh)
end)

settings.on_q_layout(function(layout)
  text_allowed = layout.media_text
  if latest then render(latest) end
end)
return item
