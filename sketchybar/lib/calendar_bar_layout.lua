local M = {
  event_max_width = 256,
  edge_padding = 8,
  content_gap = 8,
  title_narrow_advance = 5.4,
  title_fallback_advance = 24.0,
  title_oversized_advance = 64.0,
  title_font_postscript = "JetBrainsMonoNF-SemiBold",
  title_font_size = 9.0,
  detail_advance = 4.8,
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
