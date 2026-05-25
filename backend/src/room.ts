import { DurableObject } from "cloudflare:workers";
import { notifyDevices, type ApnsEnv } from "./lib/apns";
import { logError } from "./lib/log";
import { notifyUsers } from "./lib/notify";

type Env = ApnsEnv & {
  DB: D1Database;
  USER_HUB: DurableObjectNamespace;
  R2_PUBLIC_BASE?: string;
};

type Attachment = {
  userId: string;
  username: string;
  roomId: string;
  // E2E rooms store opaque ciphertext instead of plaintext text. Flag is set
  // when the WS upgrade is accepted and read back on each message.
  e2e?: boolean;
};

type StoredMessage = {
  id: string;
  client_id: string | null;
  user_id: string;
  username: string;
  text: string;
  created_at: number;
  attachment_id: string | null;
  ciphertext: string | null;
  iv: string | null;
  key_version: number | null;
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
    const e2e = url.searchParams.get("e2e") === "1";

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ userId, username, roomId, e2e } satisfies Attachment);

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
      ciphertext?: string;
      iv?: string;
      key_version?: number;
    };
    try {
      msg = JSON.parse(raw);
    } catch {
      return;
    }

    if (msg.type === "typing") {
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
    const isE2e = att.e2e === true;
    const hasText = typeof msg.text === "string" && msg.text.trim().length > 0;
    const hasAttachment = typeof msg.attachment_id === "string" && msg.attachment_id.length > 0;
    const hasCipher =
      typeof msg.ciphertext === "string" && msg.ciphertext.length > 0 &&
      typeof msg.iv === "string" && msg.iv.length > 0 &&
      typeof msg.key_version === "number" && msg.key_version >= 0;

    if (isE2e) {
      // E2E rooms accept ciphertext (with optional attachment_id). Plaintext
      // is silently dropped — clients on these rooms must encrypt.
      if (!hasCipher && !hasAttachment) return;
    } else {
      if (!hasText && !hasAttachment) return;
    }

    if (!(await this.checkWsRateLimit(att.userId))) {
      try { ws.send(JSON.stringify({ type: "error", code: "rate_limited" })); } catch { /* */ }
      return;
    }

    const text = !isE2e && hasText ? msg.text!.slice(0, 4000) : "";
    const ciphertext = isE2e && hasCipher ? msg.ciphertext!.slice(0, 8192) : null;
    const iv = isE2e && hasCipher ? msg.iv!.slice(0, 64) : null;
    const keyVersion = isE2e && hasCipher ? msg.key_version! : null;
    const attachmentId = hasAttachment ? msg.attachment_id!.slice(0, 64) : null;
    const clientId =
      typeof msg.client_id === "string" && msg.client_id.length > 0
        ? msg.client_id.slice(0, 64)
        : null;

    const selectExisting = () =>
      this.env.DB
        .prepare(
          "SELECT id, client_id, user_id, username, text, created_at, attachment_id, ciphertext, iv, key_version FROM messages WHERE room_id = ? AND client_id = ?",
        )
        .bind(att.roomId, clientId)
        .first<StoredMessage>();

    let stored: StoredMessage | null = null;
    if (clientId) {
      const existing = await selectExisting();
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
        ciphertext,
        iv,
        key_version: keyVersion,
      };
      try {
        await this.env.DB
          .prepare(
            `INSERT INTO messages
               (id, room_id, user_id, username, text, created_at, client_id,
                attachment_id, ciphertext, iv, key_version)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
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
            ciphertext,
            iv,
            keyVersion,
          )
          .run();
      } catch (_e) {
        if (clientId) {
          const existing = await selectExisting();
          if (existing) stored = existing;
          else throw _e;
        } else {
          throw _e;
        }
      }
    }

    const attachmentPayload = await this.attachmentPayload(stored.attachment_id);

    const out: Record<string, unknown> = {
      type: "msg",
      id: stored.id,
      client_id: stored.client_id,
      user_id: stored.user_id,
      username: stored.username,
      text: stored.text,
      created_at: stored.created_at,
      attachment: attachmentPayload,
    };
    if (stored.ciphertext) {
      out.ciphertext = stored.ciphertext;
      out.iv = stored.iv;
      out.key_version = stored.key_version;
    }

    this.broadcast(JSON.stringify(out));

    if (isNew) {
      this.ctx.waitUntil(this.fanoutNewMessage(att.roomId, stored, attachmentPayload));
      this.ctx.waitUntil(this.pushOffline(att.roomId, stored, isE2e));
    }
  }

  /**
   * Разослать new_message событие в персональные WS-каналы всех членов
   * комнаты — чтобы список комнат и unread-счётчик обновились в фоне,
   * даже если конкретный чат не открыт.
   */
  private async fanoutNewMessage(
    roomId: string,
    msg: StoredMessage,
    attachment: Record<string, unknown> | null,
  ): Promise<void> {
    try {
      const room = await this.env.DB
        .prepare("SELECT name FROM rooms WHERE id = ?")
        .bind(roomId)
        .first<{ name: string }>();
      const { results } = await this.env.DB
        .prepare("SELECT user_id FROM memberships WHERE room_id = ?")
        .bind(roomId)
        .all<{ user_id: string }>();
      if (!room || !results) return;
      const recipients = results.map((r) => r.user_id);
      const messagePayload: Record<string, unknown> = {
        id: msg.id,
        client_id: msg.client_id,
        user_id: msg.user_id,
        username: msg.username,
        text: msg.text,
        created_at: msg.created_at,
        attachment,
      };
      if (msg.ciphertext) {
        messagePayload.ciphertext = msg.ciphertext;
        messagePayload.iv = msg.iv;
        messagePayload.key_version = msg.key_version;
      }
      await notifyUsers(this.env, recipients, {
        type: "new_message",
        room_id: roomId,
        room_name: room.name,
        message: messagePayload,
      });
    } catch (e) {
      logError({ at: "fanoutNewMessage", err: (e as Error).message });
    }
  }

  private async attachmentPayload(
    attachmentId: string | null,
  ): Promise<Record<string, unknown> | null> {
    if (!attachmentId) return null;
    const a = await this.env.DB
      .prepare(
        "SELECT id, mime, r2_key, width, height, wrapped_key, wrapped_key_iv, iv, key_version FROM attachments WHERE id = ?",
      )
      .bind(attachmentId)
      .first<{
        id: string;
        mime: string;
        r2_key: string;
        width: number | null;
        height: number | null;
        wrapped_key: string | null;
        wrapped_key_iv: string | null;
        iv: string | null;
        key_version: number | null;
      }>();
    if (!a) return null;
    const base = this.env.R2_PUBLIC_BASE?.replace(/\/+$/, "") ?? null;
    // E2E attachments never have a public URL (R2 holds ciphertext) — clients
    // hit the authed /attachments/:id passthrough instead.
    const isE2e = a.wrapped_key !== null;
    const payload: Record<string, unknown> = {
      id: a.id,
      mime: a.mime,
      url: !isE2e && base ? `${base}/${a.r2_key}` : null,
      width: a.width,
      height: a.height,
    };
    if (isE2e) {
      payload.wrapped_key = a.wrapped_key;
      payload.wrapped_key_iv = a.wrapped_key_iv;
      payload.iv = a.iv;
      payload.key_version = a.key_version;
    }
    return payload;
  }

  private async pushOffline(
    roomId: string,
    msg: StoredMessage,
    isE2e: boolean,
  ): Promise<void> {
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

      const { results } = await this.env.DB
        .prepare("SELECT user_id FROM memberships WHERE room_id = ? AND muted = 0")
        .bind(roomId)
        .all<{ user_id: string }>();
      const targets = (results ?? [])
        .map((r) => r.user_id)
        .filter((uid) => uid !== msg.user_id && !online.has(uid));
      if (targets.length === 0) return;

      // For E2E rooms the server never sees plaintext, so push previews are
      // intentionally opaque. For plain rooms we keep the existing snippet.
      const body = isE2e
        ? "📩 новое сообщение"
        : msg.text && msg.text.length > 0
          ? msg.text.length > 140 ? msg.text.slice(0, 140) + "…" : msg.text
          : "📎 вложение";

      await notifyDevices(this.env.DB, this.env, targets, {
        alert: {
          title: isE2e ? `${room.name} · 🔒` : `${room.name} · ${msg.username}`,
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
