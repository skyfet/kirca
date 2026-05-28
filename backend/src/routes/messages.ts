import { getUser, isRoomAccessible, requireAuth } from "../lib/middleware";
import { notifyRoomMembers, notifyUser } from "../lib/notify";
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
import { forwardBody, messageEditBody, reactionBody, readBody } from "../lib/schemas";
import type { Env } from "../lib/types";

export const messageRoutes = createApp();

const MSG_COLUMNS =
  "id, room_id, client_id, user_id, username, text, created_at, edited_at, deleted_at, attachment_id";

const HISTORY_SELECT = `
  SELECT
    m.id, m.client_id, m.user_id, m.username, m.text, m.created_at,
    m.edited_at, m.deleted_at,
    m.attachment_id, m.ciphertext, m.iv, m.key_version,
    m.reply_to_id,
    m.forwarded_from_room_id, m.forwarded_from_msg_id, m.forwarded_from_username,
    a.mime AS attachment_mime,
    a.r2_key AS attachment_key,
    a.width AS attachment_width,
    a.height AS attachment_height,
    a.blurhash AS attachment_blurhash,
    a.duration_ms AS attachment_duration_ms,
    a.wrapped_key AS attachment_wrapped_key,
    a.wrapped_key_iv AS attachment_wrapped_key_iv,
    a.iv AS attachment_iv,
    a.key_version AS attachment_key_version
  FROM messages m
  LEFT JOIN attachments a ON a.id = m.attachment_id
`;

const MessageSchema = z
  .object({
    id: z.number().int().describe("Monotonic server id."),
    client_id: z.string().uuid().describe("Idempotency key from the client."),
    user_id: z.string().uuid(),
    username: z.string(),
    text: z.string().describe("Empty in E2E rooms — see ciphertext/iv."),
    created_at: z.number().int().describe("Unix epoch milliseconds."),
    edited_at: z.number().int().nullable().optional(),
    deleted_at: z.number().int().nullable().optional(),
    attachment: z.record(z.unknown()).optional(),
    ciphertext: z.string().optional().describe("base64 AES-GCM ciphertext, set in E2E rooms."),
    iv: z.string().optional(),
    key_version: z.number().int().optional(),
    reply_to_id: z.string().nullable().optional().describe("F1: id of the quoted message."),
    forwarded_from_room_id: z.string().nullable().optional(),
    forwarded_from_msg_id: z.string().nullable().optional(),
    forwarded_from_username: z.string().nullable().optional(),
    reactions: z
      .array(
        z.object({
          emoji: z.string(),
          count: z.number().int(),
          mine: z.boolean(),
          user_ids: z.array(z.string()),
        }),
      )
      .optional()
      .describe("F2: aggregated reactions on this message."),
  })
  .openapi("Message");

type ReactionAgg = { emoji: string; count: number; mine: boolean; user_ids: string[] };

function shapeMessage(
  env: Env,
  row: Record<string, unknown>,
  reactionsById?: Map<string, ReactionAgg[]>,
): Record<string, unknown> {
  const isE2e = !!row.ciphertext;
  const base: Record<string, unknown> = {
    id: row.id,
    client_id: row.client_id,
    user_id: row.user_id,
    username: row.username,
    text: row.deleted_at ? "" : row.text,
    created_at: row.created_at,
    edited_at: row.edited_at ?? null,
    deleted_at: row.deleted_at ?? null,
    reply_to_id: row.reply_to_id ?? null,
    forwarded_from_room_id: row.forwarded_from_room_id ?? null,
    forwarded_from_msg_id: row.forwarded_from_msg_id ?? null,
    forwarded_from_username: row.forwarded_from_username ?? null,
  };
  if (isE2e && !row.deleted_at) {
    base.ciphertext = row.ciphertext;
    base.iv = row.iv;
    base.key_version = row.key_version;
  }
  if (row.attachment_id) {
    const key = row.attachment_key as string;
    const base_url = env.R2_PUBLIC_BASE?.replace(/\/+$/, "") ?? null;
    const att: Record<string, unknown> = {
      id: row.attachment_id,
      mime: row.attachment_mime,
      url: base_url ? `${base_url}/${key}` : null,
      width: row.attachment_width ?? null,
      height: row.attachment_height ?? null,
      blurhash: row.attachment_blurhash ?? null,
      duration_ms: row.attachment_duration_ms ?? null,
    };
    if (row.attachment_wrapped_key) {
      att.wrapped_key = row.attachment_wrapped_key;
      att.wrapped_key_iv = row.attachment_wrapped_key_iv;
      att.iv = row.attachment_iv;
      att.key_version = row.attachment_key_version;
    }
    base.attachment = att;
  }
  if (reactionsById) {
    base.reactions = reactionsById.get(String(row.id)) ?? [];
  }
  return base;
}

