import { describe, it, expect, beforeEach } from "vitest";
import { SELF, env } from "cloudflare:test";
import { freshDb } from "./setup";

async function register(username: string, password: string): Promise<{ token: string; userId: string }> {
  const r = await SELF.fetch("http://x/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }),
  });
  const b = (await r.json()) as { token: string; user: { id: string } };
  return { token: b.token, userId: b.user.id };
}

async function createRoom(token: string, name: string, isPublic: boolean): Promise<string> {
  const r = await SELF.fetch("http://x/rooms", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ name, is_public: isPublic }),
  });
  const b = (await r.json()) as { id: string };
  return b.id;
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

describe("WS dedup", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("одинаковый client_id вставляется только один раз", async () => {
    const a = await register("alice", "secret123");
    const roomId = await createRoom(a.token, "test", true);

    const ws = await openWs(roomId, a.token);
    const clientId = crypto.randomUUID();

    ws.send(JSON.stringify({ type: "msg", client_id: clientId, text: "hello" }));
    const m1 = JSON.parse(await nextMessage(ws));
    expect(m1.type).toBe("msg");
    expect(m1.text).toBe("hello");
    const id1 = m1.id;

    // повтор с тем же client_id — сервер должен вернуть ту же запись, не создавая новую
    ws.send(JSON.stringify({ type: "msg", client_id: clientId, text: "hello" }));
    const m2 = JSON.parse(await nextMessage(ws));
    expect(m2.id).toBe(id1);

    const rows = await env.DB
      .prepare("SELECT COUNT(*) AS n FROM messages WHERE room_id = ?")
      .bind(roomId)
      .first<{ n: number }>();
    expect(rows?.n).toBe(1);

    try { ws.close(); } catch {}
  });
});
