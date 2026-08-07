package.path = os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?.lua;" .. os.getenv("SKETCHYBAR_CONFIG_DIR") .. "/?/init.lua;" .. package.path
local pages = require("lib.window_pages")
local function check(condition, message) if not condition then error(message, 0) end end
local windows = {}
for index = 1, 13 do windows[#windows + 1] = { id = index, space = ((index - 1) % 9) + 1 } end
windows[#windows + 1] = { id = 99, space = 12 }
local first, first_page, count = pages.slice(windows, 1)
local second, second_page, second_count = pages.slice(windows, 2)
check(#first == 10 and first_page == 1 and count == 2, "first window page must contain the deterministic first ten rows")
check(#second == 4 and second_page == 2 and second_count == 2 and second[#second].id == 99, "later page must keep the external-display window reachable")
local seen = {}
for _, page in ipairs({ first, second }) do for _, window in ipairs(page) do seen[window.id] = (seen[window.id] or 0) + 1 end end
for _, window in ipairs(windows) do check(seen[window.id] == 1, "every sorted window must be reachable exactly once") end
print("Front-window deterministic pagination contract passed")
