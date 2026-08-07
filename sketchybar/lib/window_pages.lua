local M = { size = 10 }

function M.count(total)
  total = math.max(0, math.floor(tonumber(total) or 0))
  return math.max(1, math.ceil(total / M.size))
end

function M.slice(windows, page)
  windows = type(windows) == "table" and windows or {}
  local pages = M.count(#windows)
  page = math.max(1, math.min(pages, math.floor(tonumber(page) or 1)))
  local first = (page - 1) * M.size + 1
  local result = {}
  for index = first, math.min(#windows, first + M.size - 1) do result[#result + 1] = windows[index] end
  return result, page, pages
end

return M
