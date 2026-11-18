/**
 * Spotless device sync relay: an encrypted mailbox per paired group of devices.
 *
 * The apps encrypt every batch end to end (XChaCha20-Poly1305, key known only to the devices), so
 * this only ever handles opaque `box` strings under a random 128-bit pair id. A device proves it
 * belongs to the pair with a bearer token derived from the group key; the first POST stores the
 * token's SHA-256 (trust on first use) and every later request must match it.
 *
 *   POST   /api/sync/<pair>            {from, box}          -> {id}
 *   GET    /api/sync/<pair>?after=&limit=                   -> {items, next, oldest, more}
 *   DELETE /api/sync/<pair>                                 -> {ok}
 *
 * Nothing here logs tokens, boxes or IP addresses. The client in the app is
 * crates/core/src/sync/relay.rs in the Spotless repo.
 */
import { createHash, timingSafeEqual } from "node:crypto";
import { clientKey, limited } from "./rate-limit";
import { type SyncStore } from "./sync-relay-store";

const PAIR_RE = /^[0-9a-f]{32}$/;
const TOKEN_RE = /^[0-9a-f]{64}$/;
const FROM_RE = /^[a-z0-9-]{16,64}$/;
const BOX_RE = /^[A-Za-z0-9_-]+$/;
export const MAX_BODY = 1024 * 1024;
/** Per instance (the in-memory limiter in rate-limit.ts), so the effective cap scales with instances. */
export const PAIR_PER_MIN = 120;
export const IP_PER_MIN = 300;

const json = (body: unknown, status = 200, headers: Record<string, string> = {}) =>
  Response.json(body, { status, headers: { "Cache-Control": "no-store", ...headers } });

const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");

function sameHex(a: string, b: string) {
  const x = Buffer.from(a, "hex");
  const y = Buffer.from(b, "hex");
  return x.length === y.length && timingSafeEqual(x, y);
}

function bearer(req: Request) {
  const h = req.headers.get("authorization") ?? "";
  const t = h.startsWith("Bearer ") ? h.slice(7).trim() : "";
  return TOKEN_RE.test(t) ? t : null;
}

export async function handleSync(req: Request, pairId: string, store: SyncStore | null, now = Date.now()): Promise<Response> {
  if (!store) return json({ error: "unavailable" }, 503);
  if (!PAIR_RE.test(pairId)) return json({ error: "bad_pair" }, 400);
  if (limited("sync-ip", clientKey(req), IP_PER_MIN, 60_000) || limited("sync-pair", pairId, PAIR_PER_MIN, 60_000)) {
    return json({ error: "rate_limited" }, 429, { "Retry-After": "30" });
  }
  const token = bearer(req);
  if (!token) return json({ error: "forbidden" }, 403);
  const hash = sha256(token);
  const stored = await store.getAuth(pairId);
  const method = req.method.toUpperCase();

  if (method === "GET") {
    const url = new URL(req.url);
    const after = Math.max(0, Math.floor(Number(url.searchParams.get("after") ?? 0)) || 0);
    const limit = Math.min(200, Math.max(1, Math.floor(Number(url.searchParams.get("limit") ?? 100)) || 100));
    if (!stored) return json({ items: [], next: after, oldest: null, more: false });
    if (!sameHex(stored, hash)) return json({ error: "forbidden" }, 403);
    const r = await store.range(pairId, after, limit, now);
    const next = r.items.length ? r.items[r.items.length - 1].id : after;
    return json({ items: r.items, next, oldest: r.oldest, more: r.more });
  }

  if (method === "POST") {
    if (Number(req.headers.get("content-length") ?? 0) > MAX_BODY) return json({ error: "too_large" }, 413);
    const text = await req.text();
    if (Buffer.byteLength(text) > MAX_BODY) return json({ error: "too_large" }, 413);
    let body: { from?: unknown; box?: unknown } | null = null;
    try {
      body = JSON.parse(text);
    } catch {
      body = null;
    }
    const from = typeof body?.from === "string" ? body.from : "";
    const box = typeof body?.box === "string" ? body.box : "";
    if (!FROM_RE.test(from) || !box || !BOX_RE.test(box)) return json({ error: "bad_request" }, 400);
    if (!stored) {
      await store.setAuthIfAbsent(pairId, hash);
      const now2 = await store.getAuth(pairId);
      if (!now2 || !sameHex(now2, hash)) return json({ error: "forbidden" }, 403);
    } else if (!sameHex(stored, hash)) {
      return json({ error: "forbidden" }, 403);
    }
    const id = await store.append(pairId, from, box, now);
    return json({ id });
  }

  if (method === "DELETE") {
    if (stored && !sameHex(stored, hash)) return json({ error: "forbidden" }, 403);
    await store.remove(pairId);
    return json({ ok: true });
  }

  return json({ error: "method_not_allowed" }, 405, { Allow: "GET, POST, DELETE" });
}
