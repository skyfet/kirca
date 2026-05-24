import { getUser, isRoomAccessible, requireAuth, uuid } from "../lib/middleware";
import { notifyUser } from "../lib/notify";
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
import { createRoomBody, inviteCreateBody, muteBody } from "../lib/schemas";

export const roomRoutes = createApp();

const RoomSchema = z
  .object({
    id: z.string().uuid(),
    name: z.string(),
    is_public: z
      .union([z.number().int(), z.boolean()])
      .describe("1/true if anyone can join via POST /rooms/{id}/join."),
    e2e: z
      .union([z.number().int(), z.boolean()])
      .optional()
      .describe("1/true if message bodies are stored as opaque ciphertext."),
    key_version: z.number().int().optional(),
  })
  .openapi("Room");

// ---- list ----
const listRoomsRoute = createRoute({
  method: "get",
  path: "/rooms",
  tags: ["rooms"],
  summary: "List visible rooms",
  description: "Returns all public rooms plus private rooms where the user is a member.",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(z.object({ rooms: z.array(RoomSchema) }), "OK."),
    401: unauthorized,
  },
});

roomRoutes.openapi(listRoomsRoute, async (c) => {
  const u = getUser(c);
  const { results } = await c.env.DB
    .prepare(
      `SELECT
         r.id, r.name, r.is_public, r.created_by, r.e2e, r.key_version,
         (m.user_id IS NOT NULL) AS is_member,
         COALESCE(m.muted, 0) AS muted,
         COALESCE(m.role, '') AS role,
         COALESCE(
           (SELECT COUNT(*) FROM messages msg
             WHERE msg.room_id = r.id
               AND msg.deleted_at IS NULL
               AND msg.user_id <> ?
               AND msg.created_at > COALESCE((SELECT last_read_at FROM read_state WHERE user_id = ? AND room_id = r.id), 0)),
           0
         ) AS unread
       FROM rooms r
       LEFT JOIN memberships m ON m.room_id = r.id AND m.user_id = ?
       WHERE r.is_public = 1 OR m.user_id IS NOT NULL
       ORDER BY r.created_at DESC`,
    )
    .bind(u.id, u.id, u.id)
    .all();
  return c.json({ rooms: results } as never, 200);
});

const createRoomRoute = createRoute({
  method: "post",
  path: "/rooms",
  tags: ["rooms"],
  summary: "Create a room",
  description:
    "Caller becomes the owner. Public by default — set `is_public: false` for a private room.",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: createRoomBody } } },
  },
  responses: {
    200: jsonContent(RoomSchema, "Created."),
    400: errorResponse("Missing name."),
    401: unauthorized,
  },
});

roomRoutes.openapi(createRoomRoute, async (c) => {
  const u = getUser(c);
  const { name, is_public, e2e } = c.req.valid("json");
  // E2E rooms are private by construction — there's no plaintext history for
  // a public stranger to bootstrap into, so we silently flip is_public off
  // when e2e is requested.
  const wantE2e = e2e === true ? 1 : 0;
  const isPublic = wantE2e === 1 ? 0 : (is_public === false ? 0 : 1);
  const id = uuid();
  const now = Date.now();
  await c.env.DB
    .prepare(
      "INSERT INTO rooms (id, name, created_at, is_public, created_by, e2e, key_version) VALUES (?, ?, ?, ?, ?, ?, ?)",
    )
    .bind(id, name.trim(), now, isPublic, u.id, wantE2e, wantE2e === 1 ? 1 : 0)
    .run();
  await c.env.DB
    .prepare(
      "INSERT INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, ?, ?)",
    )
    .bind(u.id, id, "owner", now)
    .run();
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, {
      type: "room_added",
      room: {
        id,
        name: name.trim(),
        is_public: isPublic === 1,
        is_member: true,
        role: "owner",
        muted: false,
        unread: 0,
        e2e: wantE2e === 1,
        key_version: wantE2e === 1 ? 1 : 0,
      },
    }),
  );
  return c.json(
    { id, name: name.trim(), is_public: isPublic === 1, e2e: wantE2e === 1, key_version: wantE2e === 1 ? 1 : 0 },
    200,
  );
});

