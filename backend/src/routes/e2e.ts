import { getUser, isRoomAccessible, requireAuth } from "../lib/middleware";
import {
  createApp,
  createRoute,
  errorResponse,
  jsonContent,
  notFound,
  unauthorized,
  z,
} from "../lib/openapi";
import { identityPublishBody, mentionTagPublishBody, publishRoomKeysBody } from "../lib/schemas";

export const e2eRoutes = createApp();

// ---- identity bundle -------------------------------------------------------

const IdentityFullSchema = z
  .object({
    identity_pub: z.string().nullable(),
    identity_priv_wrapped: z.string().nullable(),
    identity_priv_iv: z.string().nullable(),
    recovery_salt: z.string().nullable(),
    identity_updated_at: z.number().int().nullable(),
  })
  .openapi("IdentityBundle");

const IdentityPublicSchema = z
  .object({
    user_id: z.string(),
    identity_pub: z.string().nullable(),
    identity_updated_at: z.number().int().nullable(),
  })
  .openapi("IdentityPublic");

const publishIdentityRoute = createRoute({
  method: "put",
  path: "/me/identity",
  tags: ["auth"],
  summary: "Publish or rotate the E2E identity bundle",
  description:
    "Stores the user's X25519 public key, the AES-GCM wrapped private key " +
    "(wrapped under a recovery-key derived from the 24-word phrase), the IV " +
    "used to wrap it, and the recovery salt. The server treats all four as " +
    "opaque base64 blobs and cannot decrypt the private key.",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: identityPublishBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean(), updated_at: z.number().int() }), "Stored."),
    401: unauthorized,
  },
});

e2eRoutes.openapi(publishIdentityRoute, async (c) => {
  const u = getUser(c);
  const body = c.req.valid("json");
  const now = Date.now();
  await c.env.DB
    .prepare(
      `UPDATE users
       SET identity_pub = ?, identity_priv_wrapped = ?, identity_priv_iv = ?,
           recovery_salt = ?, identity_updated_at = ?
       WHERE id = ?`,
    )
    .bind(
      body.identity_pub,
      body.identity_priv_wrapped,
      body.identity_priv_iv,
      body.recovery_salt,
      now,
      u.id,
    )
    .run();
  return c.json({ ok: true, updated_at: now }, 200);
});

const getMyIdentityRoute = createRoute({
  method: "get",
  path: "/me/identity",
  tags: ["auth"],
  summary: "Read the current user's identity bundle (for restore)",
  description:
    "Returns the wrapped private key + salt so a new device can re-derive the recovery key from the 24-word phrase and decrypt the private key locally.",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(IdentityFullSchema, "Bundle (any field may be null if not yet published)."),
    401: unauthorized,
  },
});

e2eRoutes.openapi(getMyIdentityRoute, async (c) => {
  const u = getUser(c);
  const row = await c.env.DB
    .prepare(
      `SELECT identity_pub, identity_priv_wrapped, identity_priv_iv,
              recovery_salt, identity_updated_at
       FROM users WHERE id = ?`,
    )
    .bind(u.id)
    .first<{
      identity_pub: string | null;
      identity_priv_wrapped: string | null;
      identity_priv_iv: string | null;
      recovery_salt: string | null;
      identity_updated_at: number | null;
    }>();
  return c.json(
    row ?? {
      identity_pub: null,
      identity_priv_wrapped: null,
      identity_priv_iv: null,
      recovery_salt: null,
      identity_updated_at: null,
    },
    200,
  );
});

const getUserIdentityRoute = createRoute({
  method: "get",
  path: "/users/{id}/identity",
  tags: ["auth"],
  summary: "Fetch a user's E2E public key",
  description:
    "Returns only the X25519 public key — used by other clients to wrap a room key for this user. The wrapped private key is never returned through this endpoint.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(IdentityPublicSchema, "Public key (may be null if user has not opted in)."),
    401: unauthorized,
    404: notFound,
  },
});

e2eRoutes.openapi(getUserIdentityRoute, async (c) => {
  const { id } = c.req.valid("param");
  const row = await c.env.DB
    .prepare("SELECT id, identity_pub, identity_updated_at FROM users WHERE id = ?")
    .bind(id)
    .first<{ id: string; identity_pub: string | null; identity_updated_at: number | null }>();
  if (!row) return c.json({ error: "not found" }, 404);
  return c.json(
    {
      user_id: row.id,
      identity_pub: row.identity_pub,
      identity_updated_at: row.identity_updated_at,
    },
    200,
  );
});

