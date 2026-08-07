local text = require("lib.text")
local M = {}

function M.quote(value)
  local text = tostring(value or "")
  return "'" .. text:gsub("'", "'\"'\"'") .. "'"
end

function M.command(argv)
  local quoted = {}
  for i, value in ipairs(argv) do quoted[i] = M.quote(value) end
  return table.concat(quoted, " ")
end

function M.exec(argv, callback)
  return sbar.exec(M.command(argv), callback)
end

function M.exec_quiet(argv, callback)
  return sbar.exec(M.command(argv) .. " 2>/dev/null", callback)
end

function M.open(url)
  M.exec({ "/usr/bin/open", url })
end

function M.trim(value)
  local result = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
  return result
end

function M.clean_text(value, max_chars, max_bytes)
  return text.clean(value, max_chars, max_bytes)
end

function M.display(value)
  local normalized = tostring(value or ""):gsub("\\", "/"):gsub('"', "’")
  return M.clean_text(normalized, 512, 4096) or ""
end

function M.ellipsis(value, max_chars)
  local text = M.display(value)
  max_chars = math.max(2, tonumber(max_chars) or 2)
  local length = utf8.len(text)
  if length and length <= max_chars then return text end
  if length then
    local byte = utf8.offset(text, max_chars)
    if byte then return text:sub(1, byte - 1) .. "…" end
  end
  if #text <= max_chars then return text end
  return text:sub(1, max_chars - 1) .. "…"
end

function M.lines(value)
  local result = {}
  for line in tostring(value or ""):gmatch("[^\r\n]+") do
    result[#result + 1] = line
  end
  return result
end

return M
