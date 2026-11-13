import { expect, test } from "bun:test";
import receipt from "../../schema/fixtures/ingest-receipt.json";
import { startServer } from "../src/server.ts";
import { fixture, setup } from "./helpers.ts";

test("Mac 确认契约来自真实 HTTP 入库，包含接受、重复和明确拒收", async () => {
  const ctx = setup();
  const duplicate = fixture(), fresh = fixture(), invalid = fixture({ source: "mac.git" });
  ctx.db.ingest([duplicate]);
  const server = startServer({ db: ctx.db, token: ctx.config.token, port: 0 });
  try {
    const response = await fetch(`http://127.0.0.1:${server.port}/v1/ingest`, {
      method: "POST", headers: { authorization: `Bearer ${ctx.config.token}`, "content-type": "application/json" },
      body: JSON.stringify({ device: "mac", records: [fresh, duplicate, invalid] }),
    });
    expect(response.status).toBe(200);
    expect(await response.json()).toEqual(receipt);
    expect(ctx.db.get(fresh.id)?.body).toBe(fresh.body);
    expect(ctx.db.get(duplicate.id)?.body).toBe(duplicate.body);
    expect(ctx.db.get(invalid.id)).toBeNull();
  } finally { await server.stop(true); ctx.cleanup(); }
});
