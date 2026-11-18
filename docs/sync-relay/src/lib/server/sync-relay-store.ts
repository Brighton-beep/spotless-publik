/**
 * Storage for the Spotless sync relay (see sync-relay.ts). Only opaque ciphertext is stored, under a
 * random pair id, for at most 30 days. Upstash Redis when KV_REST_API_URL + KV_REST_API_TOKEN are set
 * (same env as savings-store.ts); otherwise an in-memory store, which only dev and tests may use.
 *
 * Redis layout per pair: `sync:<pair>:auth` (sha256 of the bearer token), `sync:<pair>:seq` (INCR),
 * `sync:<pair>:log` (sorted set, score = id, member = JSON item), `sync:<pair>:bytes` (box bytes held).
 */

export type RelayItem = { id: number; from: string; box: string; at: number };
export type RelayRange = { items: RelayItem[]; oldest: number | null; more: boolean };

export const TTL_SECONDS = 30 * 24 * 3600;
export const MAX_ITEMS = 5000;
export const MAX_BYTES = 25 * 1024 * 1024;
/** Box data per GET response. */
export const MAX_READ_BYTES = 4 * 1024 * 1024;

export interface SyncStore {
  getAuth(pair: string): Promise<string | null>;
  /** Store the token hash unless one is already there. */
  setAuthIfAbsent(pair: string, hash: string): Promise<void>;
  /** Append, trim (age, count, bytes) and refresh the TTL. Returns the new item's id. */
  append(pair: string, from: string, box: string, now: number): Promise<number>;
  range(pair: string, after: number, limit: number, now: number): Promise<RelayRange>;
  remove(pair: string): Promise<void>;
}

const tooOld = (it: RelayItem, now: number) => now - it.at > TTL_SECONDS * 1000;

/** Items after `after`, capped by count and by box bytes. */
function window(all: RelayItem[], after: number, limit: number): RelayRange {
  const rest = all.filter((i) => i.id > after);
  const items: RelayItem[] = [];
  let bytes = 0;
  for (const it of rest) {
    if (items.length >= limit || (items.length > 0 && bytes + it.box.length > MAX_READ_BYTES)) break;
    items.push(it);
    bytes += it.box.length;
  }
  return { items, oldest: all.length ? all[0].id : null, more: rest.length > items.length };
}

export class MemoryStore implements SyncStore {
  private pairs = new Map<string, { auth: string | null; seq: number; log: RelayItem[]; expires: number }>();

  private get(pair: string, now: number) {
    const p = this.pairs.get(pair);
    if (p && p.expires <= now) {
      this.pairs.delete(pair);
      return undefined;
    }
    return p;
  }

  async getAuth(pair: string) {
    return this.get(pair, Date.now())?.auth ?? null;
  }

  async setAuthIfAbsent(pair: string, hash: string) {
    const now = Date.now();
    const p = this.get(pair, now) ?? { auth: null, seq: 0, log: [], expires: now + TTL_SECONDS * 1000 };
    if (!p.auth) p.auth = hash;
    this.pairs.set(pair, p);
  }

  async append(pair: string, from: string, box: string, now: number) {
    const p = this.get(pair, now) ?? { auth: null, seq: 0, log: [], expires: 0 };
    const id = ++p.seq;
    p.log.push({ id, from, box, at: now });
    p.log = p.log.filter((i) => !tooOld(i, now));
    let bytes = p.log.reduce((n, i) => n + i.box.length, 0);
    while (p.log.length > 1 && (p.log.length > MAX_ITEMS || bytes > MAX_BYTES)) bytes -= p.log.shift()!.box.length;
    p.expires = now + TTL_SECONDS * 1000;
    this.pairs.set(pair, p);
    return id;
  }

  async range(pair: string, after: number, limit: number, now: number) {
    const p = this.get(pair, now);
    return window((p?.log ?? []).filter((i) => !tooOld(i, now)), after, limit);
  }

  async remove(pair: string) {
    this.pairs.delete(pair);
  }
}

export class RedisStore implements SyncStore {
  constructor(
    private url: string,
    private token: string,
  ) {}

