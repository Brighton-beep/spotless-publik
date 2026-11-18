# Device sync

Pair a Mac and an iPhone once, nearby, with a 6-digit code. After that, every change reaches the other
device a few seconds later when both are online, directly over the local network when they share one and
through an end-to-end encrypted mailbox on opena.tech when they don't. Changes made offline wait and go the
next time both are online. No accounts. Playback is never limited to one device.

Code: `crates/core/src/sync/` (all logic), `src-tauri/src/sync.rs` and `crates/ffi/src/invoke.rs` (thin
bridges), `ui/src/lib/api.ts` (typings). Relay: `docs/sync-relay/` (drop-in for the opena.tech repo).

## 1. Pieces

| Module | Job |
|---|---|
| `sync/store.rs` | Change log (SQLite triggers), merge, initial snapshot |
| `sync/crypto.rs` | XChaCha20-Poly1305 boxes, HKDF key derivation |
| `sync/net.rs` | LAN wire format, LAN server and client, SPAKE2 pairing, QR payload |
| `sync/relay.rs` | opena.tech mailbox client |
| `sync/mdns.rs` | `_spotless-sync._tcp` advertise and browse (Mac only; iOS uses Bonjour in Swift) |
| `sync/mod.rs` | Group state, the background loop, the commands |

## 2. The change log

**Capture is in SQLite, not in Rust.** `store::install` generates `AFTER INSERT/UPDATE/DELETE` triggers for every
synced table, so every write path (library.rs, db.rs, podcasts, smart, history import, undo, a future one) is
recorded with no hook to forget. Triggers are dropped and regenerated on every launch from the `SPECS` table, so
the spec is the single source of truth. `sync::start` runs last in `boot::start_services`, after every module has
created its tables.

Triggers only record while `sync_ctl.capture = 1`, which is only true while paired. An unpaired install pays one
1-row lookup per write and stores nothing.

**`sync_field`** holds the latest version of every synced field:
`(seq AUTOINCREMENT, entity, key, field, value, hlc, dev)`, unique on `(entity, key, field)`. Each change deletes the
old version and inserts the new one, so `seq` grows on every change and a peer that has everything up to `seq = n`
needs exactly the fields with `seq > n`. Superseded versions are never sent: a podcast position that moved 500 times
offline costs one field.

- **entity**: table name (or `blocked_artist`).
- **key**: JSON array of the row's global key (see §3, Identity).
- **field**: column name, plus two pseudo-fields: `_del` (1 = tombstone, 0 = present) and `_ep` (see below).
- **hlc**: hybrid logical clock in ms: `max(last + 1, wall clock ms)`, advanced to the highest clock seen in
  remote ops. Computed inside the trigger (`sync_ctl.hlc`).
- **dev**: random 128-bit device id (`sync_ctl.dev`).

On the wire an op is one changed row: `{e, k, h, d, f: {field: value}}`.

## 3. Merge rules

- **Per-field last-writer-wins** on `(hlc, dev)`. Concurrent edits of different fields of one row both survive
  (a rename on the phone and a description edit on the Mac).
- **Sets with tombstones** (likes, saved albums/artists/playlists, follows, Your Episodes, pins, hidden songs,
  playlist membership, blocked artists): a row exists if its `_del` field's latest value is 0. A delete is a `_del = 1`
  write, so it competes by clock with a re-add, and it beats a concurrent edit of another field: reordering a track
  someone else removed doesn't bring it back.
- **Ordered lists** (playlist track order, folders, pins): LWW per item position. Each track row carries its own `pos`
  and `uid`; a reorder writes the moved rows' positions. Two concurrent reorders converge to one order (each row's
  latest position), duplicates are allowed (two rows, two uids). Simplest option that is always convergent.
- **Append-only, deduplicated** (listens, episode listens, skips/`smart_events`, listen contexts): keyed by a stable
  natural id (`video_id` + `played_at` second, `+ context_key` for contexts), so the same play arriving twice is one
  row. The playing listen's growing `secs` is a field update on that key.
- **Blocked artists** live as a JSON array in one settings row. The triggers diff the array in SQL (`json_each`) and
  log one `blocked_artist` entity per artist key (channel id or name), so blocks on two devices union and an unblock
  removes only that artist.
- **Applying** a remote op: each field is stored only if its `(hlc, dev)` is higher than the stored one; the row is
  then rebuilt from the merged state with capture switched off (inside the same transaction). So applying is
  idempotent, order-independent, and never records new local ops, so nothing echoes back.