const joinRoomRoute = createRoute({
  method: "post",
  path: "/rooms/{id}/join",
  tags: ["rooms"],
  summary: "Join a public room",
  description: "Only works for public rooms. For private rooms the owner must add you out-of-band.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string().uuid() }) },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Joined (idempotent)."),
    401: unauthorized,
    403: errorResponse("Room is private."),
    404: errorResponse("Room not found."),
  },
});

roomRoutes.openapi(joinRoomRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  const room = await c.env.DB
    .prepare("SELECT id, name, is_public FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ id: string; name: string; is_public: number }>();
  if (!room) return c.json({ error: "not found" }, 404);
  if (room.is_public !== 1) return c.json({ error: "forbidden" }, 403);
  const res = await c.env.DB
    .prepare(
      "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
    )
    .bind(u.id, roomId, Date.now())
    .run();
  if ((res.meta.changes ?? 0) > 0) {
    c.executionCtx.waitUntil(
      notifyUser(c.env, u.id, {
        type: "room_added",
        room: {
          id: room.id,
          name: room.name,
          is_public: room.is_public === 1,
          is_member: true,
          role: "member",
          muted: false,
          unread: 0,
        },
      }),
    );
  }
  return c.json({ ok: true }, 200);
});

const leaveRoomRoute = createRoute({
  method: "post",
  path: "/rooms/{id}/leave",
  tags: ["rooms"],
  summary: "Leave a room (non-owner)",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    204: { description: "Left." },
    401: unauthorized,
    404: errorResponse("Not a member."),
    409: errorResponse("Owner cannot leave."),
  },
});

roomRoutes.openapi(leaveRoomRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  const m = await c.env.DB
    .prepare("SELECT role FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(u.id, roomId)
    .first<{ role: string }>();
  if (!m) return c.json({ error: "not a member" }, 404);
  if (m.role === "owner") return c.json({ error: "owner cannot leave" }, 409);
  await c.env.DB
    .prepare("DELETE FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(u.id, roomId)
    .run();
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, { type: "room_removed", room_id: roomId }),
  );
  return c.body(null, 204);
});

// ---- members + presence ----
const membersRoute = createRoute({
  method: "get",
  path: "/rooms/{id}/members",
  tags: ["rooms"],
  summary: "List members and online state",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(
      z.object({ members: z.array(z.record(z.unknown())) }),
      "Members with role, joined_at, online flag.",
    ),
    401: unauthorized,
    403: errorResponse("No access."),
  },
});

roomRoutes.openapi(membersRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }
  const { results } = await c.env.DB
    .prepare(
      `SELECT u.id, u.username, u.display_name, u.avatar_url, m.role, m.joined_at
       FROM memberships m JOIN users u ON u.id = m.user_id
       WHERE m.room_id = ?
       ORDER BY m.joined_at ASC`,
    )
    .bind(roomId)
    .all();

  let online: Set<string> = new Set();
  try {
    const stub = c.env.ROOM.get(c.env.ROOM.idFromName(roomId));
    const r = await stub.fetch("https://room.internal/online");
    if (r.ok) {
      const b = await r.json<{ users: string[] }>();
      online = new Set(b.users);
    }
  } catch { /* DO ещё не поднимался — все offline */ }

  const members = (results as Array<Record<string, unknown>>).map((m) => ({
    ...m,
    online: online.has(m.id as string),
  }));
  return c.json({ members } as never, 200);
});

// ---- per-membership mute ----
const muteRoute = createRoute({
  method: "patch",
  path: "/rooms/{id}/membership",
  tags: ["rooms"],
  summary: "Mute / unmute room for the current user",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string() }),
    body: { required: true, content: { "application/json": { schema: muteBody } } },
  },
  responses: {
    200: jsonContent(z.object({ muted: z.boolean() }), "OK."),
    401: unauthorized,
    404: errorResponse("Not a member."),
  },
});

