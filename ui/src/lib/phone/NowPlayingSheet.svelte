<script lang="ts">
	// Now Playing, full screen, on the phone: the desktop's Now Playing panel (artwork, title, like,
	// lyrics preview, artist, credits, next up) with the player bar's progress and controls under the
	// title, and its extras in a row: lyrics, speed and pitch, sleep timer, queue. The header's
	// chevron closes it; so does Android's back gesture (history state, below).
	import { onMount } from 'svelte';
	import * as api from '$lib/api';
	import { cycleRepeat, playback, playingFrom, SKIP_SECS, skipBy } from '$lib/player.svelte';
	import Icon from '$lib/kit/Icon.svelte';
	import Slider from '$lib/kit/Slider.svelte';
	import NowPlayingPanel from '$lib/nowplaying/NowPlayingPanel.svelte';
	import QueuePanel from '$lib/nowplaying/QueuePanel.svelte';
	import SpeedButton from '$lib/nowplaying/SpeedButton.svelte';
	import { openNowPlayingMenu, openSleepMenu } from '$lib/nowplaying/menus';
	import { audio, formatSleepLeft } from '$lib/audio.svelte';
	import { offersLyrics } from '$lib/nowlyrics.svelte';
	import { shell } from '$lib/shell/layout.svelte';
	import { playlistHref } from '$lib/kit/actions';
	import { cycleShuffle, initSmartShuffle, shuffleMode } from '$lib/smart/smartshuffle.svelte';
	import SmartShuffleIcon from '$lib/smart/SmartShuffleIcon.svelte';
	import CaretDownIcon from 'phosphor-svelte/lib/CaretDownIcon';
	import DotsThreeIcon from 'phosphor-svelte/lib/DotsThreeIcon';
	import ShuffleIcon from 'phosphor-svelte/lib/ShuffleIcon';
	import SkipBackIcon from 'phosphor-svelte/lib/SkipBackIcon';
	import SkipForwardIcon from 'phosphor-svelte/lib/SkipForwardIcon';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
	import RepeatIcon from 'phosphor-svelte/lib/RepeatIcon';
	import RepeatOnceIcon from 'phosphor-svelte/lib/RepeatOnceIcon';
	import MicrophoneStageIcon from 'phosphor-svelte/lib/MicrophoneStageIcon';
	import QueueIcon from 'phosphor-svelte/lib/QueueIcon';
	import MoonIcon from 'phosphor-svelte/lib/MoonIcon';
	import ClockCounterClockwiseIcon from 'phosphor-svelte/lib/ClockCounterClockwiseIcon';
	import ClockClockwiseIcon from 'phosphor-svelte/lib/ClockClockwiseIcon';
	import { phone } from './phone.svelte';

	const now = $derived(playback.now);
	const from = $derived(playingFrom(playlistHref));
	const sleepMode = $derived(audio.sleep.mode);

	initSmartShuffle();
	const shuffleOn = $derived(playback.queue.shuffle ?? false);
	const sMode = $derived(shuffleMode(shuffleOn, playback.queue.sourceId));
	const repeat = $derived(playback.queue.repeat ?? 'off');

	let scrub = $state<number | null>(null);
	const speed = $derived(playback.speed || 1);
	const duration = $derived(playback.duration / speed);
	const position = $derived((scrub ?? playback.position) / speed);
	const fmt = (secs: number) => {
		if (!secs || secs < 0 || !Number.isFinite(secs)) return '0:00';
		const t = Math.floor(secs);
		const h = Math.floor(t / 3600);
		const m = Math.floor((t % 3600) / 60);
		const s = t % 60;
		return `${h ? `${h}:${String(m).padStart(2, '0')}` : m}:${String(s).padStart(2, '0')}`;
	};
	function seekCommit(v: number) {
		const secs = v * speed;
		playback.position = secs;
		scrub = null;
		api.seek(secs);
	}

	// Back closes the sheet (and the queue over it) instead of leaving the page underneath.
	onMount(() => {
		history.pushState({ phoneSheet: true }, '');
		const back = () => {
			if (phone.queue) {
				phone.queue = false;
				history.pushState({ phoneSheet: true }, '');
			} else phone.nowPlaying = false;
		};
		addEventListener('popstate', back);
		return () => removeEventListener('popstate', back);
	});
	const close = () => history.back();

	function lyrics() {
		shell.lyricsOpen = true;
		close();
	}

	const round = 'grid place-items-center rounded-full transition-transform active:scale-95 disabled:opacity-30';
</script>

