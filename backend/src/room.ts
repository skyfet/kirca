import { DurableObject } from "cloudflare:workers";
import { notifyDevices, type ApnsEnv } from "./lib/apns";
import { logError } from "./lib/log";

type Env = ApnsEnv & { DB: D1Database };

type Attachment = {
  userId: string;
  username: string;
  roomId: string;
};

type StoredMessage = {
  id: string;
  client_id: string | null;
  user_id: string;
  username: string;
  text: string;
  created_at: number;
};

// WS-level rate limit (per user per DO): защита от спама в комнату.
const WS_RL_LIMIT = 10;
const WS_RL_WINDOW_MS = 5000;

/**
 * Одна Durable Object на одну комнату.
 * Держит активные WS-соединения и рассылает сообщения.
 * Использует WebSocket Hibernation API — между событиями инстанс не жжёт CPU.
 */
export class Room extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const url = new URL(request.url);
    const userId = url.searchParams.get("userId") ?? "";
    const username = url.searchParams.get("username") ?? "";
    const roomId = url.searchParams.get("roomId") ?? "";

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ userId, username, roomId } satisfies Attachment);

    return new Response(null, { status: 101, webSocket: client });
  }

  private async checkWsRateLimit(userId: string): Promise<boolean> {
    const key = `rl:${userId}`;
    const now = Date.now();
    const cur = (await this.ctx.storage.get<{ count: number; ws: number }>(key)) ?? null;
    if (!cur || now - cur.ws >= WS_RL_WINDOW_MS) {
      await this.ctx.storage.put(key, { count: 1, ws: now });
      return true;
    }
    if (cur.count >= WS_RL_LIMIT) return false;
    await this.ctx.storage.put(key, { count: cur.count + 1, ws: cur.ws });
    return true;
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    const att = ws.deserializeAttachment() as Attachment;
    if (typeof raw !== "string") return;

    let msg: { type?: string; text?: string; client_id?: string };
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type !== "msg" || typeof msg.text !== "string" || !msg.text.trim()) return;

    if (!(await this.checkWsRateLimit(att.userId))) {
      try {
        ws.send(JSON.stringify({ type: "error", code: "rate_limited" }));
      } catch {}
      return;
    }

    const text = msg.text.slice(0, 4000);
    const clientId = typeof msg.client_id === "string" && msg.client_id.length > 0
      ? msg.client_id.slice(0, 64)
      : null;

    // Дедуп: если client_id задан и сообщение уже было — отдаём существующее.
    let stored: StoredMessage | null = null;
    if (clientId) {
      const existing = await this.env.DB
        .prepare(
          "SELECT id, client_id, user_id, username, text, created_at FROM messages WHERE room_id = ? AND client_id = ?"
        )
        .bind(att.roomId, clientId)
        .first<StoredMessage>();
      if (existing) stored = existing;
    }

    const isNew = !stored;
    if (!stored) {
      stored = {
        id: crypto.randomUUID(),
        client_id: clientId,
        user_id: att.userId,
        username: att.username,
        text,
        created_at: Date.now(),
      };
      try {
        await this.env.DB
          .prepare(
            "INSERT INTO messages (id, room_id, user_id, username, text, created_at, client_id) VALUES (?, ?, ?, ?, ?, ?, ?)"
          )
          .bind(stored.id, att.roomId, stored.user_id, stored.username, stored.text, stored.created_at, clientId)
          .run();
      } catch (_e) {
        // Гонка: параллельный коннект уже вставил эту же (room_id, client_id).
        // Перечитываем существующую строку и используем её.
        if (clientId) {
          const existing = await this.env.DB
            .prepare(
              "SELECT id, client_id, user_id, username, text, created_at FROM messages WHERE room_id = ? AND client_id = ?"
            )
            .bind(att.roomId, clientId)
            .first<StoredMessage>();
          if (existing) stored = existing;
          else throw _e;
        } else {
          throw _e;
        }
      }
    }

    const out = {
      type: "msg",
      id: stored.id,
      client_id: stored.client_id,
      user_id: stored.user_id,
      username: stored.username,
      text: stored.text,
      created_at: stored.created_at,
    };

    const payload = JSON.stringify(out);
    for (const sock of this.ctx.getWebSockets()) {
      try { sock.send(payload); } catch { /* socket мёртв — игнор */ }
    }

    // Push offline-юзерам — только для новых сообщений (не для повторов с тем же client_id).
    if (isNew) {
      this.ctx.waitUntil(this.pushOffline(att.roomId, stored));
    }
  }

  private async pushOffline(roomId: string, msg: StoredMessage): Promise<void> {
    try {
      // Кто онлайн в этой DO.
      const online = new Set<string>();
      for (const sock of this.ctx.getWebSockets()) {
        try {
          const a = sock.deserializeAttachment() as Attachment | null;
          if (a?.userId) online.add(a.userId);
        } catch {}
      }

      // Получатели: участники комнаты, кроме онлайн и автора.
      // Для публичных комнат пушим только тем, кто join-нулся (owner/member).
      const room = await this.env.DB
        .prepare("SELECT name FROM rooms WHERE id = ?")
        .bind(roomId)
        .first<{ name: string }>();
      if (!room) return;

      const { results } = await this.env.DB
        .prepare("SELECT user_id FROM memberships WHERE room_id = ?")
        .bind(roomId)
        .all<{ user_id: string }>();
      const targets = (results ?? [])
        .map((r) => r.user_id)
        .filter((uid) => uid !== msg.user_id && !online.has(uid));
      if (targets.length === 0) return;

      await notifyDevices(this.env.DB, this.env, targets, {
        alert: {
          title: `${room.name} · ${msg.username}`,
          body: msg.text.length > 140 ? msg.text.slice(0, 140) + "…" : msg.text,
        },
        sound: "default",
        "thread-id": roomId,
      });
    } catch (e) {
      logError({ at: "pushOffline", err: (e as Error).message });
    }
  }

  async webSocketClose(ws: WebSocket, code: number, _reason: string, _wasClean: boolean) {
    try { ws.close(code, "bye"); } catch { /* already closed */ }
  }

  async webSocketError(ws: WebSocket) {
    try { ws.close(1011, "error"); } catch { /* */ }
  }
}
