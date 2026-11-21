// The phone layout (Android): one page at a time under a compact top bar, a mini player and a tab
// bar at the bottom, and Now Playing as a full-screen sheet. The desktop's three-column shell
// (Your Library · page · right panel) and its 72px player bar don't fit a 400px-wide screen.
//
// On for Android always, and for any window narrower than a phone-ish width, so the layout can be
// worked on in a desktop window too.
import { browser } from '$app/environment';

const ANDROID = browser && /Android/i.test(navigator.userAgent);
const NARROW = 640;

export const phone = $state({
	on: ANDROID || (browser && window.innerWidth < NARROW),
	/** The full-screen Now Playing sheet. */
	nowPlaying: false,
	/** The queue as a full-screen sheet (over Now Playing). */
	queue: false
});

if (browser && !ANDROID) {
	addEventListener('resize', () => (phone.on = window.innerWidth < NARROW));
}
if (browser && phone.on) document.documentElement.classList.add('phone');
