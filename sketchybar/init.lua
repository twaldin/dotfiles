require("bar")
require("default")

-- Public and documented distributed notifications only.
sbar.add("event", "network_connect", "com.apple.networkConnect")
sbar.add("event", "system_metrics_v2")
sbar.add("event", "system_battery_v2")
sbar.add("event", "sketchybar_test_popup")
sbar.add("event", "sketchybar_test_popup_exit")
sbar.add("event", "sketchybar_test_hover")
sbar.add("event", "sketchybar_test_hover_exit")

require("items")

-- The launcher owns only the provider PID recorded for this configuration.
local shell = require("lib.shell")
shell.exec({ require("settings").config_dir .. "/scripts/provider-launch.sh", "restart" })
