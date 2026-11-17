#!/usr/bin/env python3
"""Fetch the raw tag data for the Liked Songs chip benchmark (lane magic-d3).

    python3 -I scripts/bench/tags_fetch.py docs/bench/tags/labelled.tsv OUT.json [MSD_DIR]

Per labelled track it stores what each candidate source says, unprocessed:
  mb_artist     MusicBrainz artist search (top 5 candidates with their tags and score)
  mb_recording  MusicBrainz recording search (top hit: tags, artist-credit ids)
  mb_lookup     MusicBrainz artist lookup (inc=genres+tags) for the recording's first artist
  deezer        Deezer search -> the top hit's album genres
  lastfm        Last.fm track tags from the Million Song Dataset's Last.fm set (2011 snapshot),
                when MSD_DIR holds lastfm_tags.db + unique_tracks.txt (research data, not shipped)
MusicBrainz is called at most once a second, as its rules ask. Re-runs reuse OUT.json.
"""
import json, os, re, sqlite3, sys, time, unicodedata, urllib.parse, urllib.request

UA = "MusicTagBench/0.1"
_last = [0.0]

def get(url, mb=False):
    if mb:
        wait = 1.1 - (time.time() - _last[0])
        if wait > 0:
            time.sleep(wait)
        _last[0] = time.time()
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return json.load(r)
        except Exception as e:  # 503 = MusicBrainz rate limit
            time.sleep(2 + attempt * 2)
    return None

def q(s):
    return s.replace('"', '').replace('\\', '')

def norm(s):
    s = unicodedata.normalize("NFKD", s).encode("ascii", "ignore").decode().lower()
    s = re.sub(r"\(.*?\)|\[.*?\]", " ", s)
    return re.sub(r"[^a-z0-9]+", " ", s).strip()

def main():
    labelled, out = sys.argv[1], sys.argv[2]
    msd = sys.argv[3] if len(sys.argv) > 3 else None
    rows = []
    for line in open(labelled, encoding="utf-8"):
        if line.startswith("#") or not line.strip():
            continue
        parts = line.rstrip("\n").split("\t")
        rows.append({"artist": parts[0], "title": parts[1],
                     "genres": [g for g in parts[2].split(",") if g],
                     "moods": [m for m in (parts[3] if len(parts) > 3 else "").split(",") if m]})
    data = json.load(open(out)) if os.path.exists(out) else {}
    lf = None
    if msd:
        idx = {}
        for l in open(os.path.join(msd, "unique_tracks.txt"), encoding="utf-8", errors="ignore"):
            p = l.rstrip("\n").split("<SEP>")
            if len(p) == 4:
                idx.setdefault((norm(p[2]), norm(p[3])), p[0])
        lf = (idx, sqlite3.connect(os.path.join(msd, "lastfm_tags.db")))
    artist_cache = {}
    for i, r in enumerate(rows):
        key = f"{r['artist']}\t{r['title']}"
        d = data.get(key, {})
        d.update({"artist": r["artist"], "title": r["title"], "genres": r["genres"], "moods": r["moods"]})
        a = r["artist"]
        if "mb_artist" not in d:
            if a not in artist_cache:
                j = get("https://musicbrainz.org/ws/2/artist/?fmt=json&limit=5&query=" +
                        urllib.parse.quote(f'artist:"{q(a)}"'), mb=True) or {}
                artist_cache[a] = [{"id": x["id"], "name": x["name"], "score": x.get("score", 0),
                                    "tags": [[t["name"], t["count"]] for t in x.get("tags", [])]}
                                   for x in j.get("artists", [])]
            d["mb_artist"] = artist_cache[a]
        if "mb_recording" not in d:
            j = get("https://musicbrainz.org/ws/2/recording/?fmt=json&limit=5&query=" +
                    urllib.parse.quote(f'recording:"{q(r["title"])}" AND artist:"{q(a)}"'), mb=True) or {}
            recs = j.get("recordings", [])
            top = recs[0] if recs else None
            d["mb_recording"] = None if not top else {
                "score": top.get("score", 0),
                "tags": [[t["name"], t["count"]] for x in recs[:5] for t in x.get("tags", [])],
                "artists": [c["artist"]["id"] for c in top.get("artist-credit", []) if "artist" in c]}
        if "mb_lookup" not in d:
            rec = d.get("mb_recording")
            aid = rec["artists"][0] if rec and rec["artists"] else None
            if aid:
                j = get(f"https://musicbrainz.org/ws/2/artist/{aid}?fmt=json&inc=genres+tags", mb=True) or {}
                d["mb_lookup"] = {"id": aid, "genres": [[t["name"], t["count"]] for t in j.get("genres", [])],
                                  "tags": [[t["name"], t["count"]] for t in j.get("tags", [])]}
            else:
                d["mb_lookup"] = None
        if "deezer" not in d:
            j = get("https://api.deezer.com/search?limit=1&q=" + urllib.parse.quote(f"{a} {r['title']}")) or {}
            hit = (j.get("data") or [None])[0]
            genres = []
            if hit and hit.get("album", {}).get("id"):
                alb = get(f"https://api.deezer.com/album/{hit['album']['id']}") or {}
                genres = [g["name"] for g in alb.get("genres", {}).get("data", [])]
                time.sleep(0.15)
            d["deezer"] = {"hit": bool(hit), "genres": genres}
        if lf and "lastfm" not in d:
            tid = lf[0].get((norm(a), norm(r["title"])))
            tags = []
            if tid:
                tags = [[t, v] for t, v in lf[1].execute(
                    "SELECT tags.tag, tid_tag.val FROM tid_tag JOIN tids ON tids.ROWID = tid_tag.tid "
                    "JOIN tags ON tags.ROWID = tid_tag.tag WHERE tids.tid = ?", (tid,))]
            d["lastfm"] = {"found": bool(tid), "tags": tags}
        data[key] = d
        if i % 10 == 0:
            json.dump(data, open(out, "w"), indent=0)
            print(f"{i+1}/{len(rows)}", flush=True)
    json.dump(data, open(out, "w"), indent=0)
    print("done", len(data))

if __name__ == "__main__":
    main()
