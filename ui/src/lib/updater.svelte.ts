// Auto-update via Tauri's updater plugin. Checks a signed latest.json on GitHub Releases; the
// startup check is silent unless an update exists, the Settings check always reports a result.
//
// `UPDATER_ENABLED` is the kill switch: off, no request goes out and the banner never shows.
// The feed is plugins.updater.endpoints in tauri.conf.json (latest.json on the GitHub release,
// written by scripts/release-mac.sh); every update is checked against plugins.updater.pubkey.
import { check, Update } from '@tauri-apps/plugin-updater';
import { relaunch } from '@tauri-apps/plugin-process';
import { toast } from './player.svelte';
import { t } from './i18n.svelte';
import { friendlyNetError } from './neterr';
import { canSelfUpdate, getSettings, openExternal } from './api';
import { isNewer, isPrerelease } from './version';
import { getVersion } from '@tauri-apps/api/app';

/** The kill switch (see the header). */
export const UPDATER_ENABLED = true;

const RELEASES_URL = 'https://github.com/fjenn/spotless/releases/latest';

/** How often the quiet check repeats while the app stays open. */
export const QUIET_INTERVAL_MS = 6 * 60 * 60 * 1000;

export const updateState = $state({
	// Set when Latest differs from this build. `rollback` is true when Latest is OLDER than this
	// build, which is what a pulled release looks like from the inside.
	available: null as { version: string; rollback: boolean } | null,
	canInstall: true, // always resolved before `available` is set
	checking: false, // Settings "Check for updates" is in flight
	installing: false // downloading/installing the update
});

// The resolved handle to download; kept out of reactive state (it's not serializable/renderable).
let pending: Update | null = null;

async function look(): Promise<boolean> {
	const current = await getVersion();
	// `allowDowngrades` is the rollback lever: whatever release is marked Latest is what every
	// client converges on, newer or older. Not on a prerelease build, which stays put until stable
	// passes it.
	const u = await check({ allowDowngrades: !isPrerelease(current) });
	if (u) {
		pending = u;
		// Before `available`, so the banner never renders with the wrong button for a frame.
		updateState.canInstall = await canSelfUpdate().catch(() => false);
		updateState.available = { version: u.version, rollback: isNewer(u.currentVersion, u.version) };
		return true;
	}
	return false;
}

/** The line announcing an available version. */
export function availableMessage(a: { version: string; rollback: boolean }): string {
	return t(a.rollback ? 'settings.about.rollback_available' : 'settings.about.update_available', {
		version: a.version
	});
}

/** On app open, and every `QUIET_INTERVAL_MS` after: show the update banner if one exists, stay
 *  silent otherwise. With `update_banner` off the check is skipped entirely. */
export async function checkForUpdatesQuiet() {
	if (!UPDATER_ENABLED) return;
	try {
		if (updateState.available) return; // one is already on screen; don't re-fetch behind it
		if ((await getSettings()).update_banner === 'false') return;
		await look();
	} catch (e) {
		console.error('update check failed', e); // no endpoint / offline — don't nag on launch
	}
}

/** From Settings: return the outcome so the modal can show it inline (a toast renders behind the
 *  dialog). `error` picks the Alert variant. */
export async function checkForUpdatesInteractive(): Promise<{ message: string; error: boolean }> {
	if (!UPDATER_ENABLED) return { message: 'Automatic updates are not available yet.', error: false };
	updateState.checking = true;
	try {
		if (await look()) return { message: availableMessage(updateState.available!), error: false };
		return { message: t('settings.about.up_to_date'), error: false };
	} catch (e) {
		const detail = friendlyNetError(String(e), t('errors.unreachable'));
		return { message: t('settings.about.update_check_failed', { error: detail }), error: true };
	} finally {
		updateState.checking = false;
	}
}

/** Send the user to the releases page when the update can't be installed in place. */
export function openDownloadPage() {
	openExternal(RELEASES_URL).catch((e) => toast.error(t('toasts.browser_failed', { error: String(e) })));
}

/** Download + install the pending update, then relaunch into the new version. */
export async function installUpdate() {
	if (!UPDATER_ENABLED || !pending) return;
	updateState.installing = true;
	try {
		// Re-read the manifest first: an installer replaced since the banner appeared no longer
		// matches the signature it was offered with. `look` swaps `pending` for the current one.
		if (!(await look())) {
			updateState.available = null;
			updateState.installing = false;
			return;
		}
		await pending.downloadAndInstall();
		await relaunch();
	} catch (e) {
		toast.error(t('toasts.update_failed', { error: String(e) }));
		updateState.installing = false;
	}
}