roomRoutes.openapi(muteRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  const { muted } = c.req.valid("json");
  const m = await c.env.DB
    .prepare("SELECT 1 AS x FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(u.id, roomId)
    .first<{ x: number }>();
  if (!m) return c.json({ error: "not a member" }, 404);
  await c.env.DB
    .prepare("UPDATE memberships SET muted = ? WHERE user_id = ? AND room_id = ?")
    .bind(muted ? 1 : 0, u.id, roomId)
    .run();
  return c.json({ muted }, 200);
});

// ---- invites ----
const createInviteRoute = createRoute({
  method: "post",
  path: "/rooms/{id}/invites",
  tags: ["rooms"],
  summary: "Invite a user to a private room",
  description: "Inviter must be a member. Body: `{username}` or `{user_id}`.",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ id: z.string() }),
    body: { required: true, content: { "application/json": { schema: inviteCreateBody } } },
  },
  responses: {
    200: jsonContent(z.record(z.unknown()), "Invite created."),
    400: errorResponse("Self-invite."),
    401: unauthorized,
    403: errorResponse("Not a member."),
    404: errorResponse("Room or user not found."),
    409: errorResponse("Public room / already member / already invited."),
  },
});

roomRoutes.openapi(createInviteRoute, async (c) => {
  const u = getUser(c);
  const { id: roomId } = c.req.valid("param");
  const room = await c.env.DB
    .prepare("SELECT is_public FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ is_public: number }>();
  if (!room) return c.json({ error: "not found" }, 404);
  if (room.is_public === 1) return c.json({ error: "room is public" }, 409);

  const isMember = await c.env.DB
    .prepare("SELECT 1 AS x FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(u.id, roomId)
    .first<{ x: number }>();
  if (!isMember) return c.json({ error: "forbidden" }, 403);

  const body = c.req.valid("json");
  let inviteeId = body.user_id ?? null;
  if (!inviteeId && body.username) {
    const row = await c.env.DB
      .prepare("SELECT id FROM users WHERE username = ?")
      .bind(body.username)
      .first<{ id: string }>();
    if (!row) return c.json({ error: "user not found" }, 404);
    inviteeId = row.id;
  }
  if (!inviteeId) return c.json({ error: "user not found" }, 404);
  if (inviteeId === u.id) return c.json({ error: "cannot invite yourself" }, 400);

  const already = await c.env.DB
    .prepare("SELECT 1 AS x FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(inviteeId, roomId)
    .first<{ x: number }>();
  if (already) return c.json({ error: "already a member" }, 409);

  const id = uuid();
  const now = Date.now();
  try {
    await c.env.DB
      .prepare(
        `INSERT INTO invites (id, room_id, inviter_user_id, invitee_user_id, status, created_at)
         VALUES (?, ?, ?, ?, 'pending', ?)`,
      )
      .bind(id, roomId, u.id, inviteeId, now)
      .run();
  } catch {
    return c.json({ error: "already invited" }, 409);
  }
  // Уведомим приглашённого.
  const roomRow = await c.env.DB
    .prepare("SELECT name FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ name: string }>();
  const inviterRow = await c.env.DB
    .prepare("SELECT username, display_name FROM users WHERE id = ?")
    .bind(u.id)
    .first<{ username: string; display_name: string | null }>();
  c.executionCtx.waitUntil(
    notifyUser(c.env, inviteeId, {
      type: "invite_received",
      invite: {
        id,
        room_id: roomId,
        room_name: roomRow?.name ?? "",
        inviter_id: u.id,
        inviter_username: inviterRow?.username ?? "",
        inviter_display_name: inviterRow?.display_name ?? null,
        created_at: now,
      },
    }),
  );
  return c.json(
    { id, room_id: roomId, invitee_user_id: inviteeId, status: "pending", created_at: now } as never,
    200,
  );
});

const listInvitesRoute = createRoute({
  method: "get",
  path: "/invites",
  tags: ["rooms"],
  summary: "List pending invites for the current user",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(
      z.object({ invites: z.array(z.record(z.unknown())) }),
      "List of invites with room and inviter info.",
    ),
    401: unauthorized,
  },
});

roomRoutes.openapi(listInvitesRoute, async (c) => {
  const u = getUser(c);
  const { results } = await c.env.DB
    .prepare(
      `SELECT
         i.id, i.room_id, i.status, i.created_at,
         r.name AS room_name, r.is_public AS room_is_public,
         u.id AS inviter_id, u.username AS inviter_username, u.display_name AS inviter_display_name
       FROM invites i
       JOIN rooms r ON r.id = i.room_id
       JOIN users u ON u.id = i.inviter_user_id
       WHERE i.invitee_user_id = ? AND i.status = 'pending'
       ORDER BY i.created_at DESC`,
    )
    .bind(u.id)
    .all();
  return c.json({ invites: results } as never, 200);
});

const acceptInviteRoute = createRoute({
  method: "post",
  path: "/invites/{id}/accept",
  tags: ["rooms"],
  summary: "Accept a pending invite",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(z.record(z.unknown()), "Joined."),
    401: unauthorized,
    404: notFound,
    409: errorResponse("Already responded."),
  },
});

roomRoutes.openapi(acceptInviteRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const inv = await c.env.DB
    .prepare("SELECT id, room_id, invitee_user_id, status FROM invites WHERE id = ?")
    .bind(id)
    .first<{ id: string; room_id: string; invitee_user_id: string; status: string }>();
  if (!inv || inv.invitee_user_id !== u.id) return c.json({ error: "not found" }, 404);
  if (inv.status !== "pending") return c.json({ error: "already responded" }, 409);
  const now = Date.now();
  await c.env.DB
    .prepare(
      "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
    )
    .bind(u.id, inv.room_id, now)
    .run();
  await c.env.DB
    .prepare("UPDATE invites SET status = 'accepted', responded_at = ? WHERE id = ?")
    .bind(now, id)
    .run();
  const room = await c.env.DB
    .prepare("SELECT id, name, is_public FROM rooms WHERE id = ?")
    .bind(inv.room_id)
    .first<{ id: string; name: string; is_public: number }>();
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, {
      type: "room_added",
      room: room
        ? {
            id: room.id,
            name: room.name,
            is_public: room.is_public === 1,
            is_member: true,
            role: "member",
            muted: false,
            unread: 0,
          }
        : { id: inv.room_id, name: "", is_public: false, is_member: true, role: "member", muted: false, unread: 0 },
    }),
  );
  return c.json({ ok: true, room_id: inv.room_id } as never, 200);
});