// ---- room keys -------------------------------------------------------------

const SealedRoomKeySchema = z
  .object({
    room_id: z.string(),
    member_user_id: z.string(),
    key_version: z.number().int(),
    sealed: z.string(),
    created_at: z.number().int(),
  })
  .openapi("SealedRoomKey");

const publishKeysRoute = createRoute({
  method: "post",
  path: "/rooms/{id}/keys",
  tags: ["rooms"],
  summary: "Publish sealed room-key envelopes for members",
  description:
    "Caller (a current member with the room key) seals the AES-256 room key " +
    "for each recipient using that recipient's X25519 public key, and uploads " +
    "the envelopes. Server stores them as opaque base64 and cannot decrypt.",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string() }),
    body: { required: true, content: { "application/json": { schema: publishRoomKeysBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean(), stored: z.number().int() }), "OK."),
    401: unauthorized,
    403: errorResponse("Not a member or room is not E2E."),
    404: notFound,
  },
});

e2eRoutes.openapi(publishKeysRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  const { key_version, keys } = c.req.valid("json");

  const room = await c.env.DB
    .prepare("SELECT id, e2e FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ id: string; e2e: number }>();
  if (!room) return c.json({ error: "not found" }, 404);
  if (room.e2e !== 1) return c.json({ error: "room is not e2e" }, 403);
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const now = Date.now();
  const stmts = keys.map((k) =>
    c.env.DB
      .prepare(
        `INSERT INTO room_keys (room_id, member_user_id, key_version, sealed, created_at)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(room_id, member_user_id, key_version)
         DO UPDATE SET sealed = excluded.sealed, created_at = excluded.created_at`,
      )
      .bind(roomId, k.member_user_id, key_version, k.sealed, now),
  );
  // Bump room.key_version if we just advanced past the current.
  stmts.push(
    c.env.DB
      .prepare("UPDATE rooms SET key_version = MAX(key_version, ?) WHERE id = ?")
      .bind(key_version, roomId),
  );
  await c.env.DB.batch(stmts);
  return c.json({ ok: true, stored: keys.length }, 200);
});

const getKeysRoute = createRoute({
  method: "get",
  path: "/rooms/{id}/keys",
  tags: ["rooms"],
  summary: "Fetch sealed envelopes addressed to the caller",
  description:
    "Returns all key_version envelopes the server has stored for the caller " +
    "in this room. The client unwraps each with its private key to retrieve " +
    "the per-version room keys, then decrypts historical ciphertext.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(z.object({ keys: z.array(SealedRoomKeySchema) }), "OK."),
    401: unauthorized,
    403: errorResponse("Not a member."),
    404: notFound,
  },
});

e2eRoutes.openapi(getKeysRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { results } = await c.env.DB
    .prepare(
      `SELECT room_id, member_user_id, key_version, sealed, created_at
       FROM room_keys WHERE room_id = ? AND member_user_id = ?
       ORDER BY key_version ASC`,
    )
    .bind(roomId, u.id)
    .all();
  return c.json({ keys: results } as never, 200);
});

// ---- F3 E2E mention tags ---------------------------------------------------

const publishMentionTagRoute = createRoute({
  method: "put",
  path: "/rooms/{id}/mention-tag",
  tags: ["rooms"],
  summary: "Publish the caller's opaque mention tag for an E2E room",
  description:
    "Each member publishes an opaque keyed token (HMAC over their user_id under " +
    "a key derived from the room key). When another member mentions them, the " +
    "client includes this token in the message's mention list; the server matches " +
    "the token here to route a push without learning the plaintext mention list.",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string() }),
    body: { required: true, content: { "application/json": { schema: mentionTagPublishBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Stored."),
    401: unauthorized,
    403: errorResponse("No access."),
  },
});

e2eRoutes.openapi(publishMentionTagRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { tag } = c.req.valid("json");
  const now = Date.now();
  await c.env.DB
    .prepare(
      `INSERT INTO room_mention_tags (room_id, user_id, tag, created_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(room_id, user_id)
       DO UPDATE SET tag = excluded.tag, created_at = excluded.created_at`,
    )
    .bind(roomId, u.id, tag, now)
    .run();
  return c.json({ ok: true }, 200);
});
