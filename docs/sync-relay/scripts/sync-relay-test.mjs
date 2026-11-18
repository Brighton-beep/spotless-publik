// Spotless sync relay: handler tests against the in-memory store. `npm run sync:test`.
// jiti loads the TypeScript modules the route uses, so this tests the real code without Next.
import assert from "node:assert/strict";
import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url);
const { handleSync, MAX_BODY, PAIR_PER_MIN } = await jiti.import("../src/lib/server/sync-relay.ts");
const { MemoryStore, TTL_SECONDS } = await jiti.import("../src/lib/server/sync-relay-store.ts");

const PAIR = "0123456789abcdef0123456789abcdef";
const TOKEN = "a".repeat(64);
const OTHER = "b".repeat(64);
let ip = 0;
const T = Date.now();
const req = (method, { pair = PAIR, token = TOKEN, body, query = "", fresh = true } = {}) =>
  new Request(`https://opena.tech/api/sync/${pair}${query}`, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      // A new client IP per request unless a test is about the per-IP limit.
      "x-forwarded-for": fresh ? `10.0.${(ip >> 8) & 255}.${ip++ & 255}` : "10.9.9.9",
      ...(body !== undefined ? { "content-type": "application/json" } : {}),
    },
    body: body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body),
  });

let n = 0;
async function test(name, fn) {
  await fn();
  n++;
  console.log(`ok - ${name}`);
}

await test("unknown pair reads empty; bad pair id is 400", async () => {
  const s = new MemoryStore();
  const r = await handleSync(req("GET", { query: "?after=7" }), PAIR, s);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { items: [], next: 7, oldest: null, more: false });
  assert.equal((await handleSync(req("GET", { pair: "nothex" }), "nothex", s)).status, 400);
  assert.equal((await handleSync(req("GET", { pair: PAIR.toUpperCase() }), PAIR.toUpperCase(), s)).status, 400);
});

await test("no store in production is 503; missing or malformed token is 403", async () => {
  assert.equal((await handleSync(req("GET"), PAIR, null)).status, 503);
  const s = new MemoryStore();
  assert.equal((await handleSync(req("GET", { token: null }), PAIR, s)).status, 403);
  assert.equal((await handleSync(req("GET", { token: "abc" }), PAIR, s)).status, 403);
});

await test("first POST stores the token; a different token is refused everywhere", async () => {
  const s = new MemoryStore();
  const r = await handleSync(req("POST", { body: { from: "dev-aaaaaaaaaaaaaaaa", box: "AAAA" } }), PAIR, s);
  assert.equal(r.status, 200);
  assert.deepEqual(await r.json(), { id: 1 });
  for (const m of ["GET", "DELETE"]) assert.equal((await handleSync(req(m, { token: OTHER }), PAIR, s)).status, 403);
  const p = await handleSync(req("POST", { token: OTHER, body: { from: "dev-bbbbbbbbbbbbbbbb", box: "BBBB" } }), PAIR, s);
  assert.equal(p.status, 403);
});

await test("POST then GET: order, cursors, after filtering", async () => {
  const s = new MemoryStore();
  for (let i = 1; i <= 5; i++) {
    const r = await handleSync(req("POST", { body: { from: "dev-aaaaaaaaaaaaaaaa", box: `box${i}` } }), PAIR, s, T + i);
    assert.equal((await r.json()).id, i);
  }
  const all = await (await handleSync(req("GET"), PAIR, s, T + 100)).json();
  assert.deepEqual(all.items.map((i) => i.id), [1, 2, 3, 4, 5]);
  assert.deepEqual(all.items[0], { id: 1, from: "dev-aaaaaaaaaaaaaaaa", box: "box1", at: T + 1 });
  assert.equal(all.next, 5);
  assert.equal(all.oldest, 1);
  assert.equal(all.more, false);
  const after = await (await handleSync(req("GET", { query: "?after=3" }), PAIR, s, T + 100)).json();
  assert.deepEqual(after.items.map((i) => i.box), ["box4", "box5"]);
  const none = await (await handleSync(req("GET", { query: "?after=5" }), PAIR, s, T + 100)).json();
  assert.deepEqual([none.items.length, none.next, none.more], [0, 5, false]);
});

