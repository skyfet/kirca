import { getUser, requireAuth, uuid } from "../lib/middleware";
import { notifyUser } from "../lib/notify";
import { notifyDevices } from "../lib/apns";
import type { Env } from "../lib/types";
import {
  createApp,
  createRoute,
  errorResponse,
  jsonContent,
  notFound,
  unauthorized,
  z,
} from "../lib/openapi";
import { friendRequestCreateBody } from "../lib/schemas";

export const friendRoutes = createApp();

// Сортировка пары так, что user_a < user_b — даёт уникальность friendship
// независимо от направления запроса и упрощает выборку друзей одного юзера.
function pairKey(a: string, b: string): { ua: string; ub: string } {
  return a < b ? { ua: a, ub: b } : { ua: b, ub: a };
}

// dm_key = "minUserId:maxUserId" (lexicographic), giving an idempotent key for
// the 1:1 room independent of who accepts.
function dmKeyFor(a: string, b: string): string {
  const { ua, ub } = pairKey(a, b);
  return `${ua}:${ub}`;
}

// Provision the DM room for a freshly-formed friendship, idempotently.
// `creator` is whichever side triggered the friendship (used as created_by on a
// new room). The DB writes are awaited (so callers must await this before
// returning), while the `room_added` fan-out — one per user, each carrying the
// peer's id — is deferred via executionCtx.waitUntil. Does NOT seal room keys;
// the client does that via POST /rooms/{id}/keys.
async function provisionDmRoom(
  c: { env: Env; executionCtx: ExecutionContext },
  userA: string,
  userB: string,
  creator: string,
): Promise<void> {
  const dmKey = dmKeyFor(userA, userB);
  const now = Date.now();

  let roomId: string;
  const existing = await c.env.DB
    .prepare("SELECT id FROM rooms WHERE dm_key = ?")
    .bind(dmKey)
    .first<{ id: string }>();

  if (existing) {
    roomId = existing.id;
    // Ensure both memberships exist (the room could pre-exist with one side gone).
    await c.env.DB.batch([
      c.env.DB
        .prepare(
          "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
        )
        .bind(userA, roomId, now),
      c.env.DB
        .prepare(
          "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
        )
        .bind(userB, roomId, now),
    ]);
  } else {
    roomId = uuid();
    await c.env.DB.batch([
      c.env.DB
        .prepare(
          "INSERT INTO rooms (id, name, created_at, is_public, created_by, e2e, key_version, kind, dm_key) VALUES (?, '', ?, 0, ?, 1, 1, 'dm', ?)",
        )
        .bind(roomId, now, creator, dmKey),
      c.env.DB
        .prepare(
          "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
        )
        .bind(userA, roomId, now),
      c.env.DB
        .prepare(
          "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
        )
        .bind(userB, roomId, now),
    ]);
  }

  const baseRoom = {
    id: roomId,
    name: "",
    is_public: false,
    is_member: true,
    role: "member",
    muted: false,
    unread: 0,
    e2e: true,
    key_version: 1,
    kind: "dm",
  };
  c.executionCtx.waitUntil(
    Promise.all([
      notifyUser(c.env, userA, {
        type: "room_added",
        room: { ...baseRoom, dm_peer_id: userB },
      }),
      notifyUser(c.env, userB, {
        type: "room_added",
        room: { ...baseRoom, dm_peer_id: userA },
      }),
    ]),
  );
}

// ---- list my friends -----------------------------------------------------

const listFriendsRoute = createRoute({
  method: "get",
  path: "/friends",
  tags: ["friends"],
  summary: "List confirmed friends",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(
      z.object({ friends: z.array(z.record(z.unknown())) }),
      "Each entry includes the friend's user_id, username, display_name, avatar_url, since.",
    ),
    401: unauthorized,
  },
});

