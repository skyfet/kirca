import { getUser, requireAuth } from "../lib/middleware";
import { notifyUser } from "../lib/notify";
import {
  createApp,
  createRoute,
  errorResponse,
  jsonContent,
  unauthorized,
  z,
} from "../lib/openapi";
import { blockCreateBody } from "../lib/schemas";

export const blockRoutes = createApp();

// ---- block a user --------------------------------------------------------

const createBlockRoute = createRoute({
  method: "post",
  path: "/blocks",
  tags: ["blocks"],
  summary: "Block a user",
  description:
    "Body: `{username}` or `{user_id}`. Idempotent. Blocking is enforced symmetrically on friend requests.",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: blockCreateBody } } },
  },
  responses: {
    200: jsonContent(
      z.object({ ok: z.boolean(), user_id: z.string() }),
      "Blocked (idempotent).",
    ),
    400: errorResponse("Cannot block yourself."),
    401: unauthorized,
    404: errorResponse("User not found."),
  },
});

blockRoutes.openapi(createBlockRoute, async (c) => {
  const u = getUser(c);
  const body = c.req.valid("json");
  let targetId = body.user_id ?? null;
  if (!targetId && body.username) {
    const row = await c.env.DB
      .prepare("SELECT id FROM users WHERE username = ?")
      .bind(body.username)
      .first<{ id: string }>();
    if (!row) return c.json({ error: "user not found" }, 404);
    targetId = row.id;
  } else if (targetId) {
    const row = await c.env.DB
      .prepare("SELECT id FROM users WHERE id = ?")
      .bind(targetId)
      .first<{ id: string }>();
    if (!row) return c.json({ error: "user not found" }, 404);
  }
  if (!targetId) return c.json({ error: "user not found" }, 404);
  if (targetId === u.id) return c.json({ error: "cannot block yourself" }, 400);

  await c.env.DB
    .prepare(
      "INSERT OR IGNORE INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)",
    )
    .bind(u.id, targetId, Date.now())
    .run();

  // Sync the blocker's own devices.
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, { type: "blocked", user_id: targetId }),
  );

  return c.json({ ok: true, user_id: targetId }, 200);
});

// ---- unblock a user (idempotent) -----------------------------------------

const deleteBlockRoute = createRoute({
  method: "delete",
  path: "/blocks/{userId}",
  tags: ["blocks"],
  summary: "Unblock a user",
  middleware: [requireAuth] as const,
  request: { params: z.object({ userId: z.string().min(1).max(64) }) },
  responses: {
    204: { description: "Unblocked (idempotent)." },
    401: unauthorized,
  },
});

blockRoutes.openapi(deleteBlockRoute, async (c) => {
  const u = getUser(c);
  const { userId } = c.req.valid("param");
  await c.env.DB
    .prepare("DELETE FROM blocks WHERE blocker_id = ? AND blocked_id = ?")
    .bind(u.id, userId)
    .run();
  c.executionCtx.waitUntil(
    notifyUser(c.env, u.id, { type: "unblocked", user_id: userId }),
  );
  return c.body(null, 204);
});

// ---- list my blocks ------------------------------------------------------

const listBlocksRoute = createRoute({
  method: "get",
  path: "/blocks",
  tags: ["blocks"],
  summary: "List users I have blocked",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(
      z.object({ blocks: z.array(z.record(z.unknown())) }),
      "Each entry includes user_id, username, display_name, avatar_url, created_at.",
    ),
    401: unauthorized,
  },
});

blockRoutes.openapi(listBlocksRoute, async (c) => {
  const u = getUser(c);
  const { results } = await c.env.DB
    .prepare(
      `SELECT b.blocked_id AS user_id, u.username, u.display_name, u.avatar_url, b.created_at
       FROM blocks b
       JOIN users u ON u.id = b.blocked_id
       WHERE b.blocker_id = ?
       ORDER BY b.created_at DESC`,
    )
    .bind(u.id)
    .all();
  return c.json({ blocks: results } as never, 200);
});