/**
 * F2: aggregate reactions for a page of messages in ONE query, returning a
 * map of message_id -> [{emoji, count, mine, user_ids}]. Empty map when the
 * page has no messages (caller should skip calling this).
 */
async function reactionsForPage(
  env: Env,
  rows: Array<Record<string, unknown>>,
  meId: string,
): Promise<Map<string, ReactionAgg[]>> {
  const out = new Map<string, ReactionAgg[]>();
  const ids = rows.map((r) => String(r.id));
  if (ids.length === 0) return out;
  const placeholders = ids.map(() => "?").join(",");
  const { results } = await env.DB
    .prepare(
      `SELECT message_id, emoji, user_id FROM reactions WHERE message_id IN (${placeholders})`,
    )
    .bind(...ids)
    .all<{ message_id: string; emoji: string; user_id: string }>();
  // message_id -> emoji -> agg
  const byMsg = new Map<string, Map<string, ReactionAgg>>();
  for (const r of results ?? []) {
    let emojiMap = byMsg.get(r.message_id);
    if (!emojiMap) {
      emojiMap = new Map();
      byMsg.set(r.message_id, emojiMap);
    }
    let agg = emojiMap.get(r.emoji);
    if (!agg) {
      agg = { emoji: r.emoji, count: 0, mine: false, user_ids: [] };
      emojiMap.set(r.emoji, agg);
    }
    agg.count += 1;
    agg.user_ids.push(r.user_id);
    if (r.user_id === meId) agg.mine = true;
  }
  for (const [msgId, emojiMap] of byMsg) {
    out.set(msgId, [...emojiMap.values()]);
  }
  return out;
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
    const rows = results as Array<Record<string, unknown>>;
    const reactions = rows.length ? await reactionsForPage(c.env, rows, u.id) : undefined;
    return c.json(
      { messages: rows.map((r) => shapeMessage(c.env, r, reactions)) } as never,
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
    const rows = (results as Array<Record<string, unknown>>).reverse();
    const reactions = rows.length ? await reactionsForPage(c.env, rows, u.id) : undefined;
    return c.json(
      { messages: rows.map((r) => shapeMessage(c.env, r, reactions)) } as never,
      200,
    );
  }

  const { results } = await c.env.DB
    .prepare(
      `${HISTORY_SELECT} WHERE m.room_id = ? ORDER BY m.created_at DESC LIMIT ?`,
    )
    .bind(roomId, limit)
    .all();
  const rows = (results as Array<Record<string, unknown>>).reverse();
  const reactions = rows.length ? await reactionsForPage(c.env, rows, u.id) : undefined;
  return c.json(
    { messages: rows.map((r) => shapeMessage(c.env, r, reactions)) } as never,
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
        ciphertext: z.string().optional(),
        iv: z.string().optional(),
        key_version: z.number().int().optional(),
      }),
      "Updated.",
    ),
    400: errorResponse("Wrong body shape for the room type."),
    401: unauthorized,
    403: errorResponse("Not the author."),
    404: notFound,
    409: errorResponse("Already deleted."),
  },
});

