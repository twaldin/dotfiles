local colors = require("colors")
local settings = require("settings")
local hover = require("lib.hover")
local spaces = {}
local selected = {}

settings.set_space_count(9)
settings.set_q_layout("full", false)

for index = 1, 9 do
  local item = sbar.add("space", "space." .. index, {
    position = "left",
    associated_space = index,
    width = 24,
    padding_left = 0,
    padding_right = 0,
    icon = {
      string = tostring(index),
      color = colors.muted,
      highlight_color = colors.active,
      width = 24,
      align = "center",
      padding_left = 0,
      padding_right = 0,
      font = { family = settings.font, style = "Bold", size = 11.0 },
    },
    label = { drawing = false },
    background = { drawing = false, color = colors.surface, height = 26, corner_radius = 0 },
  })
  spaces[index] = item
  item:subscribe("space_change", function(env)
    selected[index] = env.SELECTED == true or env.SELECTED == "true"
    if hover.is_active(item) then
      item:set({ icon = { color = colors.primary }, background = { color = colors.hover } })
      item:set({ background = { drawing = true } })
    else
      item:set({ icon = { color = selected[index] and colors.accent or colors.muted }, background = { drawing = selected[index], color = colors.surface } })
    end
  end)
  hover.bind(item, {
    idle_background = function() return selected[index] == true end,
    idle_color = function() return selected[index] and colors.accent or colors.muted end,
  })
end

return {}