friendRoutes.openapi(listFriendsRoute, async (c) => {
  const u = getUser(c);
  const { results } = await c.env.DB
    .prepare(
      `SELECT
         CASE WHEN f.user_a = ? THEN f.user_b ELSE f.user_a END AS user_id,
         u.username, u.display_name, u.avatar_url,
         f.created_at AS since
       FROM friendships f
       JOIN users u ON u.id = CASE WHEN f.user_a = ? THEN f.user_b ELSE f.user_a END
       WHERE f.user_a = ? OR f.user_b = ?
       ORDER BY u.username ASC`,
    )
    .bind(u.id, u.id, u.id, u.id)
    .all();
  return c.json({ friends: results } as never, 200);
});

// ---- remove a friend (idempotent) ----------------------------------------

const removeFriendRoute = createRoute({
  method: "delete",
  path: "/friends/{userId}",
  tags: ["friends"],
  summary: "Remove a friend",
  middleware: [requireAuth] as const,
  request: { params: z.object({ userId: z.string().min(1).max(64) }) },
  responses: {
    204: { description: "Removed (idempotent)." },
    401: unauthorized,
  },
});

friendRoutes.openapi(removeFriendRoute, async (c) => {
  const u = getUser(c);
  const { userId: other } = c.req.valid("param");
  const { ua, ub } = pairKey(u.id, other);
  await c.env.DB
    .prepare("DELETE FROM friendships WHERE user_a = ? AND user_b = ?")
    .bind(ua, ub)
    .run();
  // Notify both sides so their lists stay in sync across devices.
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, { type: "friend_removed", user_id: other }),
  );
  c.executionCtx.waitUntil(
    notifyUser(c.env, other, { type: "friend_removed", user_id: u.id }),
  );
  return c.body(null, 204);
});

// ---- send a friend request ----------------------------------------------

const createFriendRequestRoute = createRoute({
  method: "post",
  path: "/friend-requests",
  tags: ["friends"],
  summary: "Send a friend request",
  description:
    "Body: `{username}` or `{user_id}`. If the target has already sent us a pending request the two collapse into an immediate friendship.",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: friendRequestCreateBody } } },
  },
  responses: {
    200: jsonContent(z.record(z.unknown()), "Request created or auto-accepted into a friendship."),
    400: errorResponse("Self-request."),
    401: unauthorized,
    403: errorResponse("Blocked in either direction."),
    404: errorResponse("User not found."),
    409: errorResponse("Already friends or request already pending."),
  },
});