messageRoutes.openapi(editMessageRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId, msgId } = c.req.valid("param");
  const body = c.req.valid("json");

  const row = await c.env.DB
    .prepare("SELECT user_id, deleted_at FROM messages WHERE id = ? AND room_id = ?")
    .bind(msgId, roomId)
    .first<{ user_id: string; deleted_at: number | null }>();
  if (!row) return c.json({ error: "not found" }, 404);
  if (row.user_id !== u.id) return c.json({ error: "forbidden" }, 403);
  if (row.deleted_at) return c.json({ error: "deleted" }, 409);

  const room = await c.env.DB
    .prepare("SELECT e2e FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ e2e: number }>();
  const isE2e = room?.e2e === 1;

  const now = Date.now();
  let textOut = "";
  let cipherOut: { ciphertext: string; iv: string; key_version: number } | null = null;

  if (isE2e) {
    if (!body.ciphertext || !body.iv || body.key_version == null) {
      return c.json({ error: "e2e edit requires ciphertext, iv, key_version" }, 400);
    }
    const ct = body.ciphertext.slice(0, 8192);
    const iv = body.iv.slice(0, 64);
    const kv = body.key_version;
    await c.env.DB
      .prepare(
        "UPDATE messages SET text = '', ciphertext = ?, iv = ?, key_version = ?, edited_at = ? WHERE id = ?",
      )
      .bind(ct, iv, kv, now, msgId)
      .run();
    cipherOut = { ciphertext: ct, iv, key_version: kv };
  } else {
    if (!body.text) {
      return c.json({ error: "plain room edit requires text" }, 400);
    }
    textOut = body.text.slice(0, 4000);
    await c.env.DB
      .prepare("UPDATE messages SET text = ?, edited_at = ? WHERE id = ?")
      .bind(textOut, now, msgId)
      .run();
  }

  const editBroadcast: Record<string, unknown> = {
    type: "edit",
    id: msgId,
    text: textOut,
    edited_at: now,
  };
  if (cipherOut) {
    editBroadcast.ciphertext = cipherOut.ciphertext;
    editBroadcast.iv = cipherOut.iv;
    editBroadcast.key_version = cipherOut.key_version;
  }

  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(editBroadcast),
    });
  } catch { /* */ }

  const fanout: Record<string, unknown> = {
    type: "message_edited",
    room_id: roomId,
    id: msgId,
    text: textOut,
    edited_at: now,
  };
  if (cipherOut) {
    fanout.ciphertext = cipherOut.ciphertext;
    fanout.iv = cipherOut.iv;
    fanout.key_version = cipherOut.key_version;
  }
  c.executionCtx.waitUntil(notifyRoomMembers(c.env, roomId, fanout));

  const response: Record<string, unknown> = {
    ok: true,
    id: msgId,
    text: textOut,
    edited_at: now,
  };
  if (cipherOut) {
    response.ciphertext = cipherOut.ciphertext;
    response.iv = cipherOut.iv;
    response.key_version = cipherOut.key_version;
  }
  return c.json(response as never, 200);
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

  c.executionCtx.waitUntil(
    notifyRoomMembers(c.env, roomId, {
      type: "message_deleted",
      room_id: roomId,
      id: msgId,
      deleted_at: now,
    }),
  );

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
  // Мульти-девайс sync: другие устройства этого юзера обнулят unread.
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, {
      type: "read_self",
      room_id: roomId,
      last_read_at,
    }),
  );
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

// ---- F12 NSE single-message fetch ----------------------------------------

const SingleMessageSchema = z
  .object({
    id: z.string(),
    room_id: z.string(),
    user_id: z.string(),
    username: z.string(),
    created_at: z.number().int(),
    e2e: z.boolean(),
    ciphertext: z.string().nullable(),
    iv: z.string().nullable(),
    key_version: z.number().int().nullable(),
    text: z.string(),
    attachment: z.record(z.unknown()).nullable(),
    reply_to_id: z.string().nullable(),
  })
  .openapi("SingleMessage");

const singleMessageRoute = createRoute({
  method: "get",
  path: "/rooms/{id}/messages/{msgId}",
  tags: ["rooms"],
  summary: "Fetch one message (used by the iOS Notification Service Extension)",
  description:
    "Returns a single message by id. For E2E rooms the ciphertext/iv/key_version " +
    "are returned (text is empty); for plaintext rooms text is set and ciphertext is null.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string(), msgId: z.string() }) },
  responses: {
    200: jsonContent(SingleMessageSchema, "OK."),
    401: unauthorized,
    403: errorResponse("No access."),
    404: notFound,
  },
});

