#!/usr/bin/env python3
"""Sample RSS and CPU time of an app and the WebKit processes it is responsible for, once a second,
until it exits: `perf-sample.py <app pid> <out.tsv> <timeout s>` (stream: perf). WebKit's helper
processes are children of launchd, so they are matched by macOS's "responsible pid" (what Activity
Monitor groups by): the app's own pid, or, for a binary started from a shell, the pid responsible
for the app itself (the terminal), limited to processes started after the app."""
import ctypes
import subprocess
import sys
import time

app, out, timeout = int(sys.argv[1]), sys.argv[2], float(sys.argv[3])
lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
resp = lib.responsibility_get_pid_responsible_for_pid
resp.restype, resp.argtypes = ctypes.c_int, [ctypes.c_int]


def role(comm):
    for k, r in (("WebContent", "webcontent"), ("Networking", "network"), ("GPU", "gpu")):
        if k in comm:
            return r
    return "other"


end = time.time() + timeout
owners = {app, resp(app)}
started = time.time() - 2
seen_ok = {}


def ours(pid):
    """Responsible for by the app (or its owner) and started with or after it."""
    if pid not in seen_ok:
        ok = resp(pid) in owners
        if ok:
            lstart = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
            try:
                ok = time.mktime(time.strptime(lstart, "%a %b %d %H:%M:%S %Y")) >= int(started) - 1
            except ValueError:
                ok = False
        seen_ok[pid] = ok
    return seen_ok[pid]

with open(out, "w") as f:
    while time.time() < end:
        ps = subprocess.run(["ps", "-axo", "pid=,rss=,time=,comm="], capture_output=True, text=True).stdout
        t = int(time.time() * 1000)
        alive = False
        for line in ps.splitlines():
            parts = line.split(None, 3)
            if len(parts) < 4:
                continue
            pid, rss, cpu, comm = int(parts[0]), parts[1], parts[2], parts[3]
            if pid == app:
                alive = True
                f.write(f"{t}\tapp\t{pid}\t{rss}\t{cpu}\n")
            elif "com.apple.WebKit" in comm and ours(pid):
                f.write(f"{t}\t{role(comm)}\t{pid}\t{rss}\t{cpu}\n")
        f.flush()
        if not alive:
            break
        time.sleep(1)
    else:
        subprocess.run(["kill", str(app)])
        print("timeout, killed", file=sys.stderr)