friendRoutes.openapi(createFriendRequestRoute, async (c) => {
  const u = getUser(c);
  const body = c.req.valid("json");
  let targetId = body.user_id ?? null;
  let targetUsername: string | null = null;
  if (!targetId && body.username) {
    const row = await c.env.DB
      .prepare("SELECT id, username FROM users WHERE username = ?")
      .bind(body.username)
      .first<{ id: string; username: string }>();
    if (!row) return c.json({ error: "user not found" }, 404);
    targetId = row.id;
    targetUsername = row.username;
  } else if (targetId) {
    const row = await c.env.DB
      .prepare("SELECT username FROM users WHERE id = ?")
      .bind(targetId)
      .first<{ username: string }>();
    if (!row) return c.json({ error: "user not found" }, 404);
    targetUsername = row.username;
  }
  if (!targetId) return c.json({ error: "user not found" }, 404);
  if (targetId === u.id) return c.json({ error: "cannot friend yourself" }, 400);

  // Blocked in either direction? Refuse before creating/auto-accepting anything.
  const blocked = await c.env.DB
    .prepare(
      "SELECT 1 AS x FROM blocks WHERE (blocker_id = ? AND blocked_id = ?) OR (blocker_id = ? AND blocked_id = ?)",
    )
    .bind(u.id, targetId, targetId, u.id)
    .first<{ x: number }>();
  if (blocked) return c.json({ error: "blocked" }, 403);

  // Already friends?
  const { ua, ub } = pairKey(u.id, targetId);
  const existing = await c.env.DB
    .prepare("SELECT 1 AS x FROM friendships WHERE user_a = ? AND user_b = ?")
    .bind(ua, ub)
    .first<{ x: number }>();
  if (existing) return c.json({ error: "already friends" }, 409);

  // Reverse pending? Auto-accept into a friendship.
  const reverse = await c.env.DB
    .prepare(
      "SELECT id FROM friend_requests WHERE from_user_id = ? AND to_user_id = ? AND status = 'pending'",
    )
    .bind(targetId, u.id)
    .first<{ id: string }>();
  if (reverse) {
    const now = Date.now();
    await c.env.DB.batch([
      c.env.DB
        .prepare("UPDATE friend_requests SET status = 'accepted', responded_at = ? WHERE id = ?")
        .bind(now, reverse.id),
      c.env.DB
        .prepare(
          "INSERT OR IGNORE INTO friendships (user_a, user_b, created_at) VALUES (?, ?, ?)",
        )
        .bind(ua, ub, now),
    ]);
    c.executionCtx.waitUntil(
      notifyUser(c.env, u.id, {
        type: "friend_added",
        user_id: targetId,
        username: targetUsername ?? "",
      }),
    );
    c.executionCtx.waitUntil(
      notifyUser(c.env, targetId, {
        type: "friend_added",
        user_id: u.id,
        username: u.username,
      }),
    );
    // Friendship => provision the E2E DM room (idempotent).
    await provisionDmRoom(c, u.id, targetId, u.id);
    return c.json(
      { ok: true, friendship: true, user_id: targetId, username: targetUsername } as never,
      200,
    );
  }

  const id = uuid();
  const now = Date.now();
  try {
    await c.env.DB
      .prepare(
        "INSERT INTO friend_requests (id, from_user_id, to_user_id, status, created_at) VALUES (?, ?, ?, 'pending', ?)",
      )
      .bind(id, u.id, targetId, now)
      .run();
  } catch {
    return c.json({ error: "already pending" }, 409);
  }

  // Push notify the recipient if they're offline.
  c.executionCtx.waitUntil(
    notifyUser(c.env, targetId, {
      type: "friend_request_received",
      request: {
        id,
        from_user_id: u.id,
        from_username: u.username,
        created_at: now,
      },
    }),
  );
  c.executionCtx.waitUntil(
    notifyDevices(c.env.DB, c.env, [targetId], {
      alert: {
        title: "Запрос в друзья",
        body: `@${u.username} хочет добавить вас в друзья`,
      },
      sound: "default",
      "thread-id": `friend:${u.id}`,
    }),
  );

  return c.json(
    {
      ok: true,
      id,
      from_user_id: u.id,
      to_user_id: targetId,
      status: "pending",
      created_at: now,
    } as never,
    200,
  );
});

// ---- list pending requests addressed to me ------------------------------

const listFriendRequestsRoute = createRoute({
  method: "get",
  path: "/friend-requests",
  tags: ["friends"],
  summary: "List pending incoming friend requests",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(
      z.object({ requests: z.array(z.record(z.unknown())) }),
      "Each entry includes id, from_user_id, from_username, from_display_name, created_at.",
    ),
    401: unauthorized,
  },
});

friendRoutes.openapi(listFriendRequestsRoute, async (c) => {
  const u = getUser(c);
  const { results } = await c.env.DB
    .prepare(
      `SELECT
         fr.id, fr.from_user_id, fr.created_at,
         u.username AS from_username, u.display_name AS from_display_name, u.avatar_url AS from_avatar_url
       FROM friend_requests fr
       JOIN users u ON u.id = fr.from_user_id
       WHERE fr.to_user_id = ? AND fr.status = 'pending'
       ORDER BY fr.created_at DESC`,
    )
    .bind(u.id)
    .all();
  return c.json({ requests: results } as never, 200);
});

