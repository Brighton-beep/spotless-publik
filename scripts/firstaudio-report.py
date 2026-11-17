#!/usr/bin/env python3
"""stream: firstaudio. Medians of first-audio runs: scripts/firstaudio-report.py <run.perf.log>...

Reads the probe's `audio:<kind>:<i>` lines (UI: click to position > 0.05 s on screen) and the
backend's `fa:audible` marks (play command to mpv's first tick past 0.05 s), grouped by kind."""
import json, re, statistics, sys
from collections import defaultdict

ui, be, tap = defaultdict(list), defaultdict(list), defaultdict(list)  # tap: stream instant
for path in sys.argv[1:]:
    plays = []  # one per fa:start: [videoId, backend ms, kind, ui ms]
    for line in open(path):
        m = re.match(r'perf: (\S+) (\{.*\})', line.strip())
        if not m:
            continue
        name, data = m.group(1), json.loads(m.group(2))
        if name == 'fa:start':
            plays.append([data['videoId'], None, None, None])
        elif name == 'fa:audible' and plays and plays[-1][0] == data['videoId']:
            plays[-1][1] = data['ms']
        elif name.startswith('audio:') and name.count(':') == 2 and plays:
            p = plays[-1]
            if p[0] == data['videoId']:
                p[2] = name.split(':')[1]
                p[3] = data['ms'] if data.get('ok') else None
                if data.get('uiMs') is not None:
                    tap[p[2]].append(data['uiMs'])
    for vid, b, kind, u in plays:
        if kind is None:
            continue
        if u is not None:
            ui[kind].append(u)
        if b is not None:
            be[kind].append(b)

def fmt(xs):
    if not xs:
        return 'n=0'
    xs = sorted(xs)
    return f'median {statistics.median(xs):.0f} ms (n={len(xs)}, p25 {xs[len(xs)//4]:.0f}, p75 {xs[(3*len(xs))//4]:.0f}, min {xs[0]:.0f}, max {xs[-1]:.0f})'

for kind in sorted(set(ui) | set(be)):
    print(f'{kind:8} UI      {fmt(ui[kind])}')
    print(f'{kind:8} backend {fmt(be[kind])}')
    if tap[kind]:
        print(f'{kind:8} tap→bar {fmt(tap[kind])}')
