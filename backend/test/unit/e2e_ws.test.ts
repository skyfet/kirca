import { describe, it, expect, beforeEach } from "vitest";
import { SELF, env } from "cloudflare:test";
import { freshDb } from "./setup";

async function register(u: string, p: string) {
  const r = await SELF.fetch("http://x/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: u, password: p }),
  });
  const b = (await r.json()) as { token: string; user: { id: string } };
  return { token: b.token, userId: b.user.id };
}

async function openWs(roomId: string, token: string): Promise<WebSocket> {
  const r = await SELF.fetch(`http://x/rooms/${roomId}/ws?token=${token}`, {
    headers: { Upgrade: "websocket" },
  });
  const ws = r.webSocket;
  if (!ws) throw new Error("no websocket in response");
  ws.accept();
  return ws as unknown as WebSocket;
}

function nextMessage(ws: WebSocket, timeoutMs = 2000): Promise<string> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("ws timeout")), timeoutMs);
    const onMsg = (e: MessageEvent) => {
      clearTimeout(t);
      ws.removeEventListener("message", onMsg as EventListener);
      resolve(e.data as string);
    };
    ws.addEventListener("message", onMsg as EventListener);
  });
}

const b64 = (n: number) =>
  Buffer.from(Array.from({ length: n }, (_, i) => (i * 7 + 3) & 0xff)).toString("base64");

describe("WS in E2E rooms", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("accepts ciphertext, broadcasts it, persists in D1", async () => {
    const a = await register("alice", "passwd123");
    const room = (await (
      await SELF.fetch("http://x/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
        body: JSON.stringify({ name: "secret", e2e: true }),
      })
    ).json()) as { id: string; e2e: boolean };
    expect(room.e2e).toBe(true);

    const ws = await openWs(room.id, a.token);
    const clientId = crypto.randomUUID();
    const ct = b64(48);
    const iv = b64(12);
    ws.send(
      JSON.stringify({
        type: "msg",
        client_id: clientId,
        ciphertext: ct,
        iv,
        key_version: 1,
      }),
    );
    const m = JSON.parse(await nextMessage(ws));
    expect(m.type).toBe("msg");
    expect(m.ciphertext).toBe(ct);
    expect(m.iv).toBe(iv);
    expect(m.key_version).toBe(1);
    expect(m.text).toBe(""); // plain text empty in e2e rooms

    const row = await env.DB
      .prepare("SELECT text, ciphertext, iv, key_version FROM messages WHERE room_id = ?")
      .bind(room.id)
      .first<{ text: string; ciphertext: string; iv: string; key_version: number }>();
    expect(row?.text).toBe("");
    expect(row?.ciphertext).toBe(ct);
    expect(row?.iv).toBe(iv);
    expect(row?.key_version).toBe(1);

    try { ws.close(); } catch { /* */ }
  });

  it("drops plaintext sent into an E2E room", async () => {
    const a = await register("bob", "passwd123");
    const room = (await (
      await SELF.fetch("http://x/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
        body: JSON.stringify({ name: "secret", e2e: true }),
      })
    ).json()) as { id: string };

    const ws = await openWs(room.id, a.token);
    ws.send(
      JSON.stringify({
        type: "msg",
        client_id: crypto.randomUUID(),
        text: "this should not be stored",
      }),
    );
    // Nothing should come back — give it a moment and assert DB is empty.
    await new Promise((r) => setTimeout(r, 200));
    const row = await env.DB
      .prepare("SELECT COUNT(*) AS n FROM messages WHERE room_id = ?")
      .bind(room.id)
      .first<{ n: number }>();
    expect(row?.n).toBe(0);

    try { ws.close(); } catch { /* */ }
  });

  it("history returns ciphertext fields for E2E messages", async () => {
    const a = await register("carol", "passwd123");
    const room = (await (
      await SELF.fetch("http://x/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
        body: JSON.stringify({ name: "secret", e2e: true }),
      })
    ).json()) as { id: string };

    const ws = await openWs(room.id, a.token);
    const ct = b64(48);
    const iv = b64(12);
    ws.send(
      JSON.stringify({
        type: "msg",
        client_id: crypto.randomUUID(),
        ciphertext: ct,
        iv,
        key_version: 1,
      }),
    );
    await nextMessage(ws);

    const h = await SELF.fetch(`http://x/rooms/${room.id}/history`, {
      headers: { Authorization: `Bearer ${a.token}` },
    });
    expect(h.status).toBe(200);
    const body = (await h.json()) as { messages: Array<Record<string, unknown>> };
    expect(body.messages.length).toBe(1);
    const m = body.messages[0];
    expect(m.text).toBe("");
    expect(m.ciphertext).toBe(ct);
    expect(m.iv).toBe(iv);
    expect(m.key_version).toBe(1);

    try { ws.close(); } catch { /* */ }
  });
});