- A row that can't be built yet (a track whose playlist hasn't arrived, a NOT NULL column whose value is in a later
  batch) waits in `sync_pending` and is retried after every apply.
- **Podcast episodes**: `podcast_saved` and `podcast_progress` inserts carry `_ep`, a JSON snapshot of the episode
  row, so the other device can show a saved episode or a progress bar for a show it never loaded.

**Identity across devices.** Natural keys wherever the schema has them. `local_playlists` and
`local_playlist_tracks` use autoincrement ids, so they get a random `uid` column (filled by an always-on trigger),
and references are translated on the way out and back in: `LOCALPLAYLIST:<id>` ↔ `LOCALPLAYLIST@<uid>` in pins,
folders, recents, hidden songs and taste exclusions; a track's `playlist_id` ↔ playlist uid; a private listen's
`listen_id` ↔ `[video_id, played_at]`. `sync_gone_playlists` keeps the uid of deleted playlists (ids are never
reused) so a pin removed after its playlist still translates.

## 4. What syncs and what doesn't

**Syncs** (one-to-one):

| Area | Tables |
|---|---|
| Library | `liked_songs`, `library_items` (saved albums, playlists, artists), `local_playlists`, `local_playlist_tracks`, `lib_folders`, `lib_folder_items`, `lib_pins`, `hidden_songs` |
| Podcasts and audiobooks | `podcast_follows`, `podcast_saved` (Your Episodes), `podcast_progress` (episode and audiobook chapter progress, played state), `audiobook_books` (saved books, Continue listening) |
| History | `listens`, `listen_songs`, `episode_listens`, `lib_played` (recents), `lib_touched`, `polish_listen_contexts` |
| Behaviour and algorithm signals | `smart_events` (skips, partial and complete plays), `smart_private_listens`, `taste_excluded`, `taste_excluded_tracks`, blocked artists ("don't play this artist") |
| Settings | `store::SYNCED_SETTINGS`: quality, normalize volume, history on/off, autoplay, hide videos, prevent duplicates, lyrics providers and word-timing preference, music videos, videos first, podcast audio-only, sticky shuffle, shuffle whole queue, crossfade and its length, language, show unplayable, Last.fm primary-artist options, shuffle mode, explicit filter, podcast speed, gapless, SponsorBlock and its categories, podcast country, podcast YouTube match, charts country, What's New "seen" mark |

Remote changes reach the running app: `library-changed {scope: all}` for library tables, `home-changed` for history,
the blocklist predicate is rebuilt, live settings are re-applied (`api::setting_applied`: crossfade, gain, locale,
autoplay, ...), and `sync-changed` carries the entity list.

**Stays on each device** (explicitly):

- Downloads: `dl_*` tables, `downloads_dir`, `download_quality`, `download_on_metered`, `offline_mode`.
- Audio output: `audio_device`, `volume`, `volume_level`, `volume_before_mute`, `eq_enabled`, `eq_gains`.
- Window and desktop behaviour: `close_to_tray`, `start_minimized`, `autostart`, `system_titlebar`, `ambient_light`,
  `play_on_start`, `track_notifications*`, `discord_rpc*`, global hotkeys, mini player, update channel and banner.
- Network and playback plumbing: `proxy`, `disabled_stream_clients`, `potoken_session`, `visitor_data`,
  `web_remix_version*`.
- Accounts and secrets: `accounts`, `session_cookie`, `active_account`, `account_json`, `data_sync_id`,
  `selected_identity_json`, `lastfm_config` (a Last.fm session), Podcast Index keys.
