# Spotless sync relay (for the opena.tech repo)

Drop-in files for `~/Projects/opena`, laid out at the paths they go to there. They were written and verified
(`npm run lint`, `npm run build`, `npm run sync:test`) in a copy of that repo. Nothing has been committed in the
opena.tech repo yet. The client is `crates/core/src/sync/relay.rs`; the design is `docs/SYNC.md` §5.2.

| File | Goes to |
|---|---|
| `src/lib/server/sync-relay.ts` | request handling (auth, limits, routes), testable without Next |
| `src/lib/server/sync-relay-store.ts` | Upstash Redis store + in-memory store (dev/tests only) |
| `src/app/api/sync/[pairId]/route.ts` | thin route |
| `scripts/sync-relay-test.mjs` | handler tests (9), run with jiti |
| `legal.tsx.patch` | privacy page: new "Device sync (optional)" section, intro wording, date |

## Apply (in ~/Projects/opena)

```sh
git switch -c sync-relay
cp -R <app repo>/docs/sync-relay/src/. src/
cp <app repo>/docs/sync-relay/scripts/sync-relay-test.mjs scripts/
patch -p1 < <app repo>/docs/sync-relay/legal.tsx.patch
npm pkg set scripts.sync:test="node scripts/sync-relay-test.mjs"
npm run sync:test && npm run lint && npm run build
git add -A src/app/api/sync src/lib/server/sync-relay*.ts scripts/sync-relay-test.mjs src/data/legal.tsx package.json
git commit -m "Spotless sync relay: encrypted mailbox at /api/sync/<pair>"
```

## Deploy (with the owner's go-ahead)

1. The route reads the same Upstash env as `savings-store.ts`: `KV_REST_API_URL` and `KV_REST_API_TOKEN`. They
   already exist on the Vercel project if the savings counter runs on Redis; check with `vercel env ls`. Without
   them the route answers 503 in production (it never falls back to memory there).
2. Merge `sync-relay` and deploy as usual (`vercel --prod` or the Git integration).
3. Smoke test (expects 200 and an empty list; any 64-hex token works for an unused pair):
   `curl -s -H "Authorization: Bearer $(openssl rand -hex 32)" https://opena.tech/api/sync/$(openssl rand -hex 16)`
4. Storage: each pair holds at most 25 MB for at most 30 days. On the Upstash free plan (256 MB) that is enough for
   about ten heavy pairs at the cap, far more in practice (initial syncs go over the LAN; the relay carries
   increments). Watch the database size in the Upstash console after launch.
5. Rate limits are per serverless instance (the existing in-memory limiter). If abuse shows up, move them to Redis
   (`INCR` + `EXPIRE` per minute bucket).
