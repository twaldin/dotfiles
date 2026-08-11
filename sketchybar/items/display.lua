local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")

local state = nil
local token = nil
local in_flight = false
local rebuild

local item = sbar.add("item", "display", {
  position = "left", drawing = true, updates = true,
  width = settings.control_width,
  padding_left = settings.spacing.item / 2,
  padding_right = settings.spacing.item / 2,
  icon = {
    string = "󰍹", color = colors.muted, width = settings.control_width,
    align = "center", padding_left = 0, padding_right = 0,
    font = settings.type.bar_control,
  },
  label = { drawing = false, string = "Display state unavailable" },
  background = { drawing = false, color = colors.surface2, height = settings.surface_height, corner_radius = 0 },
})

local function helper(callback)
  shell.exec({ settings.config_dir .. "/scripts/display-state.py", "state" }, callback)
end

local function percent(value)
  value = tonumber(value)
  return value and string.format("%.0f%%", value) or "—"
end

local function rate(value)
  value = tonumber(value)
  if not value then return "—" end
  return string.format(value == math.floor(value) and "%.0f Hz" or "%.2f Hz", value)
end

local function mode_label(mode)
  if type(mode) ~= "table" then return "—" end
  return tostring(mode.resolution or "—"):gsub("x", "×")
    .. (mode.hi_dpi and " · HiDPI" or "") .. " · " .. rate(mode.refresh_rate)
end

local function build(token_value)
  if not popup.is_current(item, token_value) then return end
  popup.header(item, token_value, "DISPLAY", state and state.resolution or "—")
  if not state then
    popup.note(item, token_value, "unavailable", "BetterDisplay state unavailable", { align = "center", color = colors.state.actionable })
  else
    popup.section(item, token_value, "brightness_heading", "Brightness")
    popup.field(item, token_value, "brightness_value", "Combined", percent(state.brightness))
    popup.meter(item, token_value, "brightness", tonumber(state.brightness) or 0, colors.domain.display)

    popup.section(item, token_value, "screen_heading", "Screen")
    popup.field(item, token_value, "resolution", "Resolution", tostring(state.resolution or "—"))
    popup.field(item, token_value, "refresh", "Refresh rate", rate(state.refresh_rate))
    popup.field(item, token_value, "color_depth", "Color depth", state.color_depth and (tostring(state.color_depth) .. " bpc") or "—")
    popup.field(item, token_value, "quality", "High Resolution", state.hi_dpi == true and "On" or state.hi_dpi == false and "Off" or "—")
    popup.field(item, token_value, "main", "Role", state.main == true and "Main display" or "Extended display")

    local modes = state.modes or {}
    if #modes > 0 then
      popup.section(item, token_value, "modes_heading", "Useful modes · read only")
      local rendered = 0
      for _, mode in ipairs(modes) do
        if mode.current or mode.default or mode.native then
          rendered = rendered + 1
          local label = mode.current and "Current" or mode.default and "Default" or "Native"
          popup.field(item, token_value, "mode_" .. rendered, label, mode_label(mode), { value_max_chars = 24 })
        end
      end
    end

    if state.contrast ~= nil then
      popup.section(item, token_value, "image_heading", "Image")
      popup.field(item, token_value, "contrast_value", "Hardware contrast", percent(state.contrast))
      popup.meter(item, token_value, "contrast", tonumber(state.contrast) or 0, colors.purple)
    end

    if state.volume ~= nil then
      popup.section(item, token_value, "sound_heading", "Display audio")
      popup.field(item, token_value, "volume_value", "Volume", percent(state.volume))
      popup.meter(item, token_value, "volume", tonumber(state.volume) or 0, colors.cyan)
      popup.field(item, token_value, "mute", "Mute", state.mute == true and "On" or state.mute == false and "Off" or "—")
    end

    popup.section(item, token_value, "control_heading", "Control")
    popup.note(item, token_value, "control_note", "Use BetterDisplay for guarded display changes", { color = colors.muted })
  end

  popup.section(item, token_value, "open_heading", "Open")
  popup.link(item, token_value, "betterdisplay", "Open BetterDisplay", function()
    shell.exec({ "/usr/bin/open", "-a", "BetterDisplay" })
  end)
  popup.link(item, token_value, "settings", "Open System Settings · select Displays", function()
    shell.open(settings.links.displays)
  end)
end

rebuild = function()
  if token and popup.is_current(item, token) then popup.rebuild(item, token, build) end
end

local function render()
  local available = state ~= nil
  local idle = available and colors.domain.display or colors.muted
  item:set({
    icon = { color = hover.foreground(item, idle) },
    label = { string = available and ("Display, " .. state.resolution .. ", " .. percent(state.brightness)) or "Display state unavailable" },
  })
  rebuild()
end

local function refresh()
  if in_flight then return end
  in_flight = true
  helper(function(output, code)
    in_flight = false
    state = code == 0 and type(output) == "table" and output.schema == 1 and output.ok == true and output or nil
    render()
  end)
end

hover.bind(item, { idle_background = false, idle_color = function()
  return state and colors.domain.display or colors.muted
end })
popup.bind(item, {
  align = "left", idle_background = false,
  right_click = function() shell.exec({ "/usr/bin/open", "-a", "BetterDisplay" }) end,
  on_close = function() token = nil end,
  build = function(current_token) token = current_token; build(current_token); refresh() end,
})
item:subscribe({ "system_woke", "display_change" }, refresh)
refresh()
return item
