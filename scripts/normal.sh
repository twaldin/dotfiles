#!/bin/bash
wmctrl -r :ACTIVE: -b remove,fullscreen
wmctrl -r :ACTIVE: -b add,maximized_vert,maximized_horz
