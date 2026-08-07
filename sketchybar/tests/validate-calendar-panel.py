#!/usr/bin/env python3
import json, sys
from pathlib import Path

def check(condition, message):
    if not condition:
        raise SystemExit(message)
value = json.loads(Path(sys.argv[1]).read_text())
expected_state = sys.argv[2] if len(sys.argv) > 2 else None
expected_count = int(sys.argv[3]) if len(sys.argv) > 3 else None
panel, host, display = (value['panel'], value['host'], value['display'])
check(panel['width'] == 300, 'validation failed at line 8')
check(368 <= panel['height'] <= 720, 'validation failed at line 9')
check(abs(panel['y'] + panel['height'] + 4 - host['y']) < 0.01, 'validation failed at line 10')
check(panel['x'] >= display['x'] + 8, 'validation failed at line 11')
check(panel['x'] + panel['width'] <= display['x'] + display['width'] - 8, 'validation failed at line 12')
check(panel['y'] >= display['y'] + 8, 'validation failed at line 13')
check(panel['y'] + panel['height'] <= display['y'] + display['height'] - 8, 'validation failed at line 14')
cells = value['cells']
check(len(cells) == 42, 'validation failed at line 16')
check(len({c['identifier'] for c in cells}) == 42, 'validation failed at line 17')
check(len({(c['x'], c['y']) for c in cells}) == 42, 'validation failed at line 18')
check(all((c['width'] == 36 and c['height'] == 32 for c in cells)), 'validation failed at line 19')
check(all(c['role'] == 'AXRadioButton' for c in cells), 'date cells must be radio buttons')
check(all(c['unignored'] for c in cells), 'date radio buttons must be unignored AX elements')
check(all(c['accessibility_selected'] == c['accessibility_value'] for c in cells), 'date AX value must match controller selection')
selected_cells = [c for c in cells if c['accessibility_value']]
check(len(selected_cells) == 1, 'exactly one date radio must be selected')
check(all(c['accepts_first_responder'] and c['can_become_key_view'] and c['needs_panel_to_become_key'] for c in cells), 'date cells must accept deterministic key focus')
check(all(c['focus_mask_x'] == 2 and c['focus_mask_y'] == 2 and c['focus_mask_width'] == 32 and c['focus_mask_height'] == 28 for c in cells), 'date focus masks must stay inside 36 by 32 cells')
xs = sorted({c['x'] for c in cells})
ys = sorted({c['y'] for c in cells}, reverse=True)
check(len(xs) == 7 and len(ys) == 6, 'validation failed at line 21')
check(all((xs[i + 1] - xs[i] == 36 for i in range(6))), 'validation failed at line 22')
check(all((ys[i] - ys[i + 1] == 32 for i in range(5))), 'validation failed at line 23')
check(abs(panel['height'] - (max(ys) + 32) - 72) < 0.01, 'validation failed at line 24')
for y in ys:
    row = sorted((c for c in cells if c['y'] == y), key=lambda c: c['x'])
    check([c['x'] for c in row] == xs, 'validation failed at line 27')
headers = value['headers']
check(len(headers) == 7, 'validation failed at line 29')
check([h['x'] + h['width'] / 2 for h in headers] == [x + 18 for x in xs], 'validation failed at line 30')
check(all(not h['accessibility_element'] for h in headers), 'redundant weekday abbreviations must be ignored by AX')
nav = value['navigation']
check(len(nav) == 4, 'validation failed at line 32')
check({n['identifier'] for n in nav} == {'calendar.nav.previous-year', 'calendar.nav.previous-month', 'calendar.nav.next-month', 'calendar.nav.next-year'}, 'validation failed at line 33')
rows = value['event_rows']
check(value['event_count'] == len(rows), 'validation failed at line 38')
check(all((r['height'] == 44 and r['label'] and r['title'] and r['detail'] for r in rows)), 'validation failed at line 39')
check(all((r['detail_intrinsic_width'] <= 244 for r in rows)), 'Non-title detail would clip')
check(len({r['identifier'] for r in rows}) == len(rows), 'validation failed at line 41')
check(all((r['identifier'].startswith('calendar.event.') and len(r['identifier'].split('.')[-1]) == 64 for r in rows)), 'validation failed at line 42')
check(all((r['role'] == 'AXButton' and r['unignored'] for r in rows)), 'validation failed at line 43')
check(all((r['nested_title_hits_row'] and r['nested_detail_hits_row'] and r['nested_meeting_hits_row'] for r in rows)), 'AppKit document hit-testing must route nested fields to the full event row')
check(all((r['superview_midpoint_hits_row'] and r['nonzero_document_origin'] for r in rows)), 'event rows at nonzero document origins must accept AppKit superview-coordinate hit-test points')
check(all((r['title_frame_y'] < r['detail_frame_y'] and r['title_frame_max_y'] <= r['detail_frame_y'] for r in rows)), 'validation failed at line 45')
check(all((not r['nested_title_accessibility_element'] and not r['nested_detail_accessibility_element'] and not r['nested_meeting_accessibility_element'] for r in rows)), 'nested event fields must be ignored by AX')
check(all((r['nested_title_unignored_row'] and r['nested_detail_unignored_row'] and r['nested_meeting_unignored_row'] for r in rows)), 'unignored nested event ancestor must be the row')
check(all(r['meeting_frame_width'] == 20 for r in rows), 'meeting affordance frame must stay fixed')
check(all((r['meeting_affordance'] == '↗' and r['meeting_tooltip'] == 'Open secure meeting link') if r['meeting'] else (r['meeting_affordance'] == '' and r['meeting_tooltip'] == '') for r in rows), 'meeting affordance is safe-link-only')
check(len({r['title_frame_width'] for r in rows}) <= 1, 'meeting affordance must not move title width')
check(all((c['accessibility_label'] for c in cells)), 'validation failed at line 48')
check({n['accessibility_label'] for n in nav} == {'Previous year', 'Previous month', 'Next month', 'Next year'}, 'validation failed at line 49')
month = value['month_control']
check(month['identifier'] == 'calendar.nav.today' and month['width'] == 144 and month['height'] == 40, 'fixed central month/today control')
check(month['role'] == 'AXButton' and month['unignored'], 'month/today control must be an unignored button')
check(month['accepts_first_responder'] and month['can_become_key_view'] and month['needs_panel_to_become_key'], 'month/today control must support explicit keyboard interaction')
check(bool(month['label']) and bool(month['help']), 'month/today control must be named')
if month['title'].endswith('↩'):
    check('return to today' in month['label'].lower() and month['help'] == 'Return to Today', 'away month control needs visible and AX today recovery')
