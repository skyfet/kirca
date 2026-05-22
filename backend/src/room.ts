import { DurableObject } from "cloudflare:workers";
import { notifyDevices, type ApnsEnv } from "./lib/apns";
import { logError } from "./lib/log";

type Env = ApnsEnv & {
  DB: D1Database;
};

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
  attachment_id: string | null;
};

const WS_RL_LIMIT = 10;
const WS_RL_WINDOW_MS = 5000;

/**
 * Одна Durable Object на одну комнату.
 * Держит активные WS-соединения и рассылает сообщения.
 * Использует WebSocket Hibernation API — между событиями инстанс не жжёт CPU.
 *
 * HTTP-эндпоинты (для воркера, internal):
 *   GET /online — список user_id онлайн (для GET /rooms/:id/members).
 *   POST /broadcast — внешний edit/delete/read broadcast (worker зовёт после записи в D1).
 */
export class Room extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/online") {
      const users = new Set<string>();
      for (const sock of this.ctx.getWebSockets()) {
        try {
          const a = sock.deserializeAttachment() as Attachment | null;
          if (a?.userId) users.add(a.userId);
        } catch { /* */ }
      }
      return Response.json({ users: [...users] });
    }
    if (url.pathname === "/broadcast" && request.method === "POST") {
      const payload = await request.text();
      this.broadcast(payload);
      return new Response(null, { status: 204 });
    }
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }
    const userId = url.searchParams.get("userId") ?? "";
    const username = url.searchParams.get("username") ?? "";
    const roomId = url.searchParams.get("roomId") ?? "";

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ userId, username, roomId } satisfies Attachment);

    // Уведомим остальных, что юзер появился. Это даёт presence без отдельного запроса.
    this.broadcast(
      JSON.stringify({ type: "presence", user_id: userId, online: true }),
      server,
    );

    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(payload: string, exclude?: WebSocket): void {
    for (const sock of this.ctx.getWebSockets()) {
      if (sock === exclude) continue;
      try { sock.send(payload); } catch { /* */ }
    }
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

    let msg: {
      type?: string;
      text?: string;
      client_id?: string;
      attachment_id?: string;
      is_typing?: boolean;
    };
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    if (msg.type === "typing") {
      // Без записи в D1, без rate-limit — но c сильным capping в клиенте.
      this.broadcast(
        JSON.stringify({
          type: "typing",
          user_id: att.userId,
          username: att.username,
          is_typing: msg.is_typing !== false,
        }),
        ws,
      );
      return;
    }

    if (msg.type !== "msg") return;
    const hasText = typeof msg.text === "string" && msg.text.trim().length > 0;
    const hasAttachment = typeof msg.attachment_id === "string" && msg.attachment_id.length > 0;
    if (!hasText && !hasAttachment) return;

    if (!(await this.checkWsRateLimit(att.userId))) {
      try {
        ws.send(JSON.stringify({ type: "error", code: "rate_limited" }));
      } catch { /* */ }
      return;
    }

    const text = hasText ? msg.text!.slice(0, 4000) : "";
    const attachmentId = hasAttachment ? msg.attachment_id!.slice(0, 64) : null;
    const clientId =
      typeof msg.client_id === "string" && msg.client_id.length > 0
        ? msg.client_id.slice(0, 64)
        : null;

    let stored: StoredMessage | null = null;
    if (clientId) {
      const existing = await this.env.DB
        .prepare(
          "SELECT id, client_id, user_id, username, text, created_at, attachment_id FROM messages WHERE room_id = ? AND client_id = ?",
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
        attachment_id: attachmentId,
      };
      try {
        await this.env.DB
          .prepare(
            "INSERT INTO messages (id, room_id, user_id, username, text, created_at, client_id, attachment_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
          )
          .bind(
            stored.id,
            att.roomId,
            stored.user_id,
            stored.username,
            stored.text,
            stored.created_at,
            clientId,
            attachmentId,
          )
          .run();
      } catch (_e) {
        if (clientId) {
          const existing = await this.env.DB
            .prepare(
              "SELECT id, client_id, user_id, username, text, created_at, attachment_id FROM messages WHERE room_id = ? AND client_id = ?",
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

    const attachmentPayload = await this.attachmentPayload(stored.attachment_id);

    const out = {
      type: "msg",
      id: stored.id,
      client_id: stored.client_id,
      user_id: stored.user_id,
      username: stored.username,
      text: stored.text,
      created_at: stored.created_at,
      attachment: attachmentPayload,
    };

    this.broadcast(JSON.stringify(out));

    if (isNew) {
      this.ctx.waitUntil(this.pushOffline(att.roomId, stored));
    }
  }

  private async attachmentPayload(
    attachmentId: string | null,
  ): Promise<Record<string, unknown> | null> {
    if (!attachmentId) return null;
    const a = await this.env.DB
      .prepare("SELECT id, mime, width, height FROM attachments WHERE id = ?")
      .bind(attachmentId)
      .first<{ id: string; mime: string; width: number | null; height: number | null }>();
    if (!a) return null;
    return {
      id: a.id,
      mime: a.mime,
      // Относительный путь — клиент подставляет apiBase и шлёт Authorization.
      url: `/attachments/${a.id}`,
      width: a.width,
      height: a.height,
    };
  }

  private async pushOffline(roomId: string, msg: StoredMessage): Promise<void> {
    try {
      const online = new Set<string>();
      for (const sock of this.ctx.getWebSockets()) {
        try {
          const a = sock.deserializeAttachment() as Attachment | null;
          if (a?.userId) online.add(a.userId);
        } catch { /* */ }
      }

      const room = await this.env.DB
        .prepare("SELECT name FROM rooms WHERE id = ?")
        .bind(roomId)
        .first<{ name: string }>();
      if (!room) return;

      // Не пушим тем, кто замьютил комнату.
      const { results } = await this.env.DB
        .prepare("SELECT user_id FROM memberships WHERE room_id = ? AND muted = 0")
        .bind(roomId)
        .all<{ user_id: string }>();
      const targets = (results ?? [])
        .map((r) => r.user_id)
        .filter((uid) => uid !== msg.user_id && !online.has(uid));
      if (targets.length === 0) return;

      const body = msg.text && msg.text.length > 0
        ? msg.text.length > 140 ? msg.text.slice(0, 140) + "…" : msg.text
        : "📎 вложение";

      await notifyDevices(this.env.DB, this.env, targets, {
        alert: {
          title: `${room.name} · ${msg.username}`,
          body,
        },
        sound: "default",
        "thread-id": roomId,
      });
    } catch (e) {
      logError({ at: "pushOffline", err: (e as Error).message });
    }
  }

  async webSocketClose(ws: WebSocket, code: number, _reason: string, _wasClean: boolean) {
    let userId = "";
    try {
      const a = ws.deserializeAttachment() as Attachment | null;
      userId = a?.userId ?? "";
    } catch { /* */ }
    try { ws.close(code, "bye"); } catch { /* */ }
    // Если у юзера больше нет открытых сокетов — broadcast offline.
    if (userId) {
      let stillOnline = false;
      for (const sock of this.ctx.getWebSockets()) {
        if (sock === ws) continue;
        try {
          const a = sock.deserializeAttachment() as Attachment | null;
          if (a?.userId === userId) { stillOnline = true; break; }
        } catch { /* */ }
      }
      if (!stillOnline) {
        this.broadcast(
          JSON.stringify({ type: "presence", user_id: userId, online: false }),
        );
      }
    }
  }

  async webSocketError(ws: WebSocket) {
    try { ws.close(1011, "error"); } catch { /* */ }
  }
}
