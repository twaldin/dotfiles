local config_dir = assert(os.getenv("SKETCHYBAR_CONFIG_DIR"), "SKETCHYBAR_CONFIG_DIR is not set")
package.path = config_dir .. "/?.lua;" .. config_dir .. "/?/init.lua;" .. package.path
package.cpath = package.cpath .. ";" .. os.getenv("HOME") .. "/.local/share/sketchybar_lua/?.so"

sbar = require("sketchybar")
-- Notify the previous live configuration before its popup items are replaced.
sbar.trigger("reload")
sbar.begin_config()
require("init")
sbar.hotload(true)
sbar.end_config()
sbar.event_loop()
