// The top-bar avatar menu (settings.md "Avatar menu", audit 31): Spotify's text-only list, ≈196px.
// No account is needed for anything: the profile is the local "Spotless" one, and YouTube Music
// sign-in is an optional extra at the bottom. Stream p-settings owns the content; TopBar opens it.
import { goto } from '$app/navigation';
import * as api from '$lib/api';
import { auth, startSignIn } from '$lib/player.svelte';
import { lib } from '$lib/library.svelte';
import { openMenu, type MenuEntry, type MenuTarget } from '$lib/kit/menus';
import { goSettings, importFromSpotify, togglePrivateSession } from './actions';

export function profileMenuEntries(): MenuEntry[] {
	const account = auth.account;
	return [
		{ type: 'heading', label: account?.signedIn && account.name ? `Spotless · ${account.name}` : 'Spotless · Local profile' },
		{ label: 'Listening stats', onSelect: () => goto('/stats') },
		{ label: 'Recently played', onSelect: () => goto('/history') },
		{ label: 'Import from Spotify', onSelect: importFromSpotify },
		{ label: 'Private session', checked: lib.privateSession.enabled, onSelect: togglePrivateSession },
		{ label: 'Settings', hint: '⌘,', onSelect: () => goSettings() },
		{ type: 'separator' },
		account?.signedIn
			? { label: 'Sign out of YouTube Music', onSelect: () => api.signOut() }
			: { label: 'Sign in to YouTube Music', onSelect: () => startSignIn() }
	];
}

export function openProfileMenu(target: MenuTarget) {
	openMenu(target, profileMenuEntries(), { width: 240, align: 'end' });
}