{#snippet controls()}
	<div class="flex flex-col gap-1">
		{#if now?.live}
			<div class="py-2 text-center text-xs font-bold text-white">LIVE</div>
		{:else}
			<Slider
				label="Change progress"
				value={position}
				max={duration || 1}
				step={5}
				valuetext={(v) => `${fmt(v)} of ${fmt(duration)}`}
				disabled={!now || !duration}
				oninput={(v) => (scrub = v * speed)}
				onchange={seekCommit}
			/>
			<div class="flex justify-between text-xs text-text-subdued tabular-nums">
				<span>{fmt(position)}</span><span>{fmt(duration)}</span>
			</div>
		{/if}
	</div>

	<div class="flex items-center justify-between px-1">
		{#if now?.isEpisode}
			<button type="button" class="{round} size-12 text-white" aria-label="Back 15 seconds" onclick={() => skipBy(-SKIP_SECS)}>
				<Icon icon={ClockCounterClockwiseIcon} size={28} />
			</button>
		{:else}
			<button
				type="button"
				class="{round} size-12 {shuffleOn ? 'text-accent' : 'text-white'}"
				aria-label="Shuffle"
				aria-pressed={shuffleOn}
				onclick={() => cycleShuffle(shuffleOn, playback.queue.sourceId)}
			>
				{#if sMode === 'smart'}<SmartShuffleIcon size={26} />{:else}<Icon icon={ShuffleIcon} size={26} />{/if}
			</button>
		{/if}
		<button type="button" class="{round} size-12 text-white" aria-label="Previous" onclick={() => api.prevTrack()}>
			<Icon icon={SkipBackIcon} size={34} fill />
		</button>
		<button
			type="button"
			class="{round} size-16 bg-white text-black"
			aria-label={now?.loading ? 'Loading' : playback.paused ? 'Play' : 'Pause'}
			onclick={() => api.togglePause()}
		>
			{#if now?.loading}
				<span class="size-6 animate-spin rounded-full border-2 border-black/25 border-t-black"></span>
			{:else}
				<Icon icon={playback.paused ? PlayIcon : PauseIcon} size={30} fill />
			{/if}
		</button>
		<button type="button" class="{round} size-12 text-white" aria-label="Next" onclick={() => api.nextTrack()}>
			<Icon icon={SkipForwardIcon} size={34} fill />
		</button>
		{#if now?.isEpisode}
			<button type="button" class="{round} size-12 text-white" aria-label="Forward 15 seconds" onclick={() => skipBy(SKIP_SECS)}>
				<Icon icon={ClockClockwiseIcon} size={28} />
			</button>
		{:else}
			<button
				type="button"
				class="{round} size-12 {repeat !== 'off' ? 'text-accent' : 'text-white'}"
				aria-label={repeat === 'off' ? 'Enable repeat' : repeat === 'all' ? 'Enable repeat one' : 'Disable repeat'}
				onclick={() => cycleRepeat()}
			>
				<Icon icon={repeat === 'one' ? RepeatOnceIcon : RepeatIcon} size={26} />
			</button>
		{/if}
	</div>

	<div class="flex items-center justify-between px-1 pb-2">
		<button
			type="button"
			class="{round} size-11 text-white"
			aria-label="Lyrics"
			disabled={!now || !offersLyrics(now)}
			onclick={lyrics}
		>
			<Icon icon={MicrophoneStageIcon} size={22} />
		</button>
		<SpeedButton />
		<button
			type="button"
			class="flex h-11 items-center gap-1 rounded-full px-2 {sleepMode ? 'text-accent' : 'text-white'}"
			aria-label="Sleep timer"
			onclick={(e) => openSleepMenu(e)}
		>
			<Icon icon={MoonIcon} size={22} />
			{#if sleepMode}<span class="text-xs font-bold tabular-nums">{sleepMode.kind === 'endOfTrack' ? 'End of track' : formatSleepLeft(audio.sleepLeft ?? 0)}</span>{/if}
		</button>
		<button type="button" class="{round} size-11 text-white" aria-label="Queue" onclick={() => (phone.queue = true)}>
			<Icon icon={QueueIcon} size={22} />
		</button>
	</div>
{/snippet}

<div class="phone-sheet fixed inset-0 z-50 flex flex-col bg-gradient-to-b from-bg-elevated-highlight to-bg-base text-white">
	<header class="flex h-14 shrink-0 items-center gap-2 px-2">
		<button type="button" class="{round} size-11 text-white" aria-label="Close Now Playing" onclick={close}>
			<Icon icon={CaretDownIcon} size={26} />
		</button>
		<div class="min-w-0 flex-1 text-center">
			<div class="truncate text-[11px] tracking-wider text-text-subdued uppercase">{from.label ?? 'Playing from'}</div>
			<div class="truncate text-sm font-bold">{from.title}</div>
		</div>
		<button type="button" class="{round} size-11 text-white" aria-label="More" disabled={!now} onclick={(e) => openNowPlayingMenu(e)}>
			<Icon icon={DotsThreeIcon} size={26} />
		</button>
	</header>
	<div class="scroll-area min-h-0 flex-1 overflow-y-auto pt-2">
		<NowPlayingPanel {controls} onqueue={() => (phone.queue = true)} />
	</div>
</div>

{#if phone.queue}
	<div class="phone-sheet fixed inset-0 z-[60] flex flex-col bg-bg-base text-white">
		<header class="flex h-14 shrink-0 items-center gap-2 px-2">
			<button type="button" class="{round} size-11 text-white" aria-label="Close queue" onclick={() => history.back()}>
				<Icon icon={CaretDownIcon} size={26} />
			</button>
			<h2 class="flex-1 text-base font-bold">Queue</h2>
		</header>
		<div class="scroll-area min-h-0 flex-1 overflow-y-auto" data-right-scroll>
			<QueuePanel />
		</div>
	</div>
{/if}
