import { Hono } from "hono";
import { cors } from "hono/cors";
import { hashPassword, verifyPassword, SESSION_TTL_MS } from "./lib/auth";

export { Room } from "./room";

type Env = {
  DB: D1Database;
  ROOM: DurableObjectNamespace;
};

const app = new Hono<{ Bindings: Env }>();
app.use("*", cors());

// ---------- helpers ----------
const uuid = () => crypto.randomUUID();

type UserRow = { id: string; username: string };

async function authUser(env: Env, token: string | undefined | null): Promise<UserRow | null> {
  if (!token) return null;
  const now = Date.now();
  const s = await env.DB
    .prepare(
      "SELECT user_id FROM sessions WHERE token = ? AND (expires_at IS NULL OR expires_at > ?)"
    )
    .bind(token, now)
    .first<{ user_id: string }>();
  if (!s) return null;
  return env.DB
    .prepare("SELECT id, username FROM users WHERE id = ?")
    .bind(s.user_id)
    .first<UserRow>();
}

const bearer = (h: string | undefined) => h?.replace(/^Bearer\s+/i, "");

async function isRoomAccessible(env: Env, roomId: string, userId: string): Promise<boolean> {
  const room = await env.DB
    .prepare("SELECT is_public FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ is_public: number }>();
  if (!room) return false;
  if (room.is_public === 1) return true;
  const m = await env.DB
    .prepare("SELECT 1 AS x FROM memberships WHERE user_id = ? AND room_id = ?")
    .bind(userId, roomId)
    .first<{ x: number }>();
  return !!m;
}

async function createSession(env: Env, userId: string): Promise<{ token: string; expiresAt: number }> {
  const token = uuid();
  const now = Date.now();
  const expiresAt = now + SESSION_TTL_MS;
  await env.DB
    .prepare("INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(token, userId, now, expiresAt)
    .run();
  return { token, expiresAt };
}

// ---------- auth ----------
app.post("/register", async (c) => {
  const { username, password } = await c.req.json<{ username: string; password: string }>();
  if (!username || !password) return c.json({ error: "username and password required" }, 400);
  if (password.length < 6) return c.json({ error: "password too short" }, 400);

  const exists = await c.env.DB.prepare("SELECT id FROM users WHERE username = ?").bind(username).first();
  if (exists) return c.json({ error: "username taken" }, 409);

  const id = uuid();
  const hash = hashPassword(password);
  const now = Date.now();
  await c.env.DB
    .prepare("INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
    .bind(id, username, hash, now).run();

  const { token } = await createSession(c.env, id);
  return c.json({ token, user: { id, username } });
});

app.post("/login", async (c) => {
  const { username, password } = await c.req.json<{ username: string; password: string }>();
  if (!username || !password) return c.json({ error: "username and password required" }, 400);

  const row = await c.env.DB
    .prepare("SELECT id, username, password_hash FROM users WHERE username = ?")
    .bind(username)
    .first<{ id: string; username: string; password_hash: string }>();
  if (!row) return c.json({ error: "invalid credentials" }, 401);

  const v = await verifyPassword(password, row.password_hash);
  if (!v.ok) return c.json({ error: "invalid credentials" }, 401);

  // Прозрачно перехешируем легаси-пароли в scrypt.
  if (v.needsRehash) {
    const newHash = hashPassword(password);
    await c.env.DB
      .prepare("UPDATE users SET password_hash = ? WHERE id = ?")
      .bind(newHash, row.id)
      .run();
  }

  const { token } = await createSession(c.env, row.id);
  return c.json({ token, user: { id: row.id, username: row.username } });
});

// ---------- rooms ----------
app.get("/rooms", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  // Все публичные + все, где пользователь — участник.
  const { results } = await c.env.DB
    .prepare(
      `SELECT r.id, r.name, r.is_public
       FROM rooms r
       WHERE r.is_public = 1
          OR r.id IN (SELECT room_id FROM memberships WHERE user_id = ?)
       ORDER BY r.created_at DESC`
    )
    .bind(u.id)
    .all();
  return c.json({ rooms: results });
});

app.post("/rooms", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const body = await c.req.json<{ name: string; is_public?: boolean }>();
  const name = body.name?.trim();
  if (!name) return c.json({ error: "name required" }, 400);
  const isPublic = body.is_public === false ? 0 : 1;
  const id = uuid();
  const now = Date.now();
  await c.env.DB
    .prepare(
      "INSERT INTO rooms (id, name, created_at, is_public, created_by) VALUES (?, ?, ?, ?, ?)"
    )
    .bind(id, name, now, isPublic, u.id).run();
  // Создатель всегда участник со статусом owner.
  await c.env.DB
    .prepare(
      "INSERT INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, ?, ?)"
    )
    .bind(u.id, id, "owner", now).run();
  return c.json({ id, name, is_public: isPublic === 1 });
});

app.post("/rooms/:id/join", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const roomId = c.req.param("id");
  const room = await c.env.DB
    .prepare("SELECT is_public FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ is_public: number }>();
  if (!room) return c.json({ error: "not found" }, 404);
  if (room.is_public !== 1) return c.json({ error: "forbidden" }, 403);
  await c.env.DB
    .prepare(
      "INSERT OR IGNORE INTO memberships (user_id, room_id, role, joined_at) VALUES (?, ?, 'member', ?)"
    )
    .bind(u.id, roomId, Date.now()).run();
  return c.json({ ok: true });
});

app.get("/rooms/:id/history", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, u.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  // Три режима:
  //   ?after=<ts>            — догрузка пропущенного после реконнекта (asc, до 200)
  //   ?before=<ts>&limit=N   — пагинация вверх по истории (desc, до 100)
  //   без параметров         — последние 50 (asc)
  const after = c.req.query("after");
  const before = c.req.query("before");
  const limit = Math.min(parseInt(c.req.query("limit") ?? "50", 10) || 50, 200);

  if (after !== undefined) {
    const ts = parseInt(after, 10) || 0;
    const { results } = await c.env.DB
      .prepare(
        `SELECT id, client_id, user_id, username, text, created_at
         FROM messages WHERE room_id = ? AND created_at > ?
         ORDER BY created_at ASC LIMIT ?`
      )
      .bind(roomId, ts, limit)
      .all();
    return c.json({ messages: results });
  }

  if (before !== undefined) {
    const ts = parseInt(before, 10);
    const { results } = await c.env.DB
      .prepare(
        `SELECT id, client_id, user_id, username, text, created_at
         FROM messages WHERE room_id = ? AND created_at < ?
         ORDER BY created_at DESC LIMIT ?`
      )
      .bind(roomId, isNaN(ts) ? Date.now() : ts, limit)
      .all();
    return c.json({ messages: (results as unknown[]).reverse() });
  }

  const { results } = await c.env.DB
    .prepare(
      `SELECT id, client_id, user_id, username, text, created_at
       FROM messages WHERE room_id = ?
       ORDER BY created_at DESC LIMIT ?`
    )
    .bind(roomId, limit)
    .all();
  return c.json({ messages: (results as unknown[]).reverse() });
});

// ---------- websocket ----------
app.get("/rooms/:id/ws", async (c) => {
  // токен передаётся query-параметром, потому что WS не позволяет легко слать заголовки
  const token = c.req.query("token");
  const user = await authUser(c.env, token);
  if (!user) return c.json({ error: "unauthorized" }, 401);

  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, user.id))) {
    return c.json({ error: "forbidden" }, 403);
  }

  const doId = c.env.ROOM.idFromName(roomId);
  const stub = c.env.ROOM.get(doId);

  // прокидываем userId/username/roomId в DO через query
  const url = new URL(c.req.url);
  url.searchParams.set("userId", user.id);
  url.searchParams.set("username", user.username);
  url.searchParams.set("roomId", roomId);

  return stub.fetch(url.toString(), c.req.raw);
});

export default app;
