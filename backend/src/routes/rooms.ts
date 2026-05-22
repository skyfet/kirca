import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";

import { getUser, isRoomAccessible, requireAuth, uuid } from "../lib/middleware";
import { createRoomBody, inviteCreateBody, muteBody } from "../lib/schemas";
import type { Env, Vars } from "../lib/types";

export const roomRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

// ---- list ----
roomRoutes.get("/rooms", requireAuth, async (c) => {
  const u = getUser(c);
  // К списку добавляем флаги membership и unread-счётчик для бейджа.
  const { results } = await c.env.DB
    .prepare(
      `SELECT
         r.id, r.name, r.is_public, r.created_by,
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
  return c.json({ rooms: results });
});

roomRoutes.post("/rooms", requireAuth, zValidator("json", createRoomBody), async (c) => {
  const u = getUser(c);
  const { name, is_public } = c.req.valid("json");
  const isPublic = is_public === false ? 0 : 1;
  const id = uuid();
  const now = Date.now();
  await c.env.DB
    .prepare(
      "INSERT INTO rooms (id, name, created_at, is_public, created_by) VALUES (?, ?, ?, ?, ?)",
    )
    .bind(id, name.trim(), now, isPublic, u.id)
    .run();
  await c.env.DB
    .prepare(
      "INSERT INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, ?, ?)",
    )
    .bind(u.id, id, "owner", now)
    .run();
  return c.json({ id, name: name.trim(), is_public: isPublic === 1 });
});

roomRoutes.post("/rooms/:id/join", requireAuth, async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  const room = await c.env.DB
    .prepare("SELECT is_public FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ is_public: number }>();
  if (!room) return c.json({ error: "not found" }, 404);
  if (room.is_public !== 1) return c.json({ error: "forbidden" }, 403);
  await c.env.DB
    .prepare(
      "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)",
    )
    .bind(u.id, roomId, Date.now())
    .run();
  return c.json({ ok: true });
});

roomRoutes.post("/rooms/:id/leave", requireAuth, async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  // owner не уходит просто так — пока упрощённо запрещаем, чтобы комната не осталась без хозяина.
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
  return new Response(null, { status: 204 });
});

// ---- members + presence ----
// Online считается через DO: GET туда, он отвечает списком user_id. Без DO — все offline.
roomRoutes.get("/rooms/:id/members", requireAuth, async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
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

  // Спрашиваем у DO, кто из них онлайн.
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
  return c.json({ members });
});

// ---- per-membership mute ----
roomRoutes.patch("/rooms/:id/membership", requireAuth, zValidator("json", muteBody), async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
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
  return c.json({ muted });
});

// ---- invites ----
// Создаёт invite в приватную комнату (member или owner может пригласить).
roomRoutes.post("/rooms/:id/invites", requireAuth, zValidator("json", inviteCreateBody), async (c) => {
  const u = getUser(c);
  const roomId = c.req.param("id");
  const room = await c.env.DB
    .prepare("SELECT is_public FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ is_public: number }>();
  if (!room) return c.json({ error: "not found" }, 404);
  // Приглашать в публичную не нужно.
  if (room.is_public === 1) return c.json({ error: "room is public" }, 409);

  const isMember = await c.env.DB
    .prepare("SELECT 1 AS x FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(u.id, roomId)
    .first<{ x: number }>();
  if (!isMember) return c.json({ error: "forbidden" }, 403);

  const body = c.req.valid("json");
  // Найти invitee по username, если он не передан как user_id.
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

  // Уже участник?
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
  } catch (e) {
    // Уникальный индекс по (room_id, invitee_user_id) WHERE status='pending'.
    return c.json({ error: "already invited" }, 409);
  }
  return c.json({ id, room_id: roomId, invitee_user_id: inviteeId, status: "pending", created_at: now });
});

// Свои входящие приглашения.
roomRoutes.get("/invites", requireAuth, async (c) => {
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
  return c.json({ invites: results });
});

roomRoutes.post("/invites/:id/accept", requireAuth, async (c) => {
  const u = getUser(c);
  const id = c.req.param("id");
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
  return c.json({ ok: true, room_id: inv.room_id });
});

roomRoutes.post("/invites/:id/decline", requireAuth, async (c) => {
  const u = getUser(c);
  const id = c.req.param("id");
  const now = Date.now();
  const res = await c.env.DB
    .prepare("UPDATE invites SET status = 'declined', responded_at = ? WHERE id = ? AND invitee_user_id = ? AND status = 'pending'")
    .bind(now, id, u.id)
    .run();
  if ((res.meta.changes ?? 0) === 0) return c.json({ error: "not found" }, 404);
  return c.json({ ok: true });
});

// Inviter может отозвать своё приглашение.
roomRoutes.delete("/invites/:id", requireAuth, async (c) => {
  const u = getUser(c);
  const id = c.req.param("id");
  const now = Date.now();
  const res = await c.env.DB
    .prepare("UPDATE invites SET status = 'revoked', responded_at = ? WHERE id = ? AND inviter_user_id = ? AND status = 'pending'")
    .bind(now, id, u.id)
    .run();
  if ((res.meta.changes ?? 0) === 0) return c.json({ error: "not found" }, 404);
  return new Response(null, { status: 204 });
});