messageRoutes.openapi(singleMessageRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId, msgId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { results } = await c.env.DB
    .prepare(`${HISTORY_SELECT} WHERE m.room_id = ? AND m.id = ? LIMIT 1`)
    .bind(roomId, msgId)
    .all();
  const rows = results as Array<Record<string, unknown>>;
  if (rows.length === 0) return c.json({ error: "not found" }, 404);
  const row = rows[0];
  const isE2e = !!row.ciphertext;
  const shaped = shapeMessage(c.env, row);
  return c.json(
    {
      id: row.id,
      room_id: roomId,
      user_id: row.user_id,
      username: row.username,
      created_at: row.created_at,
      e2e: isE2e,
      ciphertext: isE2e ? (row.ciphertext as string) : null,
      iv: isE2e ? (row.iv as string | null) : null,
      key_version: isE2e ? (row.key_version as number | null) : null,
      text: isE2e ? "" : (row.deleted_at ? "" : (row.text as string)),
      attachment: (shaped.attachment as Record<string, unknown> | undefined) ?? null,
      reply_to_id: row.reply_to_id ?? null,
    } as never,
    200,
  );
});

// ---- F2 reactions ---------------------------------------------------------

const addReactionRoute = createRoute({
  method: "put",
  path: "/rooms/{id}/messages/{msgId}/reactions",
  tags: ["rooms"],
  summary: "Add a reaction to a message",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string(), msgId: z.string() }),
    body: { required: true, content: { "application/json": { schema: reactionBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Stored."),
    401: unauthorized,
    403: errorResponse("No access."),
  },
});

messageRoutes.openapi(addReactionRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId, msgId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { emoji } = c.req.valid("json");
  const now = Date.now();
  await c.env.DB
    .prepare(
      "INSERT OR IGNORE INTO reactions (message_id, room_id, user_id, emoji, created_at) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(msgId, roomId, u.id, emoji, now)
    .run();

  const event = {
    type: "reaction_add",
    message_id: msgId,
    user_id: u.id,
    emoji,
    created_at: now,
  };
  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(event),
    });
  } catch { /* */ }
  c.executionCtx.waitUntil(
    notifyRoomMembers(c.env, roomId, {
      type: "reaction_add",
      room_id: roomId,
      message_id: msgId,
      user_id: u.id,
      emoji,
    }),
  );
  return c.json({ ok: true }, 200);
});

const removeReactionRoute = createRoute({
  method: "delete",
  path: "/rooms/{id}/messages/{msgId}/reactions/{emoji}",
  tags: ["rooms"],
  summary: "Remove a reaction from a message",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string(), msgId: z.string(), emoji: z.string() }) },
  responses: {
    204: { description: "Removed." },
    401: unauthorized,
    403: errorResponse("No access."),
  },
});

messageRoutes.openapi(removeReactionRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId, msgId, emoji: rawEmoji } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const emoji = decodeURIComponent(rawEmoji);
  await c.env.DB
    .prepare("DELETE FROM reactions WHERE message_id = ? AND user_id = ? AND emoji = ?")
    .bind(msgId, u.id, emoji)
    .run();

  const event = {
    type: "reaction_remove",
    message_id: msgId,
    user_id: u.id,
    emoji,
  };
  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(event),
    });
  } catch { /* */ }
  c.executionCtx.waitUntil(
    notifyRoomMembers(c.env, roomId, {
      type: "reaction_remove",
      room_id: roomId,
      message_id: msgId,
      user_id: u.id,
      emoji,
    }),
  );
  return c.body(null, 204);
});

// ---- F18 forward ----------------------------------------------------------

const forwardRoute = createRoute({
  method: "post",
  path: "/rooms/{id}/forward",
  tags: ["rooms"],
  summary: "Forward a message into this (target) room",
  description:
    "Inserts a new message into the target room carrying provenance to the source " +
    "message. The server never transcrypts: for an E2E target the client supplies " +
    "re-encrypted ciphertext/iv/key_version; for a plaintext target it supplies text.",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string() }),
    body: { required: true, content: { "application/json": { schema: forwardBody } } },
  },
  responses: {
    200: jsonContent(z.object({ message: MessageSchema }), "Stored."),
    400: errorResponse("Wrong body shape for the target room type."),
    401: unauthorized,
    403: errorResponse("No access to target or source room."),
  },
});

