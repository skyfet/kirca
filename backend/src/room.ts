import { DurableObject } from "cloudflare:workers";

type Env = { DB: D1Database };

type Attachment = {
  userId: string;
  username: string;
  roomId: string;
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
    // Сохраняем данные пользователя на сокете — переживут гибернацию
    server.serializeAttachment({ userId, username, roomId } satisfies Attachment);

    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(ws: WebSocket, raw: string | ArrayBuffer) {
    const att = ws.deserializeAttachment() as Attachment;
    if (typeof raw !== "string") return;

    let msg: { type?: string; text?: string };
    try { msg = JSON.parse(raw); } catch { return; }
    if (msg.type !== "msg" || typeof msg.text !== "string" || !msg.text.trim()) return;

    const out = {
      type: "msg",
      id: crypto.randomUUID(),
      user_id: att.userId,
      username: att.username,
      text: msg.text.slice(0, 4000),
      created_at: Date.now(),
    };

    // 1) пишем в D1
    await this.env.DB
      .prepare(
        "INSERT INTO messages (id, room_id, user_id, username, text, created_at) VALUES (?, ?, ?, ?, ?, ?)"
      )
      .bind(out.id, att.roomId, out.user_id, out.username, out.text, out.created_at)
      .run();

    // 2) рассылаем всем активным сокетам этой комнаты
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