await test("limit pages with more", async () => {
  const s = new MemoryStore();
  for (let i = 0; i < 7; i++) await handleSync(req("POST", { body: { from: "dev-aaaaaaaaaaaaaaaa", box: "x" } }), PAIR, s);
  const p1 = await (await handleSync(req("GET", { query: "?limit=3" }), PAIR, s)).json();
  assert.deepEqual([p1.items.length, p1.next, p1.more], [3, 3, true]);
  const p2 = await (await handleSync(req("GET", { query: `?after=${p1.next}&limit=3` }), PAIR, s)).json();
  assert.deepEqual([p2.items[0].id, p2.next, p2.more], [4, 6, true]);
  const p3 = await (await handleSync(req("GET", { query: `?after=${p2.next}&limit=3` }), PAIR, s)).json();
  assert.deepEqual([p3.items.length, p3.more], [1, false]);
});

await test("bad bodies are 400, oversize is 413", async () => {
  const s = new MemoryStore();
  for (const body of ["not json", { from: "x", box: "AAAA" }, { from: "dev-aaaaaaaaaaaaaaaa" }, { from: "dev-aaaaaaaaaaaaaaaa", box: "no spaces!" }]) {
    assert.equal((await handleSync(req("POST", { body }), PAIR, s)).status, 400, JSON.stringify(body));
  }
  const big = { from: "dev-aaaaaaaaaaaaaaaa", box: "A".repeat(MAX_BODY) };
  assert.equal((await handleSync(req("POST", { body: big }), PAIR, s)).status, 413);
});

await test("items older than 30 days are dropped", async () => {
  const s = new MemoryStore();
  const t0 = Date.now();
  const day = 24 * 3600 * 1000;
  // An active mailbox: the old item ages out while the newer ones stay.
  await handleSync(req("POST", { body: { from: "dev-aaaaaaaaaaaaaaaa", box: "old" } }), PAIR, s, t0);
  await handleSync(req("POST", { body: { from: "dev-aaaaaaaaaaaaaaaa", box: "mid" } }), PAIR, s, t0 + 20 * day);
  const later = t0 + TTL_SECONDS * 1000 + 1000;
  await handleSync(req("POST", { body: { from: "dev-aaaaaaaaaaaaaaaa", box: "new" } }), PAIR, s, later);
  const r = await (await handleSync(req("GET"), PAIR, s, later)).json();
  assert.deepEqual(r.items.map((i) => i.box), ["mid", "new"]);
  assert.equal(r.oldest, 2, "a client still at 0 or 1 sees the gap and asks for a resync");
  // An idle one is gone entirely 30 days after its last write.
  const idle = await (await handleSync(req("GET"), PAIR, s, later + TTL_SECONDS * 1000 + 1)).json();
  assert.deepEqual(idle.items, []);
});

await test("rate limit per pair returns 429 with Retry-After", async () => {
  const s = new MemoryStore();
  const pair = "fedcba9876543210fedcba9876543210";
  let last;
  for (let i = 0; i <= PAIR_PER_MIN; i++) last = await handleSync(req("GET", { pair }), pair, s);
  assert.equal(last.status, 429);
  assert.ok(last.headers.get("retry-after"));
});

await test("DELETE removes the mailbox", async () => {
  const s = new MemoryStore();
  const pair = "11111111111111111111111111111111";
  await handleSync(req("POST", { pair, body: { from: "dev-aaaaaaaaaaaaaaaa", box: "x" } }), pair, s);
  assert.equal((await handleSync(req("DELETE", { pair }), pair, s)).status, 200);
  const r = await (await handleSync(req("GET", { pair }), pair, s)).json();
  assert.deepEqual(r.items, []);
  // And the token is forgotten: a new group may claim the id.
  assert.equal((await handleSync(req("POST", { pair, token: OTHER, body: { from: "dev-bbbbbbbbbbbbbbbb", box: "y" } }), pair, s)).status, 200);
});

console.log(`\n${n} passed`);
