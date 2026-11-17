#!/usr/bin/env python3
"""A synthetic Spotify "Download your data" zip in the real file formats (as stream import2 did):
Spotify Account Data/{YourLibrary.json, Playlist1.json, StreamingHistory_music_0.json, ...}.
    python3 scripts/make-spotify-export.py <out.zip> [--review] [--more]
--review adds "Review Mix" (a song YouTube Music doesn't have, so review has a Not found row).
--more adds a ninth song to Road Trip Classics: the same export a few weeks later, for re-import."""
import json, sys, zipfile, datetime

liked = [("Daft Punk", "Random Access Memories", "Get Lucky"), ("The Weeknd", "After Hours", "Blinding Lights"),
         ("Dua Lipa", "Future Nostalgia", "Levitating"), ("Queen", "A Night at the Opera", "Bohemian Rhapsody"),
         ("Fleetwood Mac", "Rumours", "Dreams"), ("Radiohead", "OK Computer", "Karma Police")]
road = [("Van Halen", "1984", "Panama"), ("Toto", "Toto IV", "Africa"), ("a-ha", "Hunting High and Low", "Take On Me"),
        ("Journey", "Escape", "Don't Stop Believin'"), ("Bon Jovi", "Slippery When Wet", "Livin' on a Prayer"),
        ("Survivor", "Eye of the Tiger", "Eye of the Tiger"), ("Europe", "The Final Countdown", "The Final Countdown"),
        ("Kenny Loggins", "Footloose", "Footloose")]
if "--more" in sys.argv:
    road.append(("Def Leppard", "Hysteria", "Pour Some Sugar on Me"))
library = {"tracks": [{"artist": a, "album": al, "track": t, "uri": ""} for a, al, t in liked],
           "albums": [{"artist": "Daft Punk", "album": "Discovery", "uri": ""}],
           "artists": [{"name": "Fleetwood Mac", "uri": ""}], "shows": [], "episodes": [], "bannedTracks": [], "other": []}
playlists = {"playlists": [{"name": "Road Trip Classics", "lastModifiedDate": "2025-06-01", "collaborators": [],
                            "items": [{"track": {"trackName": t, "artistName": a, "albumName": al, "trackUri": ""},
                                       "episode": None, "localTrack": None, "addedDate": "2025-06-01"} for a, al, t in road]}]}
if "--review" in sys.argv:
    mix = [("Nobody Known Quartet", "Basement Tapes", "Zqxv Plorth Vintage Demo 1997"), ("Daft Punk", "Discovery", "One More Time"),
           ("Radiohead", "The Bends", "High and Dry")]
    playlists["playlists"].append({"name": "Review Mix", "lastModifiedDate": "2025-06-02", "collaborators": [],
                                   "items": [{"track": {"trackName": t, "artistName": a, "albumName": al, "trackUri": ""},
                                              "episode": None, "localTrack": None, "addedDate": "2025-06-02"} for a, al, t in mix]})
now = datetime.datetime(2025, 11, 1, 12, 0)
history = []
for i, (a, al, t) in enumerate(liked * 3 + road[:4]):
    history.append({"endTime": (now - datetime.timedelta(hours=7 * i)).strftime("%Y-%m-%d %H:%M"),
                    "artistName": a, "trackName": t, "msPlayed": 190000 if i % 5 else 6000})
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    d = "Spotify Account Data/"
    z.writestr(d + "YourLibrary.json", json.dumps(library))
    z.writestr(d + "Playlist1.json", json.dumps(playlists))
    z.writestr(d + "StreamingHistory_music_0.json", json.dumps(history))
    z.writestr(d + "StreamingHistory_podcast_0.json", "[]")
    z.writestr(d + "Userdata.json", json.dumps({"username": "encore-test", "country": "NL"}))
print(sys.argv[1])
