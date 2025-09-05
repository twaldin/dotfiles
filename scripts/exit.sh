#!/bin/bash

HOME="/home/twaldin"
export SWAYSOCK="/run/user/$(id -u)/sway-ipc.$(id -u).$(pgrep -x sway).sock"

if [ -f "$HOME/exit.flag" ]; then
	rm -rf "$HOME/exit.flag"
	swaymsg exit
else
	touch "$HOME/exit.flag"
	swaynag -c ~/.config/swaynag/config -t gruvbox -m 'Exit Sway? Press Mod+Shift+E again to exit'
	rm -rf "$HOME/exit.flag"
fi

