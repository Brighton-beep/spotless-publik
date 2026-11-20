<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
<script lang="ts">
	// publik edition: "Sign in with publik", shown over the whole window until the person is
	// signed in (publik/README.md). The Rust gate (publik/rust/src/gate.rs) decides what to show
	// and what each button does; this shows its current screen and reports presses. The words
	// are publik's own, as its gate has them.
	import { onMount } from 'svelte';
	import { invoke } from '@tauri-apps/api/core';
	import { listen } from '@tauri-apps/api/event';
	import logo from '$lib/assets/favicon.svg';
	import { publikGate } from './gate-state.svelte';

	type Screen = {
		id: string;
		title: string;
		body: string;
		note: string | null;
		buttons: [string, string][];
	};

	let screen = $state<Screen | null>(null);
	let checked = $state(false);

	onMount(() => {
		let alive = true;
		let timer: ReturnType<typeof setInterval> | undefined;
		const read = async () => {
			try {
				screen = await invoke<Screen | null>('publik_gate_screen');
			} catch {
				// Not the publik window (or the app is quitting): keep what is shown.
			}
			checked = true;
			if (alive && screen === null && timer) {
				clearInterval(timer);
				timer = undefined;
			}
		};
		void read();
		timer = setInterval(read, 300);
		const off = listen('publik-signed-in', () => {
			screen = null;
		});
		return () => {
			alive = false;
			if (timer) clearInterval(timer);
			void off.then((f) => f());
		};
	});

	$effect(() => {
		publikGate.open = !checked || screen !== null;
	});

	const press = (id: string) => void invoke('publik_gate_press', { id }).catch(() => {});
</script>

{#if !checked || screen}
	<div class="gate" role="dialog" aria-modal="true" aria-labelledby="publik-gate-title">
		<div class="drag" data-tauri-drag-region aria-hidden="true"></div>
		{#if screen}
			<div class="card">
				<img class="logo" src={logo} alt="" width="64" height="64" />
				<h1 id="publik-gate-title">{screen.title}</h1>
				<p class="body">{screen.body}</p>
				<div class="buttons">
					{#each screen.buttons as [id, label], i (id)}
						<button class:primary={i === 0} onclick={() => press(id)}>{label}</button>
					{/each}
				</div>
				{#if screen.note}<p class="note" role="status">{screen.note}</p>{/if}
			</div>
		{/if}
	</div>
{/if}

<style>
	.gate {
		position: fixed;
		inset: 0;
		z-index: 2147483647;
		display: flex;
		align-items: center;
		justify-content: center;
		background: radial-gradient(120% 90% at 50% 0%, #2a0f1d 0%, #121212 55%, #000 100%);
		color: #fff;
		user-select: none;
	}
	.drag {
		position: absolute;
		inset: 0 0 auto 0;
		height: 48px;
	}
	.card {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 16px;
		max-width: 420px;
		padding: 0 24px;
		text-align: center;
	}
	.logo {
		border-radius: 14px;
		margin-bottom: 8px;
	}
	h1 {
		margin: 0;
		font-size: 32px;
		font-weight: 700;
		letter-spacing: -0.02em;
	}
	.body {
		margin: 0;
		color: #b3b3b3;
		font-size: 16px;
		line-height: 1.5;
	}
	.buttons {
		display: flex;
		flex-wrap: wrap;
		justify-content: center;
		gap: 12px;
		margin-top: 8px;
	}
	button {
		height: 48px;
		padding: 0 32px;
		border-radius: 9999px;
		border: 1px solid #727272;
		background: transparent;
		color: #fff;
		font-size: 16px;
		font-weight: 700;
		cursor: pointer;
		transition: transform 0.1s ease, background-color 0.15s ease;
	}
	button:hover {
		transform: scale(1.04);
		border-color: #fff;
	}
	button.primary {
		border: none;
		background: var(--color-accent, #ff2d7a);
		color: #000;
	}
	button.primary:hover {
		background: var(--color-accent-hover, #ff468a);
	}
	button:focus-visible {
		outline: 2px solid #fff;
		outline-offset: 3px;
	}
	.note {
		margin: 0;
		color: #b3b3b3;
		font-size: 14px;
	}
</style>
