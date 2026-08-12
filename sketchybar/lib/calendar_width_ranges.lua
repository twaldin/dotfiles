-- Conservative outlier blocks for JetBrainsMonoNF-SemiBold at 11.5 points and
-- its supported Tahoe fallback cascade. The release gate rescans every
-- sanitizer-reachable Unicode scalar and rejects any uncovered wider glyph.
local M = {
  oversized = {
    0x102a, 0x102a,
    0x2e3b, 0x2e3b,
    0xfb50, 0xfdff,
    0x12000, 0x1257f,
  },
}

function M.contains(ranges, value)
  local low, high = 1, #ranges / 2
  while low <= high do
    local middle = math.floor((low + high) / 2)
    local first, last = ranges[middle * 2 - 1], ranges[middle * 2]
    if value < first then high = middle - 1
    elseif value > last then low = middle + 1
    else return true end
  end
  return false
end

return M
