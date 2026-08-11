local colors = require("colors")
local settings = require("settings")
local shell = require("lib.shell")
local popup = require("lib.popup")
local hover = require("lib.hover")
local icons = require("lib.icons")
local window_pages = require("lib.window_pages")
local generation = 0
local app_name, title = "Desktop", ""
local item = sbar.add("item", "front_window", {
  position = "left",
  updates = true,
  update_freq = 15,
  width = settings.left_layout.front_width,
  align = "right",
  padding_left = settings.spacing.group / 2,
  padding_right = settings.spacing.group / 2,
  icon = {
    string = "",
    drawing = false,
    color = colors.primary,
    width = 22,
    padding_left = 4,
    padding_right = 0,
    font = settings.type.bar_app,
  },
  label = { string = "Desktop", color = colors.primary, max_chars = 11, width = 74, align = "left", padding_left = 4, padding_right = 6 },
  background = { drawing = false, color = colors.surface, height = settings.surface_height, corner_radius = 0 },
  popup = { align = "left" },
})

local function render()
  local glyph = icons.for_app(app_name)
  item:set({
    width = settings.left_layout.front_width,
    icon = { string = glyph or "", drawing = glyph ~= nil },
    label = {
      string = shell.ellipsis(app_name, glyph and 10 or 13),
      width = glyph and 74 or 94, max_chars = glyph and 10 or 13,
    },
  })
end

local function refresh_title()
  generation = generation + 1
  local token = generation
  shell.exec_quiet({ settings.config_dir .. "/scripts/yabai-windows.sh", "current" }, function(window, exit_code)
    if token ~= generation then return end
    if exit_code == 0 and type(window) == "table" then
      app_name = shell.display(window.app or app_name)
      title = shell.display(window.title or "")
    end
    render()
  end)
end

item:subscribe("front_app_switched", function()
  refresh_title()
end)
item:subscribe({ "routine", "space_change", "display_change" }, refresh_title)
hover.bind(item, {
  idle_background = false,
  idle_color = colors.primary,
})

popup.bind(item, {
  align = "left",
  idle_background = false,
  build = function(token)
    popup.row(item, token, "heading", { label = { string = "WINDOWS", color = colors.primary } })
    shell.exec_quiet({ settings.config_dir .. "/scripts/yabai-windows.sh", "all" }, function(windows, exit_code)
      if not popup.is_current(item, token) then return end
      if exit_code ~= 0 or type(windows) ~= "table" then
        popup.row(item, token, "unavailable", { label = { string = "Window list needs Yabai", color = colors.muted } })
        return
      end
      table.sort(windows, function(a, b)
        if tonumber(a.space) ~= tonumber(b.space) then return (tonumber(a.space) or 99) < (tonumber(b.space) or 99) end
        return (tonumber(a.id) or 0) < (tonumber(b.id) or 0)
      end)
      if #windows == 0 then
        popup.row(item, token, "empty", { label = { string = "No windows", color = colors.muted } })
        return
      end
      local render_page
      render_page = function(requested_page)
        popup.rebuild(item, token, function(current_token)
          local page_windows, page, page_count = window_pages.slice(windows, requested_page)
          popup.row(item, current_token, "heading", { label = { string = "WINDOWS", color = colors.primary } })
          for slot, window in ipairs(page_windows) do
            local id = tonumber(window.id)
            local app = shell.display(window.app or "App")
            local window_title = shell.display(window.title or "")
            if id then
              local focused = window["has-focus"] == true
              local full_label = string.format("%d  %s", tonumber(window.space) or 0, window_title ~= "" and window_title or app)
              local glyph = icons.for_app(app)
              local row_glyph = glyph or "󰖯"
              local label = shell.ellipsis(full_label, 29)
              local row = popup.row(item, current_token, "window_slot_" .. slot, {
                icon = { drawing = true, string = row_glyph, width = 22, padding_left = 8, padding_right = 0, color = focused and colors.accent or colors.primary, font = glyph and settings.type.bar_app or settings.type.bar_control },
                label = { string = label, color = colors.primary, width = settings.popup_width - 42, max_chars = 38 },
                background = { drawing = focused, color = colors.surface2 },
              })
              if row then
                popup.action(row, { selected = focused, idle_color = focused and colors.primary or colors.muted, idle_icon_color = focused and colors.primary or colors.muted })
                popup.on_click(row, function()
                  if popup.is_current(item, current_token) then
                    shell.exec({ settings.config_dir .. "/scripts/focus-window.sh", tostring(id) })
                    popup.close()
                  end
                end)
              end
            end
          end
          popup.row(item, current_token, "page_heading", { label = { string = string.format("Page %d/%d", page, page_count), color = colors.primary, align = "center" } })
          local previous = popup.row(item, current_token, "previous", {
            drawing = page > 1,
            icon = { drawing = page > 1, string = "←", width = 24, color = colors.blue, padding_left = 8, padding_right = 0 },
            label = { string = "Previous page", color = colors.muted },
          })
          if page > 1 then
            popup.action(previous, { idle_color = colors.muted })
            popup.on_click(previous, function()
              if popup.is_current(item, current_token) then render_page(page - 1) end
            end)
          end
          local following = popup.row(item, current_token, "next", {
            drawing = page < page_count,
            icon = { drawing = page < page_count, string = "→", width = 24, color = colors.blue, padding_left = 8, padding_right = 0 },
            label = { string = "Next page", color = colors.muted },
          })
          if page < page_count then
            popup.action(following, { idle_color = colors.muted })
            popup.on_click(following, function()
              if popup.is_current(item, current_token) then render_page(page + 1) end
            end)
          end
          popup.section(item, current_token, "application_heading", "Open")
          popup.link(item, current_token, "open_application", "Open " .. shell.ellipsis(app_name, 24), function()
            shell.exec({ "/usr/bin/open", "-a", app_name ~= "Desktop" and app_name or "Finder" })
          end)
        end)
      end
      render_page(1)
    end)
  end,
})

refresh_title()
return item
