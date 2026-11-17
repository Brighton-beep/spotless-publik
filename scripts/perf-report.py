#!/usr/bin/env python3
"""Summarise a scripts/perf-run.sh run: `perf-report.py <out prefix>` (stream: perf)."""
import json
import re
import sys
from collections import defaultdict

out = sys.argv[1]
launch = int(open(f"{out}.meta").read().split()[1])

marks = []
for line in open(f"{out}.perf.log"):
    m = re.match(r"perf: (\S+) (\{.*\})", line.strip())
    if m:
        marks.append((m.group(1), json.loads(m.group(2))))

samples = defaultdict(list)  # role -> [(t, pid, rss_kb, cpu_s)]


def cpu_secs(s):
    # ps TIME: [[dd-]hh:]mm:ss.cc
    parts = s.replace("-", ":").split(":")
    secs = 0.0
    for p in parts:
        secs = secs * 60 + float(p)
    return secs


for line in open(f"{out}.samples.tsv"):
    t, role, pid, rss, cpu = line.rstrip("\n").split("\t")
    samples[role].append((int(t), int(pid), int(rss), cpu_secs(cpu)))


def at(t):
    """Per role: total rss MB and total cpu seconds at the sample nearest to t."""
    res = {}
    for role, rows in samples.items():
        times = sorted({r[0] for r in rows})
        if not times:
            continue
        near = min(times, key=lambda x: abs(x - t))
        sel = [r for r in rows if r[0] == near]
        res[role] = (near, sum(r[2] for r in sel) / 1024, sum(r[3] for r in sel))
    return res


def phase(start, end):
    a, b = at(start), at(end)
    out = {}
    for role in a:
        if role in b and b[role][0] > a[role][0]:
            out[role] = round(100 * (b[role][2] - a[role][2]) / ((b[role][0] - a[role][0]) / 1000), 2)
    return out


def rss(t):
    return {k: round(v[1]) for k, v in at(t).items()}


report = {}
by = {}
for name, d in marks:
    by.setdefault(name, []).append(d)
    if name == "startup":
        report["startup"] = {
            "ok": d.get("ok"),
            "shelves": d.get("shelves"),
            "launch_to_webview_ms": d["timeOrigin"] - launch,
            "launch_to_home_interactive_ms": round(d["timeOrigin"] + d["homeInteractive"] - launch),
            "launch_to_home_images_ms": d.get("homeImages") and round(d["timeOrigin"] + d["homeImages"] - launch),
            "webview_nav_to_home_ms": d["homeInteractive"],
            "layout_mounted_ms": d["layoutMounted"],
            "dom_content_loaded_ms": d["domContentLoaded"],
            "resources": d["resources"],
            "js_resources": d["jsResources"],
            "rss_mb_at_home": rss(d["epoch"] + 2000),
        }
    elif name.startswith(("search", "nav:", "audio:", "scroll:")) and not name.endswith(":rows"):
        report.setdefault("timings", []).append({"name": name, **{k: v for k, v in d.items() if k != "epoch"}})
    elif name.endswith(":rows"):
        report.setdefault("rows", []).append({"name": name, **d})

for ph in ("playing-idle", "paused-idle"):
    s, e = by.get(f"phase:{ph}:start"), by.get(f"phase:{ph}:end")
    if s and e:
        report[f"cpu_pct_{ph}"] = phase(s[0]["epoch"] + 1000, e[0]["epoch"])
        report[f"rss_mb_{ph}"] = rss(e[0]["epoch"])
if by.get("phase:soak:end"):
    report["rss_mb_after_soak"] = rss(by["phase:after-soak-idle:end"][0]["epoch"]) if by.get(
        "phase:after-soak-idle:end"
    ) else rss(by["phase:soak:end"][0]["epoch"])
    report["soak_ms"] = by["phase:soak:end"][0].get("ms")
print(json.dumps(report, indent=1))
