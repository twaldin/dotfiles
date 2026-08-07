#!/usr/bin/env python3
import json, sys, unicodedata
from pathlib import Path

def check(condition, message):
    if not condition:
        raise SystemExit(message)
root = Path(sys.argv[1])

def load(name):
    return json.loads((root / f'{name}.json').read_text())
empty, one, mixed, many, bottom = map(load, ['empty', 'one', 'mixed', 'many', 'many-bottom'])
check(empty['panel']['height'] == 368 and empty['event_count'] == 0, 'validation failed at line 7')
check(empty['accessibility']['selected_label'].endswith(', 0 events') and empty['accessibility']['selected_visual'].endswith('· 0 EVENTS'), 'successful empty day shows and announces explicit zero events')
check(one['panel']['height'] == 368 and one['event_rows'][0]['detail'] == '9:00 AM · 45m · ENDED', 'validation failed at line 8')
check(mixed['panel']['height'] > 368, 'validation failed at line 9')
check([r['title'] for r in mixed['event_rows']] == ['Birthday', 'Launch Day 🎉', 'Morning sync', 'Late review'], 'validation failed at line 10')
check([r['detail'] for r in mixed['event_rows']] == ['All day · ONGOING', 'All day · ONGOING', '9:30 AM · 1h 15m · ENDED', '3:45 PM · 30m · UPCOMING'], 'validation failed at line 11')
check(many['event_count'] == 16 and many['panel']['height'] == 720, 'validation failed at line 12')
check(many['scroll']['required'] and many['scroll']['offset_y'] == 0, 'validation failed at line 13')
check(bottom['scroll']['offset_y'] == bottom['scroll']['maximum_offset_y'] > 0, 'validation failed at line 14')
check(many['event_rows'][0]['identifier'] == bottom['event_rows'][0]['identifier'], 'validation failed at line 15')
check(many['event_rows'][-1]['identifier'] == bottom['event_rows'][-1]['identifier'], 'validation failed at line 16')
check(many['scroll']['first_fully_visible'] and not many['scroll']['last_fully_visible'], 'top screenshot must expose complete first row but not last')
check(bottom['scroll']['last_fully_visible'] and not bottom['scroll']['first_fully_visible'], 'bottom screenshot must expose complete last row but not first')
check(bottom['scroll']['viewport_max_y'] == bottom['scroll']['document_height'], 'bottom viewport ends at document boundary')
check(any(abs(bottom['scroll']['offset_y'] - row['y']) < 0.01 for row in bottom['event_rows']), 'bottom screenshot starts on a whole event-row boundary')
links = load('links')['event_rows']
check([r['meeting'] for r in links] == [True, False, True, False], 'validation failed at line 18')
check(all(('Open secure meeting link.' in r['label'] for r in (links[0], links[2]))), 'validation failed at line 19')
check(all(('Open in Calendar.' in r['label'] for r in (links[1], links[3]))), 'validation failed at line 20')
check([r['meeting_affordance'] for r in links] == ['↗', '', '↗', ''], 'safe-link-only meeting arrows')
check([r['meeting_tooltip'] for r in links] == ['Open secure meeting link', '', 'Open secure meeting link', ''], 'safe-link-only meeting tooltips')
check(len({r['title_frame_width'] for r in links}) == 1, 'meeting arrows never move title width')
long = load('long')['event_rows'][0]
check('東京 🧪 accessibility text must remain complete' in long['label'], 'validation failed at line 22')
check(long['title'].endswith('visual title truncates'), 'validation failed at line 23')
check(load('spring-dst')['event_rows'][0]['detail'] == '1:30 AM · 1h · ENDED', 'validation failed at line 24')
check(load('fall-dst')['event_rows'][0]['detail'] == '1:30 AM · 1h · ENDED', 'validation failed at line 25')
full = load('full-day')['event_rows']
check([r['title'] for r in full] == ['Started yesterday, ends today', 'Ended this morning', 'Ongoing at injected noon', 'Upcoming later'], 'validation failed at line 27')
check([r['detail'].split(' · ')[-1] for r in full] == ['ENDED', 'ENDED', 'ONGOING', 'UPCOMING'], 'validation failed at line 28')
check(full[0]['detail'] == 'Tue 11:00 PM · 2h · ENDED', 'cross-midnight visual includes explicit start day and duration')
check('Starts Tuesday, August 11 at 11:00 PM. Ends Wednesday, August 12 at 1:00 AM. Duration 2 hours. Ended.' in full[0]['label'], 'cross-midnight AX speech is self-contained')
check(all(' · ' not in r['label'] for r in full), 'AX speech never reuses compact visual delimiters')
check('In progress.' in full[2]['label'] and 'ONGOING' not in full[2]['label'], 'AX speech uses natural in-progress phase')
all_day_upcoming = load('all-day-upcoming')['event_rows'][0]
all_day_current = load('all-day-current')['event_rows'][0]
all_day_ended = load('all-day-ended')['event_rows'][0]
check([all_day_upcoming['detail'], all_day_current['detail'], all_day_ended['detail']] == ['All day · UPCOMING', 'All day · ONGOING', 'All day · ENDED'], 'all-day visual phases cover future current and past boundaries')
check('Upcoming.' in all_day_upcoming['label'] and 'In progress.' in all_day_current['label'] and 'Ended.' in all_day_ended['label'], 'all-day AX speech includes natural temporal phase')
check(all('Duration 1 day.' in row['label'] for row in (all_day_upcoming, all_day_current, all_day_ended)), 'all-day AX speech includes duration')
away = load('away-today')
check(away['month_control']['title'].endswith('↩') and 'return to today' in away['month_control']['label'].lower(), 'away month shows named today recovery')
for name, state in [('error', 'error'), ('permission', 'permission'), ('malformed', 'malformed'), ('duplicate-identity', 'malformed')]:
    value = load(name)
    check(value['detail_state'] == state and value['event_count'] == 0, 'validation failed at line 31')
