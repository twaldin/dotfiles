#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MEDIA = (ROOT / "items/media.lua").read_text()


def check(value: bool, message: str) -> None:
    if not value:
        raise SystemExit(message)


def media_is_retired(source: str) -> bool:
    forbidden = (
        "lib.shell", "sbar.exec", "settings.paths.media", "media-control",
        '"get"', "toggle-play-pause", "next-track", "previous-track",
        "mouse.clicked", "left_click", "right_click", "click_script",
        "popup.action", "popup.on_click", ":subscribe(", "shell.",
        ".title", ".artist", ".playing",
    )
    required = (
        "Now Playing  Public API unavailable",
        "Playback state  Unavailable",
        "Play / Pause  Use the media app",
        "Previous / Next  Use the media app",
        "App controls  Open the media app",
    )
    strings = re.findall(r'string = "([^"]*)"', source)
    return (
        not any(value in source for value in forbidden)
        and all(value in source for value in required)
        and all(len(value) <= 38 for value in strings)
        and source.count("width = settings.control_width") == 2
        and source.count("drawing = true") == 1
        and source.count("updates = false") == 1
        and source.count("label = { drawing = false }") == 1
    )


check(media_is_retired(MEDIA), "private Media surface is not retired")
check(not media_is_retired(MEDIA + "\nsbar.exec({ \"media-control\" })"),
      "private Media command mutation was not detected")
check(not media_is_retired(MEDIA.replace(
    "Playback state  Unavailable", "Playback state  Playing")),
    "invented playback-state mutation was not detected")
check(not media_is_retired(MEDIA.replace(
    "Play / Pause  Use the media app", "Play / Pause")),
    "action-surface mutation was not detected")
check(not media_is_retired(MEDIA + "\npopup.action(item, {})"),
      "popup action mutation was not detected")
check(not media_is_retired(MEDIA + "\nitem:subscribe(\"mouse.clicked\", function() end)"),
      "click subscription mutation was not detected")
check(not media_is_retired(MEDIA + "\nshell.exec({ \"media\" })"),
      "alternate shell mutation was not detected")
check(not media_is_retired(MEDIA.replace(
    "width = settings.control_width", "width = 68", 1)),
    "host-width mutation was not detected")
check(not media_is_retired(MEDIA.replace(
    "label = { drawing = false }", "label = { drawing = true }", 1)),
    "visible-label mutation was not detected")
print("Private Media retirement source test passed")
