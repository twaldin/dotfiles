local settings = require("settings")
local M = { map = {}, lower = {}, default = ":default:" }
local ok, loaded = pcall(dofile, settings.app_icon_map)
if ok and type(loaded) == "table" then
  M.map = loaded
  M.default = loaded.Default or M.default
  for name, glyph in pairs(loaded) do
    local key = tostring(name):lower()
    if M.lower[key] == nil then M.lower[key] = glyph end
  end
end

function M.for_app(name)
  name = tostring(name or "")
  return M.map[name] or M.lower[name:lower()]
end

return M
