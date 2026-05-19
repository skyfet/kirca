import { DurableObject } from "cloudflare:workers";

type Env = { DB: D1Database };

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

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    const att = ws.deserializeAttachment() as Attachment;
    if (typeof raw !== "string") return;

    let msg: { type?: string; text?: string; client_id?: string };
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type !== "msg" || typeof msg.text !== "string" || !msg.text.trim()) return;

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
  }

  async webSocketClose(ws: WebSocket, code: number, _reason: string, _wasClean: boolean) {
    try { ws.close(code, "bye"); } catch { /* already closed */ }
  }

  async webSocketError(ws: WebSocket) {
    try { ws.close(1011, "error"); } catch { /* */ }
  }
}
