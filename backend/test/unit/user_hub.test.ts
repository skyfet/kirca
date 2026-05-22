import { describe, it, expect, beforeEach } from "vitest";
import { SELF } from "cloudflare:test";
import { freshDb } from "./setup";

async function register(
  username: string,
  password: string,
): Promise<{ token: string; userId: string }> {
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
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ name, is_public: isPublic }),
  });
  const b = (await r.json()) as { id: string };
  return b.id;
}

async function openUserWs(token: string): Promise<WebSocket> {
  const r = await SELF.fetch(`http://x/v1/ws?token=${token}`, {
    headers: { Upgrade: "websocket" },
  });
  const ws = r.webSocket;
  if (!ws) throw new Error("no websocket in response");
  ws.accept();
  return ws as unknown as WebSocket;
}

async function openRoomWs(roomId: string, token: string): Promise<WebSocket> {
  const r = await SELF.fetch(`http://x/rooms/${roomId}/ws?token=${token}`, {
    headers: { Upgrade: "websocket" },
  });
  const ws = r.webSocket;
  if (!ws) throw new Error("no websocket in response");
  ws.accept();
  return ws as unknown as WebSocket;
}

function nextMessageMatching(
  ws: WebSocket,
  predicate: (msg: Record<string, unknown>) => boolean,
  timeoutMs = 3000,
): Promise<Record<string, unknown>> {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("ws timeout")), timeoutMs);
    const onMsg = (e: MessageEvent) => {
      try {
        const m = JSON.parse(e.data as string) as Record<string, unknown>;
        if (predicate(m)) {
          clearTimeout(t);
          ws.removeEventListener("message", onMsg as EventListener);
          resolve(m);
        }
      } catch {
        /* skip non-json */
      }
    };
    ws.addEventListener("message", onMsg as EventListener);
  });
}

describe("User-WS /v1/ws", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("шлёт hello при подключении", async () => {
    const a = await register("alice", "secret123");
    const ws = await openUserWs(a.token);
    const hello = await nextMessageMatching(ws, (m) => m.type === "hello");
    expect(hello.type).toBe("hello");
    try { ws.close(); } catch { /* */ }
  });

  it("отклоняет невалидный токен (1008)", async () => {
    const r = await SELF.fetch("http://x/v1/ws?token=00000000-0000-4000-8000-000000000000", {
      headers: { Upgrade: "websocket" },
    });
    const ws = r.webSocket;
    expect(ws).toBeTruthy();
    ws!.accept();
    const code = await new Promise<number>((resolve) => {
      (ws as unknown as WebSocket).addEventListener("close", (e) => resolve(e.code));
    });
    expect(code).toBe(1008);
  });

  it("получает new_message при отправке в комнату", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const roomId = await createRoom(a.token, "общий", true);
    // bob присоединяется (публичная комната)
    await SELF.fetch(`http://x/rooms/${roomId}/join`, {
      method: "POST",
      headers: { Authorization: `Bearer ${b.token}` },
    });

    // bob открывает свой user-ws, чтобы получать события глобально
    const bobUser = await openUserWs(b.token);
    await nextMessageMatching(bobUser, (m) => m.type === "hello");

    // alice пишет сообщение в комнату через per-room WS
    const aliceRoom = await openRoomWs(roomId, a.token);
    aliceRoom.send(JSON.stringify({ type: "msg", client_id: crypto.randomUUID(), text: "привет" }));

    const evt = await nextMessageMatching(bobUser, (m) => m.type === "new_message");
    expect(evt.room_id).toBe(roomId);
    const msg = evt.message as { text: string; user_id: string };
    expect(msg.text).toBe("привет");
    expect(msg.user_id).toBe(a.userId);

    try { aliceRoom.close(); bobUser.close(); } catch { /* */ }
  });

  it("получает invite_received при создании инвайта", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const roomId = await createRoom(a.token, "приватная", false);

    const bobUser = await openUserWs(b.token);
    await nextMessageMatching(bobUser, (m) => m.type === "hello");

    const r = await SELF.fetch(`http://x/rooms/${roomId}/invites`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${a.token}`,
      },
      body: JSON.stringify({ username: "bob" }),
    });
    expect(r.status).toBe(200);

    const evt = await nextMessageMatching(bobUser, (m) => m.type === "invite_received");
    const inv = evt.invite as { room_id: string; inviter_username: string };
    expect(inv.room_id).toBe(roomId);
    expect(inv.inviter_username).toBe("alice");

    try { bobUser.close(); } catch { /* */ }
  });

  it("получает room_added при acceptInvite", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const roomId = await createRoom(a.token, "клуб", false);

    const inviteRes = await SELF.fetch(`http://x/rooms/${roomId}/invites`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${a.token}`,
      },
      body: JSON.stringify({ username: "bob" }),
    });
    const invite = (await inviteRes.json()) as { id: string };

    const bobUser = await openUserWs(b.token);
    await nextMessageMatching(bobUser, (m) => m.type === "hello");

    const acc = await SELF.fetch(`http://x/invites/${invite.id}/accept`, {
      method: "POST",
      headers: { Authorization: `Bearer ${b.token}` },
    });
    expect(acc.status).toBe(200);

    const evt = await nextMessageMatching(bobUser, (m) => m.type === "room_added");
    const room = evt.room as { id: string; name: string };
    expect(room.id).toBe(roomId);
    expect(room.name).toBe("клуб");

    try { bobUser.close(); } catch { /* */ }
  });

  it("получает read_self на свою же markRead с другого устройства", async () => {
    const a = await register("alice", "secret123");
    const roomId = await createRoom(a.token, "соло", true);

    const aliceUser = await openUserWs(a.token);
    await nextMessageMatching(aliceUser, (m) => m.type === "hello");

    const r = await SELF.fetch(`http://x/rooms/${roomId}/read`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${a.token}`,
      },
      body: JSON.stringify({ last_read_at: 1234567890 }),
    });
    expect(r.status).toBe(200);

    const evt = await nextMessageMatching(aliceUser, (m) => m.type === "read_self");
    expect(evt.room_id).toBe(roomId);
    expect(evt.last_read_at).toBe(1234567890);

    try { aliceUser.close(); } catch { /* */ }
  });
});