else:
    check('return' not in month['label'].lower(), 'current month control must not announce away recovery')
ax = value['accessibility']
check(ax['scroll_identifier'] == 'calendar.events.scroll', 'validation failed at line 51')
check(ax['document_identifier'] == 'calendar.events.document', 'validation failed at line 52')
check(ax['window_title'] == 'Calendar' and ax['panel_title'] == 'Calendar', 'named Calendar panel and AX window')
check(ax['grid_identifier'] == 'calendar.dates' and ax['grid_role'] == 'AXRadioGroup' and ax['grid_unignored'] and ax['grid_label'].startswith('Dates for '), 'named date radio group')
check(ax['event_group_role'] == 'AXGroup' and ax['event_group_unignored'] and ax['event_group_is_document_view'] and ax['event_group_label'].startswith('Events for '), 'named unignored selected-day document group')
check(ax['selected_identifier'] == 'calendar.selected.heading' and ax['selected_label'].startswith('Selected day, '), 'named selected-day heading')
check(ax['selected_role'] in {'AXHeading', 'AXStaticText'}, 'guarded heading role')
check(all(role in {'AXHeading', 'AXStaticText'} for role in ax['section_roles']), 'guarded section heading roles')
check(ax['key_order'] == ax['expected_key_order'], 'actual key loop must match expected controls and dynamic rows')
check(ax['key_order_unique'] and ax['key_loop_closed'], 'key loop must be unique and closed')
check(ax['autorecalculates_key_view_loop'] is False, 'AppKit automatic key-loop replacement must stay disabled')
check(len(ax['key_order']) == 5 + 42 + len(rows), 'key loop must contain controls, date radios, and event rows')
check(ax['initial_responder'] == selected_cells[0]['identifier'], 'selected date must be initial responder')
if rows:
    check(ax['first_role'] == ax['last_role'] == 'AXButton', 'validation failed at line 53')
scroll = value['scroll']
check(scroll['maximum_offset_y'] >= 0, 'maximum scroll offset must be nonnegative')
check(scroll['required'] == (scroll['document_height'] > scroll['viewport_height']), 'scroll requirement must match document and viewport')
check(0 <= scroll['bottom_padding'] < 44, 'bottom padding must be bounded below one event row')
if scroll['required']:
    check(any(abs(scroll['maximum_offset_y'] - boundary) < 0.01 for boundary in scroll['alignment_boundaries']), 'maximum offset must land on an event-row or section-heading boundary')
else:
    check(scroll['bottom_padding'] == 0, 'non-scrolling documents must not receive bottom padding')
check(scroll['viewport_min_y'] == scroll['offset_y'], 'viewport minimum must equal offset')
check(abs(scroll['viewport_max_y'] - (scroll['viewport_min_y'] + scroll['viewport_height'])) < 0.01, 'viewport maximum must equal minimum plus height')
if rows and scroll['offset_y'] == 0:
    check(scroll['first_fully_visible'], 'top viewport must expose the complete first row')
    check(scroll['viewport_min_y'] <= scroll['first_row_min_y'] and scroll['viewport_max_y'] >= scroll['first_row_max_y'], 'first row must lie inside top viewport')
if rows and scroll['required'] and scroll['offset_y'] == scroll['maximum_offset_y']:
    check(scroll['last_fully_visible'], 'bottom viewport must expose the complete last row')
    check(abs(scroll['viewport_max_y'] - scroll['document_height']) < 0.01, 'bottom viewport must end at document height')
    check(scroll['viewport_min_y'] <= scroll['last_row_min_y'] and scroll['viewport_max_y'] >= scroll['last_row_max_y'], 'last row must lie inside bottom viewport')
if expected_state is not None:
    check(value['detail_state'] == expected_state, 'validation failed at line 58')
if expected_count is not None:
    check(value['event_count'] == expected_count, 'validation failed at line 59')
print(f"Calendar panel geometry passed: 42 date buttons, {len(rows)} accessible event actions, height {panel['height']}, scroll={scroll['required']}")
