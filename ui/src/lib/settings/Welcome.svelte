<script lang="ts">
	/**
	 * First run (empty library): "Bring your music from Spotify?", the one optional onboarding step
	 * (stream import2; redesigned by stream onboard to match iOS: one idea per screen, one big
	 * button). The screens themselves are `import/ImportStart.svelte`; a read hands over to the
	 * import dialog (pick → matching → review → done). Shown once; "Not now" or any read marks it
	 * done. Settings › Import library and the avatar menu bring the same screens back.
	 */
	import Modal from '$lib/kit/Modal.svelte';
	import { lib } from '$lib/library.svelte';
	import { imp } from '$lib/import.svelte';
	import ImportStart from '$lib/import/ImportStart.svelte';
	import { setPref, uiPrefs } from './prefs.svelte';

	let open = $state(false);

	// Decide once, when the library's first snapshot is in. (`?welcome` in the dev preview.)
	let decided = false;
	$effect(() => {
		if (decided || !lib.ready) return;
		decided = true;
		if (import.meta.env.DEV && location.search.includes('welcome')) {
			open = true;
			return;
		}
		if (uiPrefs.onboarded) return;
		const empty = lib.likedCount === 0 && lib.playlists.length === 0 && lib.saved.length === 0;
		if (empty && !imp.snapshot) open = true;
		else setPref('onboarded', true);
	});

	function done() {
		open = false;
		setPref('onboarded', true);
	}

	/** Close this and let the import dialog take over, reading what was handed in. */
	function handOver(go: () => void) {
		done();
		imp.preview = null;
		imp.open = true;
		go();
	}
</script>

<Modal bind:open width={480} onClose={done}>
	<ImportStart read={handOver} onNotNow={done} />
</Modal>