  private async kv(commands: (string | number)[][]): Promise<unknown[]> {
    const r = await fetch(`${this.url}/pipeline`, {
      method: "POST",
      headers: { Authorization: `Bearer ${this.token}`, "Content-Type": "application/json" },
      body: JSON.stringify(commands),
      cache: "no-store",
    });
    if (!r.ok) throw new Error(`redis ${r.status}`);
    const out = (await r.json()) as { result?: unknown; error?: string }[];
    const failed = out.find((x) => x.error);
    if (failed) throw new Error(`redis ${failed.error}`);
    return out.map((x) => x.result);
  }

  private k(pair: string, part: string) {
    return `sync:${pair}:${part}`;
  }

  async getAuth(pair: string) {
    const [v] = await this.kv([["GET", this.k(pair, "auth")]]);
    return (v as string | null) ?? null;
  }

  async setAuthIfAbsent(pair: string, hash: string) {
    await this.kv([
      ["SET", this.k(pair, "auth"), hash, "NX"],
      ["EXPIRE", this.k(pair, "auth"), TTL_SECONDS],
    ]);
  }

  async append(pair: string, from: string, box: string, now: number) {
    const [seq] = await this.kv([["INCR", this.k(pair, "seq")]]);
    const id = Number(seq);
    const member = JSON.stringify({ id, from, box, at: now });
    const keys = ["auth", "seq", "log", "bytes"].map((p) => this.k(pair, p));
    const [, bytes, count] = await this.kv([
      ["ZADD", this.k(pair, "log"), id, member],
      ["INCRBY", this.k(pair, "bytes"), box.length],
      ["ZCARD", this.k(pair, "log")],
      ...keys.map((key) => ["EXPIRE", key, TTL_SECONDS]),
    ]);
    // Trim from the oldest end: expired by age, or over the count / byte caps. Bounded per POST.
    let held = Number(bytes);
    let n = Number(count);
    for (let round = 0; round < 20; round++) {
      const [oldest] = (await this.kv([["ZRANGE", this.k(pair, "log"), 0, 49]])) as string[][];
      if (!oldest?.length) break;
      const drop: string[] = [];
      for (const m of oldest) {
        const it = JSON.parse(m) as RelayItem;
        if (n - drop.length <= 1) break;
        if (tooOld(it, now) || n - drop.length > MAX_ITEMS || held > MAX_BYTES) {
          drop.push(m);
          held -= it.box.length;
        } else break;
      }
      if (!drop.length) break;
      n -= drop.length;
      const freed = drop.reduce((s, m) => s + (JSON.parse(m) as RelayItem).box.length, 0);
      await this.kv([
        ["ZREM", this.k(pair, "log"), ...drop],
        ["DECRBY", this.k(pair, "bytes"), freed],
      ]);
      if (drop.length < oldest.length) break;
    }
    return id;
  }

  async range(pair: string, after: number, limit: number, now: number) {
    const [rest, first] = (await this.kv([
      ["ZRANGEBYSCORE", this.k(pair, "log"), `(${after}`, "+inf", "LIMIT", 0, limit + 1],
      ["ZRANGE", this.k(pair, "log"), 0, 0],
    ])) as string[][];
    const items = (rest ?? []).map((m) => JSON.parse(m) as RelayItem).filter((i) => !tooOld(i, now));
    const head = (first ?? []).map((m) => JSON.parse(m) as RelayItem);
    const w = window(items, after, limit);
    return { items: w.items, oldest: head.length ? head[0].id : w.oldest, more: w.more || items.length > limit };
  }

  async remove(pair: string) {
    await this.kv([["DEL", ...["auth", "seq", "log", "bytes"].map((p) => this.k(pair, p))]]);
  }
}

let shared: SyncStore | null | undefined;

/** The store for this deployment: Redis when configured, memory outside production, else none. */
export function syncStore(): SyncStore | null {
  if (shared !== undefined) return shared;
  const url = process.env.KV_REST_API_URL;
  const token = process.env.KV_REST_API_TOKEN;
  if (url && token) shared = new RedisStore(url, token);
  else shared = process.env.NODE_ENV === "production" ? null : new MemoryStore();
  return shared;
}
