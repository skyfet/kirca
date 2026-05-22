import { Hono } from "hono";
import { validator } from "../lib/validator";

import { getUser, isRoomAccessible, requireAuth } from "../lib/middleware";
import { messageEditBody, readBody } from "../lib/schemas";
import type { Env, Vars } from "../lib/types";

export const messageRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

const MSG_COLUMNS =
  "id, room_id, client_id, user_id, username, text, created_at, edited_at, deleted_at, attachment_id";

// Прикручиваем attachment-данные на лету (один JOIN), чтобы клиент не делал second-trip.
const HISTORY_SELECT = `
  SELECT
    m.id, m.client_id, m.user_id, m.username, m.text, m.created_at,
    m.edited_at, m.deleted_at,
    m.attachment_id,
    a.mime AS attachment_mime,
    a.r2_key AS attachment_key,
    a.width AS attachment_width,
    a.height AS attachment_height
  FROM messages m
  LEFT JOIN attachments a ON a.id = m.attachment_id
`;

function shapeMessage(env: Env, row: Record<string, unknown>): Record<string, unknown> {
  const base = {
    id: row.id,
    client_id: row.client_id,
    user_id: row.user_id,
    username: row.username,
    text: row.deleted_at ? "" : row.text,
    created_at: row.created_at,
    edited_at: row.edited_at ?? null,
    deleted_at: row.deleted_at ?? null,
  };
  if (row.attachment_id) {
    const key = row.attachment_key as string;
    const base_url = env.R2_PUBLIC_BASE?.replace(/\/+$/, "") ?? null;
    return {
      ...base,
      attachment: {
        id: row.attachment_id,
        mime: row.attachment_mime,
        url: base_url ? `${base_url}/${key}` : null,
        width: row.attachment_width ?? null,
        height: row.attachment_height ?? null,
      },
    };
  }
  return base;
}

messageRoutes.get("/rooms/:id/history", requireAuth, async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const after = c.req.query("after");
  const before = c.req.query("before");
  const limit = Math.min(parseInt(c.req.query("limit") ?? "50", 10) || 50, 200);

  if (after !== undefined) {
    const ts = parseInt(after, 10) || 0;
    const { results } = await c.env.DB
      .prepare(
        `${HISTORY_SELECT} WHERE m.room_id = ? AND m.created_at > ? ORDER BY m.created_at ASC LIMIT ?`,
      )
      .bind(roomId, ts, limit)
      .all();
    return c.json({ messages: (results as Array<Record<string, unknown>>).map((r) => shapeMessage(c.env, r)) });
  }

  if (before !== undefined) {
    const ts = parseInt(before, 10);
    const { results } = await c.env.DB
      .prepare(
        `${HISTORY_SELECT} WHERE m.room_id = ? AND m.created_at < ? ORDER BY m.created_at DESC LIMIT ?`,
      )
      .bind(roomId, isNaN(ts) ? Date.now() : ts, limit)
      .all();
    return c.json({
      messages: (results as Array<Record<string, unknown>>).reverse().map((r) => shapeMessage(c.env, r)),
    });
  }

  const { results } = await c.env.DB
    .prepare(
      `${HISTORY_SELECT} WHERE m.room_id = ? ORDER BY m.created_at DESC LIMIT ?`,
    )
    .bind(roomId, limit)
    .all();
  return c.json({
    messages: (results as Array<Record<string, unknown>>).reverse().map((r) => shapeMessage(c.env, r)),
  });
});

messageRoutes.patch("/rooms/:id/messages/:msgId", requireAuth, validator("json", messageEditBody), async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  const msgId = c.req.param("msgId");
  const { text } = c.req.valid("json");

  const row = await c.env.DB
    .prepare("SELECT user_id, deleted_at FROM messages WHERE id = ? AND room_id = ?")
    .bind(msgId, roomId)
    .first<{ user_id: string; deleted_at: number | null }>();
  if (!row) return c.json({ error: "not found" }, 404);
  if (row.user_id !== u.id) return c.json({ error: "forbidden" }, 403);
  if (row.deleted_at) return c.json({ error: "deleted" }, 409);

  const now = Date.now();
  await c.env.DB
    .prepare("UPDATE messages SET text = ?, edited_at = ? WHERE id = ?")
    .bind(text.slice(0, 4000), now, msgId)
    .run();

  // Уведомим DO, чтобы он разослал update подключённым.
  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "edit",
        id: msgId,
        text: text.slice(0, 4000),
        edited_at: now,
      }),
    });
  } catch { /* DO может быть не поднят — ничего страшного */ }

  return c.json({ ok: true, id: msgId, text, edited_at: now });
});

messageRoutes.delete("/rooms/:id/messages/:msgId", requireAuth, async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  const msgId = c.req.param("msgId");

  const row = await c.env.DB
    .prepare("SELECT user_id, deleted_at FROM messages WHERE id = ? AND room_id = ?")
    .bind(msgId, roomId)
    .first<{ user_id: string; deleted_at: number | null }>();
  if (!row) return c.json({ error: "not found" }, 404);

  // Удалять может либо автор, либо owner комнаты.
  let allowed = row.user_id === u.id;
  if (!allowed) {
    const o = await c.env.DB
      .prepare("SELECT role FROM memberships WHERE user_id = ? AND room_id = ?")
      .bind(u.id, roomId)
      .first<{ role: string }>();
    allowed = o?.role === "owner";
  }
  if (!allowed) return c.json({ error: "forbidden" }, 403);
  if (row.deleted_at) return new Response(null, { status: 204 });

  const now = Date.now();
  await c.env.DB
    .prepare("UPDATE messages SET deleted_at = ?, text = '' WHERE id = ?")
    .bind(now, msgId)
    .run();

  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ type: "delete", id: msgId, deleted_at: now }),
    });
  } catch { /* */ }

  return new Response(null, { status: 204 });
});

// Read receipts: клиент сообщает «прочитал до created_at = X».
// Заодно дёрнем DO, чтобы расшарить состояние подключённым.
messageRoutes.post("/rooms/:id/read", requireAuth, validator("json", readBody), async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { last_read_at } = c.req.valid("json");
  await c.env.DB
    .prepare(
      `INSERT INTO read_state (user_id, room_id, last_read_at) VALUES (?, ?, ?)
       ON CONFLICT(user_id, room_id) DO UPDATE SET last_read_at = MAX(read_state.last_read_at, excluded.last_read_at)`,
    )
    .bind(u.id, roomId, last_read_at)
    .run();
  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "read",
        user_id: u.id,
        last_read_at,
      }),
    });
  } catch { /* */ }
  return c.json({ ok: true });
});

// Кто что прочитал — для отображения «прочитано N из M» / «✓✓».
messageRoutes.get("/rooms/:id/reads", requireAuth, async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { results } = await c.env.DB
    .prepare("SELECT user_id, last_read_at FROM read_state WHERE room_id = ?")
    .bind(roomId)
    .all();
  return c.json({ reads: results });
});

export { MSG_COLUMNS };