const declineInviteRoute = createRoute({
  method: "post",
  path: "/invites/{id}/decline",
  tags: ["rooms"],
  summary: "Decline a pending invite",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Declined."),
    401: unauthorized,
    404: notFound,
  },
});

roomRoutes.openapi(declineInviteRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const now = Date.now();
  const res = await c.env.DB
    .prepare(
      "UPDATE invites SET status = 'declined', responded_at = ? WHERE id = ? AND invitee_user_id = ? AND status = 'pending'",
    )
    .bind(now, id, u.id)
    .run();
  if ((res.meta.changes ?? 0) === 0) return c.json({ error: "not found" }, 404);
  return c.json({ ok: true }, 200);
});

const revokeInviteRoute = createRoute({
  method: "delete",
  path: "/invites/{id}",
  tags: ["rooms"],
  summary: "Revoke an invite you created",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    204: { description: "Revoked." },
    401: unauthorized,
    404: notFound,
  },
});

roomRoutes.openapi(revokeInviteRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const now = Date.now();
  // Сначала достанем invitee, чтобы уведомить его об отзыве.
  const inv = await c.env.DB
    .prepare(
      "SELECT invitee_user_id FROM invites WHERE id = ? AND inviter_user_id = ? AND status = 'pending'",
    )
    .bind(id, u.id)
    .first<{ invitee_user_id: string }>();
  const res = await c.env.DB
    .prepare(
      "UPDATE invites SET status = 'revoked', responded_at = ? WHERE id = ? AND inviter_user_id = ? AND status = 'pending'",
    )
    .bind(now, id, u.id)
    .run();
  if ((res.meta.changes ?? 0) === 0) return c.json({ error: "not found" }, 404);
  if (inv?.invitee_user_id) {
    c.executionCtx.waitUntil(
      notifyUser(c.env, inv.invitee_user_id, { type: "invite_revoked", id }),
    );
  }
  return c.body(null, 204);
});
