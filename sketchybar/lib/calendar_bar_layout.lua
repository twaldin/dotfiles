local settings = require("settings")
local M = {
  event_max_width = settings.right_layout.calendar_event_width,
  edge_padding = settings.spacing.edge,
  content_gap = settings.spacing.item,
  -- Conservative width bounds certified for the supported 36-point bar.
  title_narrow_advance = 6.9,
  title_fallback_advance = 27.0,
  title_oversized_advance = 75.0,
  title_font_postscript = "JetBrainsMonoNF-SemiBold",
  title_font_size = 11.5,
  detail_advance = 6.0,
}

function M.detail_width(detail)
  detail = tostring(detail or "")
  if detail == "" then return 0 end
  return math.ceil((utf8.len(detail) or #detail) * M.detail_advance + 1.5)
end

function M.title_budget(detail)
  local detail_width = M.detail_width(detail)
  local gap = detail_width > 0 and M.content_gap or 0
  return M.event_max_width - (2 * M.edge_padding) - gap - detail_width, detail_width, gap
end

return M
