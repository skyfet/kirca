import { Hono } from "hono";
import { cors } from "hono/cors";
import { hashPassword, verifyPassword, SESSION_TTL_MS } from "./lib/auth";
import { checkRateLimit, clientIp } from "./lib/rate_limit";
import { logError, logInfo, newRid } from "./lib/log";
import type { ApnsEnv } from "./lib/apns";

export { Room } from "./room";

type Env = ApnsEnv & {
  DB: D1Database;
  ROOM: DurableObjectNamespace;
};

type Vars = { rid: string };

const app = new Hono<{ Bindings: Env; Variables: Vars }>();

// ---------- middleware ----------
app.use("*", cors());

app.use("*", async (c, next) => {
  const rid = newRid();
  c.set("rid", rid);
  const t = Date.now();
  await next();
  logInfo({
    rid,
    m: c.req.method,
    p: new URL(c.req.url).pathname,
    s: c.res.status,
    ms: Date.now() - t,
  });
});

app.onError((err, c) => {
  const rid = c.get("rid") as string | undefined;
  logError({
    rid: rid ?? "-",
    err: err.message,
    stack: err.stack?.slice(0, 1000),
  });
  return c.json({ error: "internal" }, 500);
});

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

// HTTP rate-limit constants. 10 запросов в час на IP — для register/login (atak проба паролей и спам аккаунтов).
const RL_REG_LIMIT = 10;
const RL_LOGIN_LIMIT = 20;
const RL_WINDOW_MS = 60 * 60 * 1000;

// ---------- health ----------
app.get("/healthz", (c) => c.json({ ok: true, t: Date.now() }));

// ---------- auth ----------
app.post("/register", async (c) => {
  const ip = clientIp(c.req.raw.headers);
  const rl = await checkRateLimit(c.env.DB, `register:${ip}`, RL_REG_LIMIT, RL_WINDOW_MS);
  if (!rl.allowed) {
    return c.json({ error: "rate limited", retry_after: rl.retryAfterSec }, 429);
  }

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
  const ip = clientIp(c.req.raw.headers);
  const rl = await checkRateLimit(c.env.DB, `login:${ip}`, RL_LOGIN_LIMIT, RL_WINDOW_MS);
  if (!rl.allowed) {
    return c.json({ error: "rate limited", retry_after: rl.retryAfterSec }, 429);
  }

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

app.post("/logout", async (c) => {
  const token = bearer(c.req.header("Authorization"));
  if (!token) return c.json({ error: "unauthorized" }, 401);
  // Удаляем только эту сессию. Если токен поддельный — DELETE найдёт 0 строк, это ок.
  await c.env.DB.prepare("DELETE FROM sessions WHERE token = ?").bind(token).run();
  return new Response(null, { status: 204 });
});

app.post("/change-password", async (c) => {
  const token = bearer(c.req.header("Authorization"));
  const u = await authUser(c.env, token);
  if (!u) return c.json({ error: "unauthorized" }, 401);

  const { old_password, new_password } = await c.req.json<{
    old_password: string;
    new_password: string;
  }>();
  if (!old_password || !new_password) {
    return c.json({ error: "old_password and new_password required" }, 400);
  }
  if (new_password.length < 6) return c.json({ error: "password too short" }, 400);

  const row = await c.env.DB
    .prepare("SELECT password_hash FROM users WHERE id = ?")
    .bind(u.id)
    .first<{ password_hash: string }>();
  if (!row) return c.json({ error: "unauthorized" }, 401);

  const v = await verifyPassword(old_password, row.password_hash);
  if (!v.ok) return c.json({ error: "invalid old password" }, 403);

  const newHash = hashPassword(new_password);
  await c.env.DB
    .prepare("UPDATE users SET password_hash = ? WHERE id = ?")
    .bind(newHash, u.id)
    .run();
  // Отзываем все остальные сессии — менять пароль обычно из-за компрометации.
  await c.env.DB
    .prepare("DELETE FROM sessions WHERE user_id = ? AND token <> ?")
    .bind(u.id, token!)
    .run();
  return c.json({ ok: true });
});

// ---------- devices (APNs) ----------
app.post("/devices", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const { token, platform } = await c.req.json<{ token: string; platform: string }>();
  if (!token || !platform) return c.json({ error: "token and platform required" }, 400);
  if (platform !== "ios" && platform !== "android") {
    return c.json({ error: "unsupported platform" }, 400);
  }
  const now = Date.now();
  // Один токен может быть переотдан другому юзеру (передал устройство). Поэтому upsert по token.
  await c.env.DB
    .prepare(
      "INSERT INTO devices (token, user_id, platform, created_at) VALUES (?, ?, ?, ?) " +
        "ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, platform = excluded.platform"
    )
    .bind(token, u.id, platform, now)
    .run();
  return c.json({ ok: true });
});

app.delete("/devices/:token", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const token = c.req.param("token");
  await c.env.DB
    .prepare("DELETE FROM devices WHERE token = ? AND user_id = ?")
    .bind(token, u.id)
    .run();
  return new Response(null, { status: 204 });
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
// На просроченном/невалидном токене WS закрывается с кодом 1008 (вместо 401 JSON,
// который WS-клиент Flutter не увидит).
function rejectWebSocket(code = 1008, reason = "unauthorized"): Response {
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  server.accept();
  try { server.close(code, reason); } catch {}
  return new Response(null, { status: 101, webSocket: client });
}

app.get("/rooms/:id/ws", async (c) => {
  if (c.req.header("Upgrade") !== "websocket") {
    return c.json({ error: "expected websocket" }, 426);
  }
  const token = c.req.query("token");
  const user = await authUser(c.env, token);
  if (!user) return rejectWebSocket(1008, "unauthorized");

  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, user.id))) {
    return rejectWebSocket(1008, "forbidden");
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
