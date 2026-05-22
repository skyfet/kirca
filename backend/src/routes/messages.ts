import { getUser, isRoomAccessible, requireAuth } from "../lib/middleware";
import {
  createApp,
  createRoute,
  errorResponse,
  forbidden,
  jsonContent,
  notFound,
  unauthorized,
  z,
} from "../lib/openapi";
import { messageEditBody, readBody } from "../lib/schemas";
import type { Env } from "../lib/types";

export const messageRoutes = createApp();

const MSG_COLUMNS =
  "id, room_id, client_id, user_id, username, text, created_at, edited_at, deleted_at, attachment_id";

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

const MessageSchema = z
  .object({
    id: z.number().int().describe("Monotonic server id."),
    client_id: z.string().uuid().describe("Idempotency key from the client."),
    user_id: z.string().uuid(),
    username: z.string(),
    text: z.string(),
    created_at: z.number().int().describe("Unix epoch milliseconds."),
    edited_at: z.number().int().nullable().optional(),
    deleted_at: z.number().int().nullable().optional(),
    attachment: z.record(z.unknown()).optional(),
  })
  .openapi("Message");

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

const historyRoute = createRoute({
  method: "get",
  path: "/rooms/{id}/history",
  tags: ["rooms"],
  summary: "Fetch message history",
  description:
    "Three modes:\n- no params → last 50 messages, ascending\n- `?after=<ts>` → messages strictly after `ts` (used after reconnect to fill gaps), ascending, up to 200\n- `?before=<ts>&limit=N` → older messages, ascending after a server-side reverse, up to 200\n\nTimestamps are unix epoch milliseconds.",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string().uuid() }),
    query: z.object({
      after: z.string().optional().describe("Return messages with `created_at > after`."),
      before: z.string().optional().describe("Return messages with `created_at < before`."),
      limit: z.string().optional(),
    }),
  },
  responses: {
    200: jsonContent(z.object({ messages: z.array(MessageSchema) }), "OK."),
    401: unauthorized,
    403: errorResponse("Not a member of a private room."),
  },
});

messageRoutes.openapi(historyRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const q = c.req.valid("query");
  const after = q.after;
  const before = q.before;
  const limit = Math.min(parseInt(q.limit ?? "50", 10) || 50, 200);

  if (after !== undefined) {
    const ts = parseInt(after, 10) || 0;
    const { results } = await c.env.DB
      .prepare(
        `${HISTORY_SELECT} WHERE m.room_id = ? AND m.created_at > ? ORDER BY m.created_at ASC LIMIT ?`,
      )
      .bind(roomId, ts, limit)
      .all();
    return c.json(
      { messages: (results as Array<Record<string, unknown>>).map((r) => shapeMessage(c.env, r)) } as never,
      200,
    );
  }

  if (before !== undefined) {
    const ts = parseInt(before, 10);
    const { results } = await c.env.DB
      .prepare(
        `${HISTORY_SELECT} WHERE m.room_id = ? AND m.created_at < ? ORDER BY m.created_at DESC LIMIT ?`,
      )
      .bind(roomId, isNaN(ts) ? Date.now() : ts, limit)
      .all();
    return c.json(
      {
        messages: (results as Array<Record<string, unknown>>)
          .reverse()
          .map((r) => shapeMessage(c.env, r)),
      } as never,
      200,
    );
  }

  const { results } = await c.env.DB
    .prepare(
      `${HISTORY_SELECT} WHERE m.room_id = ? ORDER BY m.created_at DESC LIMIT ?`,
    )
    .bind(roomId, limit)
    .all();
  return c.json(
    {
      messages: (results as Array<Record<string, unknown>>)
        .reverse()
        .map((r) => shapeMessage(c.env, r)),
    } as never,
    200,
  );
});

const editMessageRoute = createRoute({
  method: "patch",
  path: "/rooms/{id}/messages/{msgId}",
  tags: ["rooms"],
  summary: "Edit a message (author only)",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string(), msgId: z.string() }),
    body: { required: true, content: { "application/json": { schema: messageEditBody } } },
  },
  responses: {
    200: jsonContent(
      z.object({
        ok: z.boolean(),
        id: z.string(),
        text: z.string(),
        edited_at: z.number().int(),
      }),
      "Updated.",
    ),
    401: unauthorized,
    403: errorResponse("Not the author."),
    404: notFound,
    409: errorResponse("Already deleted."),
  },
});

messageRoutes.openapi(editMessageRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId, msgId } = c.req.valid("param");
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
  } catch { /* DO может быть не поднят */ }

  return c.json({ ok: true, id: msgId, text, edited_at: now }, 200);
});

const deleteMessageRoute = createRoute({
  method: "delete",
  path: "/rooms/{id}/messages/{msgId}",
  tags: ["rooms"],
  summary: "Delete a message (author or owner)",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string(), msgId: z.string() }) },
  responses: {
    204: { description: "Tombstoned." },
    401: unauthorized,
    403: forbidden,
    404: notFound,
  },
});

messageRoutes.openapi(deleteMessageRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId, msgId } = c.req.valid("param");

  const row = await c.env.DB
    .prepare("SELECT user_id, deleted_at FROM messages WHERE id = ? AND room_id = ?")
    .bind(msgId, roomId)
    .first<{ user_id: string; deleted_at: number | null }>();
  if (!row) return c.json({ error: "not found" }, 404);

  let allowed = row.user_id === u.id;
  if (!allowed) {
    const o = await c.env.DB
      .prepare("SELECT role FROM memberships WHERE user_id = ? AND room_id = ?")
      .bind(u.id, roomId)
      .first<{ role: string }>();
    allowed = o?.role === "owner";
  }
  if (!allowed) return c.json({ error: "forbidden" }, 403);
  if (row.deleted_at) return c.body(null, 204);

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

  return c.body(null, 204);
});

const readRoute = createRoute({
  method: "post",
  path: "/rooms/{id}/read",
  tags: ["rooms"],
  summary: "Mark messages read up to a timestamp",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string() }),
    body: { required: true, content: { "application/json": { schema: readBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Stored."),
    401: unauthorized,
    403: errorResponse("No access."),
  },
});

messageRoutes.openapi(readRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
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
  return c.json({ ok: true }, 200);
});

const readsRoute = createRoute({
  method: "get",
  path: "/rooms/{id}/reads",
  tags: ["rooms"],
  summary: "Per-user last_read_at for the room",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(
      z.object({
        reads: z.array(z.object({ user_id: z.string(), last_read_at: z.number().int() })),
      }),
      "OK.",
    ),
    401: unauthorized,
    403: errorResponse("No access."),
  },
});

messageRoutes.openapi(readsRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { results } = await c.env.DB
    .prepare("SELECT user_id, last_read_at FROM read_state WHERE room_id = ?")
    .bind(roomId)
    .all();
  return c.json({ reads: results } as never, 200);
});

export { MSG_COLUMNS };
