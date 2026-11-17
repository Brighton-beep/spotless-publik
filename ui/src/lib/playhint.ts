// stream: firstaudio. Tell the backend which track is about to be played, so its stream is
// resolved and its first bytes fetched before the click (docs/streams/firstaudio.md). A row that
// the pointer rests on for HOVER_MS is a hint. Not a press: the click follows ~100 ms later, too
// soon for a background resolve to finish, so it would only double the /player call. The backend rations the
// network work; this side only keeps a track from being sent twice in a while.
import { hintPlay } from '$lib/api';
import type { SongItem } from '$lib/api';

const HOVER_MS = 250;
const AGAIN_MS = 30_000; // the backend keeps its own, longer memory of what it resolved
const sent = new Map<string, number>();
let timer: ReturnType<typeof setTimeout> | undefined;

function send(song: SongItem) {
	const now = Date.now();
	const last = sent.get(song.video_id);
	if (last !== undefined && now - last < AGAIN_MS) return;
	sent.set(song.video_id, now);
	if (sent.size > 500) sent.clear();
	hintPlay(song).catch(() => {});
}

/** The pointer entered a track row: hint it once it has rested there a moment. */
export function hoverHint(song: SongItem) {
	clearTimeout(timer);
	timer = setTimeout(() => send(song), HOVER_MS);
}

/** The pointer left before the hover counted. */
export function leaveHint() {
	clearTimeout(timer);
}