messageRoutes.openapi(forwardRoute, async (c) => {
  const u = getUser(c);
  const { id: targetRoomId } = c.req.valid("param");
  const body = c.req.valid("json");

  if (!(await isRoomAccessible(c.env, targetRoomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  if (!(await isRoomAccessible(c.env, body.source_room_id, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const targetRoom = await c.env.DB
    .prepare("SELECT e2e FROM rooms WHERE id = ?")
    .bind(targetRoomId)
    .first<{ e2e: number }>();
  const isE2e = targetRoom?.e2e === 1;

  let text = "";
  let ciphertext: string | null = null;
  let iv: string | null = null;
  let keyVersion: number | null = null;
  if (isE2e) {
    if (!body.ciphertext || !body.iv || body.key_version == null) {
      return c.json({ error: "e2e forward requires ciphertext, iv, key_version" }, 400);
    }
    ciphertext = body.ciphertext.slice(0, 8192);
    iv = body.iv.slice(0, 64);
    keyVersion = body.key_version;
  } else {
    text = (body.text ?? "").slice(0, 4000);
  }
  const attachmentId = body.attachment_id ? body.attachment_id.slice(0, 64) : null;
  const clientId = body.client_id.slice(0, 64);

  // Resolve provenance username from the source message.
  const src = await c.env.DB
    .prepare("SELECT username FROM messages WHERE id = ? AND room_id = ?")
    .bind(body.source_msg_id, body.source_room_id)
    .first<{ username: string }>();
  const fwdUsername = src?.username ?? null;

  const selectExisting = () =>
    c.env.DB
      .prepare(`${HISTORY_SELECT} WHERE m.room_id = ? AND m.client_id = ? LIMIT 1`)
      .bind(targetRoomId, clientId)
      .first<Record<string, unknown>>();

  const existing = await selectExisting();
  if (existing) {
    return c.json({ message: shapeMessage(c.env, existing) } as never, 200);
  }

  const id = crypto.randomUUID();
  const now = Date.now();
  let row: Record<string, unknown> | null = null;
  try {
    await c.env.DB
      .prepare(
        `INSERT INTO messages
           (id, room_id, user_id, username, text, created_at, client_id,
            attachment_id, ciphertext, iv, key_version,
            forwarded_from_room_id, forwarded_from_msg_id, forwarded_from_username)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      )
      .bind(
        id,
        targetRoomId,
        u.id,
        u.username,
        text,
        now,
        clientId,
        attachmentId,
        ciphertext,
        iv,
        keyVersion,
        body.source_room_id,
        body.source_msg_id,
        fwdUsername,
      )
      .run();
  } catch (e) {
    // Idempotency: UNIQUE(room_id, client_id) conflict -> return existing.
    const dup = await selectExisting();
    if (dup) return c.json({ message: shapeMessage(c.env, dup) } as never, 200);
    throw e;
  }

  row = await c.env.DB
    .prepare(`${HISTORY_SELECT} WHERE m.room_id = ? AND m.id = ? LIMIT 1`)
    .bind(targetRoomId, id)
    .first<Record<string, unknown>>();
  const shaped = shapeMessage(c.env, row ?? {});

  // Broadcast over the target Room DO, mirroring the WS path.
  const broadcast: Record<string, unknown> = {
    type: "msg",
    id,
    client_id: clientId,
    user_id: u.id,
    username: u.username,
    text,
    created_at: now,
    attachment: shaped.attachment ?? null,
    reply_to_id: null,
    mentions: null,
    forwarded_from_room_id: body.source_room_id,
    forwarded_from_msg_id: body.source_msg_id,
    forwarded_from_username: fwdUsername,
  };
  if (ciphertext) {
    broadcast.ciphertext = ciphertext;
    broadcast.iv = iv;
    broadcast.key_version = keyVersion;
  }
  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(targetRoomId));
    await stub.fetch("https://room.internal/broadcast", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(broadcast),
    });
  } catch { /* */ }

  // Fan out new_message exactly like the WS path.
  const room = await c.env.DB
    .prepare("SELECT name FROM rooms WHERE id = ?")
    .bind(targetRoomId)
    .first<{ name: string }>();
  const messagePayload: Record<string, unknown> = { ...broadcast };
  delete messagePayload.type;
  c.executionCtx.waitUntil(
    notifyRoomMembers(c.env, targetRoomId, {
      type: "new_message",
      room_id: targetRoomId,
      room_name: room?.name ?? "",
      message: messagePayload,
    }),
  );

  return c.json({ message: shaped } as never, 200);
});

export { MSG_COLUMNS };
