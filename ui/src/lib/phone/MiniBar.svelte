<script lang="ts">
	// The phone's mini player, above the tab bar: cover, title/artists, like, play/pause, and a thin
	// progress line along the bottom. Tapping it (not a button) opens Now Playing full screen.
	import * as api from '$lib/api';
	import { playback, toggleNowPlayingRating } from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import Icon from '$lib/kit/Icon.svelte';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
	import PlusCircleIcon from 'phosphor-svelte/lib/PlusCircleIcon';
	import CheckCircleIcon from 'phosphor-svelte/lib/CheckCircleIcon';
	import { phone } from './phone.svelte';

	const now = $derived(playback.now);
	const progress = $derived(
		playback.duration ? Math.min(1, Math.max(0, playback.position / playback.duration)) : 0
	);
	const likeable = $derived(!!now && !now.isEpisode && !api.isLocalId(now.videoId));
	const liked = $derived(playback.rating === 'like');
</script>

{#if now}
	<div class="shrink-0 px-2 pb-1">
		<!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_static_element_interactions -->
		<div
			class="relative flex h-14 items-center gap-3 overflow-hidden rounded-md bg-bg-elevated-highlight pr-1 pl-2"
			onclick={() => (phone.nowPlaying = true)}
		>
			{#if now.thumbnail}
				<img src={thumb(now.thumbnail, 96)} alt="" class="size-10 shrink-0 rounded object-cover" />
			{:else}
				<div class="size-10 shrink-0 rounded bg-bg-highlight"></div>
			{/if}
			<div class="min-w-0 flex-1">
				<div class="truncate text-sm font-semibold text-white">{now.title}</div>
				<div class="truncate text-xs text-text-subdued">{now.artists}</div>
			</div>
			{#if likeable}
				<button
					type="button"
					class="grid size-10 place-items-center {liked ? 'text-accent' : 'text-white'}"
					aria-label={liked ? 'Remove from Liked Songs' : 'Save to Liked Songs'}
					onclick={(e) => {
						e.stopPropagation();
						toggleNowPlayingRating();
					}}
				>
					<Icon icon={liked ? CheckCircleIcon : PlusCircleIcon} size={24} fill={liked} />
				</button>
			{/if}
			<button
				type="button"
				class="grid size-10 place-items-center text-white"
				aria-label={now.loading ? 'Loading' : playback.paused ? 'Play' : 'Pause'}
				onclick={(e) => {
					e.stopPropagation();
					api.togglePause();
				}}
			>
				{#if now.loading}
					<span class="size-5 animate-spin rounded-full border-2 border-white/25 border-t-white"></span>
				{:else}
					<Icon icon={playback.paused ? PlayIcon : PauseIcon} size={24} fill />
				{/if}
			</button>
			<div class="absolute right-2 bottom-0 left-2 h-0.5 rounded-full bg-white/20">
				<div class="h-full rounded-full bg-white" style="width:{progress * 100}%"></div>
			</div>
		</div>
	</div>
{/if}
