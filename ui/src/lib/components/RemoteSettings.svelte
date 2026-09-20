<script lang="ts">
	/**
	 * Phone remote settings (Rust: `src-tauri/src/remote.rs`).
	 *
	 * The remote is the one part of Limusic that listens on the network instead of loopback, so
	 * this panel is written to make the exposure legible: the exact URLs the phone should use, one
	 * short-lived pairing code at a time, and the list of devices that are currently trusted with
	 * a way to revoke each.
	 */
	import { onMount } from 'svelte';
	import { HugeiconsIcon } from '@hugeicons/svelte';
	import { Copy01Icon, SmartPhone01Icon, Cancel01Icon } from '@hugeicons/core-free-icons';
	import { Button } from '$lib/components/ui/button';
	import { Input } from '$lib/components/ui/input';
	import { Switch } from '$lib/components/ui/switch';
	import { Alert, AlertDescription } from '$lib/components/ui/alert';
	import { copyText } from '$lib/clipboard';
	import * as api from '$lib/api';
	import { toast } from '$lib/player.svelte';
	import { t } from '$lib/i18n.svelte';

	type Device = { id: number; name: string; pairedAt: number };
	type Info = { enabled: boolean; port: number; addresses: string[]; devices: Device[] };

	let info = $state<Info>({ enabled: false, port: 4317, addresses: [], devices: [] });
	let busy = $state(false);
	let error = $state('');
	let port = $state('4317');
	let pairing = $state<{ code: string; expiresInSeconds: number } | null>(null);
	let secondsLeft = $state(0);

	// The pairing code is short-lived on purpose; the countdown here is what makes that visible
	// rather than surprising.
	onMount(() => {
		const id = setInterval(() => {
			if (secondsLeft > 0) secondsLeft -= 1;
			if (secondsLeft === 0) pairing = null;
		}, 1000);
		return () => clearInterval(id);
	});

	async function refresh() {
		try {
			info = (await api.remoteInfo()) as Info;
			port = String(info.port);
		} catch (e) {
			error = String(e);
		}
	}

	onMount(refresh);

	async function setEnabled(enabled: boolean) {
		busy = true;
		error = '';
		try {
			const parsed = Number(port);
			info = (await api.remoteSetEnabled(
				enabled,
				Number.isInteger(parsed) && parsed >= 1024 ? parsed : undefined
			)) as Info;
			if (!enabled) pairing = null;
		} catch (e) {
			// A port already in use is the expected failure. The setting stays on so the user can
			// change the port and retry, rather than the switch silently flipping back.
			error = String(e);
		} finally {
			busy = false;
		}
	}

	async function newCode() {
		error = '';
		try {
			pairing = (await api.remoteNewPairingCode()) as { code: string; expiresInSeconds: number };
			secondsLeft = pairing.expiresInSeconds;
		} catch (e) {
			error = String(e);
		}
	}

	async function revoke(id: number) {
		try {
			info = (await api.remoteRevokeDevice(id)) as Info;
			toast(t('settings.remote.revoked'));
		} catch (e) {
			error = String(e);
		}
	}

	function urlFor(address: string) {
		return `http://${address}:${info.port}`;
	}

	function when(secs: number) {
		return secs ? new Date(secs * 1000).toLocaleString() : '';
	}
</script>

<div class="space-y-5">
	<div class="rounded-xl border bg-card px-4 py-3.5">
		<div class="flex items-center justify-between gap-6">
			<div class="min-w-0">
				<span class="text-sm font-medium">{t('settings.remote.enable')}</span>
				<p class="mt-1 max-w-prose text-xs leading-relaxed text-muted-foreground">
					{t('settings.remote.enable_hint')}
				</p>
			</div>
			<Switch
				checked={info.enabled}
				disabled={busy}
				onCheckedChange={(v: boolean) => setEnabled(v)}
			/>
		</div>
		<div class="mt-3 flex items-center gap-2">
			<span class="text-xs text-muted-foreground">{t('settings.remote.port')}</span>
			<Input class="h-8 w-24" bind:value={port} disabled={busy} />
			<Button
				variant="outline"
				size="sm"
				disabled={busy || String(info.port) === port}
				onclick={() => setEnabled(true)}
			>
				{t('settings.remote.apply')}
			</Button>
		</div>
	</div>

	{#if error}
		<Alert variant="destructive">
			<AlertDescription>{error}</AlertDescription>
		</Alert>
	{/if}

	{#if info.enabled}
		{#if info.addresses.length}
			<div class="rounded-xl border bg-card px-4 py-3.5">
				<span class="text-sm font-medium">{t('settings.remote.address')}</span>
				<p class="mt-1 text-xs leading-relaxed text-muted-foreground">
					{t('settings.remote.address_hint')}
				</p>
				<div class="mt-2 space-y-1.5">
					{#each info.addresses as address (address)}
						<div class="flex items-center gap-2">
							<code class="rounded bg-muted px-2 py-1 text-xs">{urlFor(address)}</code>
							<Button
								variant="ghost"
								size="icon"
								class="h-7 w-7"
								onclick={() => copyText(urlFor(address))}
							>
								<HugeiconsIcon icon={Copy01Icon} size={14} />
							</Button>
						</div>
					{/each}
				</div>
			</div>
		{:else}
			<Alert>
				<AlertDescription>{t('settings.remote.no_address')}</AlertDescription>
			</Alert>
		{/if}

		<div class="rounded-xl border bg-card px-4 py-3.5">
			<div class="flex items-center justify-between gap-6">
				<div class="min-w-0">
					<span class="text-sm font-medium">{t('settings.remote.pair')}</span>
					<p class="mt-1 max-w-prose text-xs leading-relaxed text-muted-foreground">
						{t('settings.remote.pair_hint')}
					</p>
				</div>
				<Button size="sm" onclick={newCode}>
					<HugeiconsIcon icon={SmartPhone01Icon} size={15} class="mr-1.5" />
					{t('settings.remote.new_code')}
				</Button>
			</div>
			{#if pairing}
				<div class="mt-3 flex items-baseline gap-3">
					<span class="font-mono text-2xl font-bold tracking-[0.3em]">{pairing.code}</span>
					<span class="text-xs text-muted-foreground">
						{t('settings.remote.expires_in', { seconds: secondsLeft })}
					</span>
				</div>
			{/if}
		</div>

		<div class="rounded-xl border bg-card">
			<div class="px-4 py-3.5">
				<span class="text-sm font-medium">{t('settings.remote.devices')}</span>
			</div>
			<div class="divide-y divide-border/60 border-t">
				{#if info.devices.length === 0}
					<p class="px-4 py-3.5 text-xs text-muted-foreground">
						{t('settings.remote.no_devices')}
					</p>
				{:else}
					{#each info.devices as device (device.id)}
						<div class="flex items-center justify-between gap-6 px-4 py-3">
							<div class="min-w-0">
								<span class="text-sm">{device.name}</span>
								<p class="text-[11px] text-muted-foreground">{when(device.pairedAt)}</p>
							</div>
							<Button
								variant="ghost"
								size="icon"
								class="h-7 w-7"
								onclick={() => revoke(device.id)}
								aria-label={t('settings.remote.revoke')}
							>
								<HugeiconsIcon icon={Cancel01Icon} size={14} />
							</Button>
						</div>
					{/each}
				{/if}
			</div>
		</div>
	{/if}
</div>