- The live queue and session: `queue_json`, `queue_index`, `queue_position`, `smart_shuffle_state`,
  `private_session` / `private_session_since` (a private session is per device, like Spotify's).
- Caches: `stream_url_cache`, `lyrics_cache`, `smart_cache`, `smart_tags`, `smart_mfy`, `smart_releases`,
  `smart_explicit`, `podcast_episodes` (except the `_ep` snapshots above), `podcast_show_meta`,
  `podcast_sponsorblock`, `podcast_http_cache`, `polish_contexts`, `polish_pod_twins`, `playlist_track`, `mood_art`,
  `podcast_home`, `import_matches`, `imported_plays`.
- Device files: `local_tracks`, `local_folders`, custom playlist cover images (a file path per device), iOS-only
  device toggles (`ios_*`), onboarding flags, migration markers.

## 5. Transport

### 5.1 Local network

Every paired device runs a TCP server (preferred port 47615, else any free port) and advertises
`_spotless-sync._tcp` with TXT `dev=<device id>`, `tag=<8 hex from HKDF(group key)>` (peers recognise each other
without the pair id going on the air) and `pairing=1` while a code is up. The Mac advertises and browses in Rust
(`mdns-sd`). On iOS raw multicast needs an entitlement, so the iPhone browses and advertises with Bonjour
(`NWBrowser` / `NWListener`) in Swift and passes the address to `sync_join`; the core learns each peer's address
from every exchange as well (the server records the client's IP and LAN port).

Frames are a 4-byte big-endian length plus JSON (max 64 MiB). A sync exchange: the client sends its fields the peer
hasn't acknowledged (`seq > peer.sent`, leaving out what that peer wrote) plus `since = peer.recv`; the server
applies them and answers with its fields after `since`. Both loop in batches of 5,000 fields until drained. Request
and reply are sealed with the group key (aad `pair|from|req` / `pair|from|resp`). The server answers nothing that
doesn't open, and a replay changes nothing because ops are idempotent.

### 5.2 Relay (opena.tech)

`POST /api/sync/<pair_id>` `{from, box}` → `{id}`; `GET /api/sync/<pair_id>?after=<cursor>&limit=` →
`{items, next, oldest, more}`; `DELETE` removes the mailbox. Auth: `Authorization: Bearer <HKDF(group key,
"relay")>`; the relay stores the token's SHA-256 on first POST and requires it after. Upstash Redis, 30-day TTL
refreshed on POST, items older than 30 days trimmed, caps of 25 MB and 5,000 items per pair, 1 MiB per POST,
rate limits 120 req/min per pair and 300 per IP (per instance). See `docs/sync-relay/README.md`.

Each device posts only its own changes (every device reads the mailbox, so nothing needs forwarding), split into
boxes under 600 KB of plaintext, and skips posting when every peer already took them over the LAN. It reads with its
own cursor and skips its own messages. A device whose cursor is older than the oldest message held (away more than
30 days) posts `resync`; the others answer by posting their full state once. Unpairing posts `leave`; the last
device left deletes the mailbox.

### 5.3 Timing

- A local change is noticed within 1 s (the loop compares `sync_field`'s head), pushed after 1 s of quiet
  (debounce), LAN and relay.
- In front: LAN exchange every 3 s, relay poll every 5 s. In the background (`sync_set_active(false)`): relay every
  60 s, no LAN polling. iOS suspends the app in the background anyway, so the phone syncs on foreground
  (`sync_set_active(true)` kicks an immediate round) and on change; the Mac, which stays running, carries the rest.
- `sync_now` forces a full round.

### 5.4 Initial sync

On first pairing each device records its whole existing library as ops (`store::enable`). Rows are stamped with
their own timestamp column (`updated_at`, `added_at`, `played_at`, ...) as the clock, so between the two snapshots
the more recently changed version wins (podcast progress, playlist edits) and any edit made after pairing beats
both. Sets union (likes from both devices survive), playlists from both are kept, listens dedupe by natural key.
Rows with no timestamp (settings) tie on the clock; the inviting device (the one showing the code) wins those.
The first exchange happens over the LAN right after pairing, so the big transfer never goes through the relay.

## 6. Pairing and security model

1. The Mac (`sync_start_pairing`) starts its LAN server and makes a 6-digit code, valid 5 minutes for 3 attempts.
   It returns the code and a QR payload: `spotless://pair?v=1&code=…&addr=ip:port,…&dev=…&name=…`.
2. The iPhone (`sync_join`) connects to an address from the QR, from Bonjour, or (Mac joining Mac) from mDNS, and
   runs **SPAKE2** (RustCrypto `spake2`, Ed25519 group) with the code as password. Each connection costs one try,
   whatever happens, and SPAKE2 gives an attacker nothing to test more guesses against offline. A wrong code
   answers `wrong_code:<tries left>`; the last wrong try withdraws the code (the host's status drops `pairing`). So an online
   attacker gets 3 guesses at a one-in-a-million code within 5 minutes.
3. The joiner sends its key confirmation first, with its identity sealed under the PAKE key. The host verifies it,
   then sends its own confirmation and, sealed, the group: random 128-bit `pair_id`, random 256-bit group key, its
   peer list. A wrong code fails on both sides before any secret moves.
4. Both store the group key via `secrets::seal` (macOS Keychain, iOS Keychain through the host's `secret_store`).
   As with sign-in cookies, debug Mac builds keep it in the database unless `ENCORE_KEYCHAIN=1` (see secrets.rs).

After pairing:

- Every message (LAN and relay) is XChaCha20-Poly1305 under `HKDF-SHA256(group key, "spotless-sync v1 enc")`, with
  a random 24-byte nonce and `pair|sender|kind` as associated data, so the relay or anyone on the network can
  neither read a box nor forge, alter, truncate or re-attribute one.
- The relay sees a random pair id, ciphertext sizes, times and IP addresses. It can drop or delay messages (sync
  then waits for the LAN or retries); it cannot read or change data.
- More than two devices: pairing a third device on a paired Mac hands it the same group key, and every exchange and
  the relay are already N-way (forwarding over the LAN, everyone reads the mailbox). Unpairing a device makes it
  forget the key and tells the others; true revocation of a device that keeps a copy of the key would need re-keying
  (not done: with two devices, unpairing either one ends the group).

## 7. Commands and events

Both bridges, same names and args (`docs/ADDING-FEATURES.md`), parity test green:

| Command | Args | Returns |
|---|---|---|
| `sync_status` | | status |
| `sync_start_pairing` | | `{code, qr, expiresAt, port, addrs}` |
| `sync_cancel_pairing` | | status |
| `sync_join` | `code?`, `qr?`, `host?`, `port?` | status |
| `sync_unpair` | | status |
| `sync_now` | | status |
| `sync_set_active` | `active` | status |

Status: `{paired, deviceId, deviceName, platform, pairId, peers: [{id, name, platform, lastSeen, lan}], pending,
lastSync, lastError, relay: {enabled, ok}, lanPort, pairing: {code, qr, expiresAt} | null, syncing, active}`.
Event `sync-changed`: `{status, entities}` after every change of status and every applied remote batch.
The relay URL can be overridden with `SPOTLESS_SYNC_RELAY` (testing a preview deployment).

## 8. Tests

`cargo test -p encore-core --lib sync::` (25): two and three in-memory devices exchanging ops (concurrent edits,
like/unlike races, playlist add/remove/reorder with id translation, progress and the episode snapshot, deletes,
idempotent re-delivery and no echo, out-of-order delivery op by op, a track before its playlist, offline queueing,
append-only listens and the private-listen reference, blocked artists as a set, initial snapshot merge of two
non-empty libraries, device-local settings staying put, unpairing), encryption round trip and tamper detection, the
QR payload, PAKE pairing between two in-process peers over loopback with wrong codes and the 3-try limit, LAN sync
both ways over loopback, a stranger with the right pair id refused, and the relay against an in-process mailbox
(ciphertext only, no echo, expiry gap and resync, tampered and forged boxes ignored, unpair deleting the mailbox).
Relay route tests: `npm run sync:test` in the site repo (9).

## 9. The UI

Same screens and words on both apps (Mac: `ui/src/lib/devices.ts`, iPhone: `DeviceSync.swift`; change one,
change the other).

- **Entry points**: the avatar menu (Mac, "Link your iPhone") and the side menu (iPhone, "Link your Mac"), both
  "Linked devices" once linked; **Settings › Devices**, the first section (status, pending changes, the last
  problem in plain words, Link a device / Sync now / Unlink with a confirmation); a first-run screen after the
  import step ("Using Spotless on your iPhone/Mac too?"); a one-time Home hint after three days, not linked.
- **Linking**: either device shows the code (`sync_start_pairing`: big code, QR from `qr`, 5-minute countdown,
  Cancel); the other enters it (six boxes, paste) or, on the iPhone, scans the QR. The host sees the end in its
  status (`pairing` gone and a new peer: linked; gone without one: expired or tries used up). The iPhone browses
  `_spotless-sync._tcp` with `NWBrowser` and passes `host`/`port`; the Mac uses the core's mDNS. Errors map from
  the core's strings (`wrong_code:<n>`, `not_pairing`, `no_host`, timeouts, `os error 65` = Local Network
  denied on macOS, `PolicyDenied` from `NWBrowser` on iOS) to plain words with Settings buttons.
- **Lifecycle**: `sync_set_active` on window focus (Mac) and scene phase (iPhone); both refresh on `sync-changed`.
- **Links**: `spotless://pair?…` opens the join with the link (Mac: `deeplink.rs` passes it through as is;
  iPhone: the Router).
- **Preview**: the Mac devmock (`devmock/syncmock.ts`) has `?sync=linked|pending|error`, `?pair=intro|show|enter|success`,
  `?joincode=000000|111111|222222|333333` (wrong, expired, unreachable, Local Network denied), `?devpeer`,
  `?devhint`, `?devlink`.
