import { handleSync } from "@/lib/server/sync-relay";
import { syncStore } from "@/lib/server/sync-relay-store";

// Spotless device sync mailbox (src/lib/server/sync-relay.ts). Request-time only: every handler reads
// the request, so nothing here is prerendered or cached.

type Ctx = { params: Promise<{ pairId: string }> };

async function handle(req: Request, ctx: Ctx) {
  const { pairId } = await ctx.params;
  try {
    return await handleSync(req, pairId, syncStore());
  } catch {
    console.error("sync relay: storage error");
    return Response.json({ error: "unavailable" }, { status: 503, headers: { "Cache-Control": "no-store" } });
  }
}

export const GET = handle;
export const POST = handle;
export const DELETE = handle;