low = load('low-clamp')
check(low['panel']['y'] == low['display']['y'] + 8, 'validation failed at line 33')
secondary = load('secondary-clamp')
check(secondary['panel']['y'] == secondary['display']['y'] + 8, 'validation failed at line 35')
for value in (empty, mixed, many, low, secondary):
    check(abs(value['panel']['y'] + value['panel']['height'] + 4 - value['host']['y']) < 0.01, 'validation failed at line 37')
malicious = load('malicious')['event_rows'][0]
check(len(malicious['title']) <= 256 and malicious['meeting'], 'validation failed at line 39')
check(not any((unicodedata.category(c) in {'Cc', 'Cf', 'Zl', 'Zp', 'Co', 'Cs'} for c in malicious['title'])), 'validation failed at line 40')
reorder_a = load('reorder-a')['event_rows']
reorder_b = load('reorder-b')['event_rows']
check([r['identifier'] for r in reorder_a] == [r['identifier'] for r in reorder_b], 'validation failed at line 43')
recurring_a = load('recurring')['event_rows'][0]['identifier']
recurring_b = load('recurring-next')['event_rows'][0]['identifier']
check(recurring_a != recurring_b, 'validation failed at line 46')
normalization = load('normalization')['event_rows']
check([r['identifier'] for r in normalization] == sorted((r['identifier'] for r in normalization)), 'validation failed at line 48')
check([r['title'] for r in load('boundaries')['event_rows']] == ['Spans into selected day', 'Inside selected day'], 'validation failed at line 49')
multi_a = load('multi-day-a')['event_rows']
multi_b = load('multi-day-b')['event_rows']
multi_c = load('multi-day-c')['event_rows']
multi_days = (multi_a, multi_b, multi_c)
check(all(rows[0]['title'] == 'Multi-day all-day synthetic' for rows in multi_days), 'multi-day all-day occurrence orders before timed events on every included selected day')
check(len({rows[0]['identifier'] for rows in multi_days}) == 1, 'multi-day occurrence keeps UID plus start identity across all selected days')
check(all(rows[0]['detail'] == 'All day · ONGOING' for rows in multi_days), 'multi-day all-day occurrence has phase through final included day')
check(all('Duration 3 days. In progress.' in rows[0]['label'] for rows in multi_days), 'multi-day all-day AX speech includes natural duration and phase')
check(all(rows[0]['meeting'] and rows[0]['meeting_affordance'] == '↗' and 'Open secure meeting link.' in rows[0]['label'] for rows in multi_days), 'multi-day safe action remains discoverable on all selected days')
check(load('multi-day-exclusive')['event_count'] == 0, 'multi-day exclusive end is absent on following selected day')
print('Calendar event fixtures passed: overlap, stable IDs, normalization, bounded text, phases, AX actions, links, DST, clamps, scroll reachability')