// ---- accept ---------------------------------------------------------------

const acceptFriendRequestRoute = createRoute({
  method: "post",
  path: "/friend-requests/{id}/accept",
  tags: ["friends"],
  summary: "Accept a pending friend request",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string().min(1).max(64) }) },
  responses: {
    200: jsonContent(z.record(z.unknown()), "Accepted; a friendship row now exists."),
    401: unauthorized,
    404: notFound,
    409: errorResponse("Already responded."),
  },
});

friendRoutes.openapi(acceptFriendRequestRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const fr = await c.env.DB
    .prepare(
      "SELECT id, from_user_id, to_user_id, status FROM friend_requests WHERE id = ?",
    )
    .bind(id)
    .first<{ id: string; from_user_id: string; to_user_id: string; status: string }>();
  if (!fr || fr.to_user_id !== u.id) return c.json({ error: "not found" }, 404);
  if (fr.status !== "pending") return c.json({ error: "already responded" }, 409);
  const now = Date.now();
  const { ua, ub } = pairKey(fr.from_user_id, fr.to_user_id);
  await c.env.DB.batch([
    c.env.DB
      .prepare("UPDATE friend_requests SET status = 'accepted', responded_at = ? WHERE id = ?")
      .bind(now, id),
    c.env.DB
      .prepare(
        "INSERT OR IGNORE INTO friendships (user_a, user_b, created_at) VALUES (?, ?, ?)",
      )
      .bind(ua, ub, now),
  ]);

  // Tell both sides — multi-device sync.
  const otherUser = await c.env.DB
    .prepare("SELECT username FROM users WHERE id = ?")
    .bind(fr.from_user_id)
    .first<{ username: string }>();
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, {
      type: "friend_added",
      user_id: fr.from_user_id,
      username: otherUser?.username ?? "",
    }),
  );
  c.executionCtx.waitUntil(
    notifyUser(c.env, fr.from_user_id, {
      type: "friend_added",
      user_id: u.id,
      username: u.username,
    }),
  );
  // Friendship => provision the E2E DM room (idempotent). The accepter (u) is
  // the room creator.
  await provisionDmRoom(c, u.id, fr.from_user_id, u.id);
  return c.json({ ok: true, friend_id: fr.from_user_id } as never, 200);
});

// ---- decline --------------------------------------------------------------

const declineFriendRequestRoute = createRoute({
  method: "post",
  path: "/friend-requests/{id}/decline",
  tags: ["friends"],
  summary: "Decline a pending friend request",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string().min(1).max(64) }) },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Declined."),
    401: unauthorized,
    404: notFound,
  },
});

friendRoutes.openapi(declineFriendRequestRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const now = Date.now();
  const res = await c.env.DB
    .prepare(
      "UPDATE friend_requests SET status = 'declined', responded_at = ? WHERE id = ? AND to_user_id = ? AND status = 'pending'",
    )
    .bind(now, id, u.id)
    .run();
  if ((res.meta.changes ?? 0) === 0) return c.json({ error: "not found" }, 404);
  return c.json({ ok: true }, 200);
});

// ---- cancel (outgoing) ----------------------------------------------------

const cancelFriendRequestRoute = createRoute({
  method: "delete",
  path: "/friend-requests/{id}",
  tags: ["friends"],
  summary: "Cancel an outgoing friend request",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string().min(1).max(64) }) },
  responses: {
    204: { description: "Cancelled." },
    401: unauthorized,
    404: notFound,
  },
});

friendRoutes.openapi(cancelFriendRequestRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const res = await c.env.DB
    .prepare(
      "DELETE FROM friend_requests WHERE id = ? AND from_user_id = ? AND status = 'pending'",
    )
    .bind(id, u.id)
    .run();
  if ((res.meta.changes ?? 0) === 0) return c.json({ error: "not found" }, 404);
  return c.body(null, 204);
});
