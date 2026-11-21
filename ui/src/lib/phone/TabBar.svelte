<script lang="ts">
	// Bottom tabs: Home · Search · Your Library. The library is the desktop's sidebar shown as a
	// page (`shell.libraryExpanded`), the same component the desktop's "expand" button uses.
	import { goto } from '$app/navigation';
	import { page } from '$app/state';
	import Icon from '$lib/kit/Icon.svelte';
	import { shell } from '$lib/shell/layout.svelte';
	import { focusSearch } from '$lib/shell/search.svelte';
	import HouseIcon from 'phosphor-svelte/lib/HouseIcon';
	import MagnifyingGlassIcon from 'phosphor-svelte/lib/MagnifyingGlassIcon';
	import BooksIcon from 'phosphor-svelte/lib/BooksIcon';

	const tab = $derived(
		shell.libraryExpanded ? 'library' : page.url.pathname.startsWith('/search') ? 'search' : page.url.pathname === '/' ? 'home' : null
	);

	function home() {
		shell.libraryExpanded = false;
		if (page.url.pathname !== '/') goto('/');
	}
	function search() {
		shell.libraryExpanded = false;
		if (!page.url.pathname.startsWith('/search')) goto('/search');
		focusSearch();
	}
	function library() {
		shell.libraryExpanded = true;
	}
	const items = [
		{ id: 'home', label: 'Home', icon: HouseIcon, go: home },
		{ id: 'search', label: 'Search', icon: MagnifyingGlassIcon, go: search },
		{ id: 'library', label: 'Your Library', icon: BooksIcon, go: library }
	] as const;
</script>

<nav aria-label="Main" class="flex h-14 shrink-0 items-stretch bg-gradient-to-t from-black to-black/90">
	{#each items as it (it.id)}
		<button
			type="button"
			class="flex flex-1 flex-col items-center justify-center gap-1 text-[11px] font-semibold {tab === it.id
				? 'text-white'
				: 'text-text-subdued'}"
			aria-current={tab === it.id ? 'page' : undefined}
			onclick={it.go}
		>
			<Icon icon={it.icon} size={24} fill={tab === it.id} />
			{it.label}
		</button>
	{/each}
</nav>
