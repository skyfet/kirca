import { Hono } from "hono";
import { cors } from "hono/cors";

export { Room } from "./room";

type Env = {
  DB: D1Database;
  ROOM: DurableObjectNamespace;
};

const app = new Hono<{ Bindings: Env }>();
app.use("*", cors());

// ---------- helpers ----------
async function sha256(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const uuid = () => crypto.randomUUID();

async function authUser(env: Env, token: string | undefined | null) {
  if (!token) return null;
  const s = await env.DB
    .prepare("SELECT user_id FROM sessions WHERE token = ?")
    .bind(token)
    .first<{ user_id: string }>();
  if (!s) return null;
  return env.DB
    .prepare("SELECT id, username FROM users WHERE id = ?")
    .bind(s.user_id)
    .first<{ id: string; username: string }>();
}

const bearer = (h: string | undefined) => h?.replace(/^Bearer\s+/i, "");

// ---------- auth ----------
app.post("/register", async (c) => {
  const { username, password } = await c.req.json<{ username: string; password: string }>();
  if (!username || !password) return c.json({ error: "username and password required" }, 400);

  const exists = await c.env.DB.prepare("SELECT id FROM users WHERE username = ?").bind(username).first();
  if (exists) return c.json({ error: "username taken" }, 409);

  const id = uuid();
  const hash = await sha256(password);
  const now = Date.now();
  await c.env.DB
    .prepare("INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
    .bind(id, username, hash, now).run();

  const token = uuid();
  await c.env.DB
    .prepare("INSERT INTO sessions (token, user_id, created_at) VALUES (?, ?, ?)")
    .bind(token, id, now).run();

  return c.json({ token, user: { id, username } });
});

app.post("/login", async (c) => {
  const { username, password } = await c.req.json<{ username: string; password: string }>();
  if (!username || !password) return c.json({ error: "username and password required" }, 400);

  const hash = await sha256(password);
  const user = await c.env.DB
    .prepare("SELECT id, username FROM users WHERE username = ? AND password_hash = ?")
    .bind(username, hash)
    .first<{ id: string; username: string }>();
  if (!user) return c.json({ error: "invalid credentials" }, 401);

  const token = uuid();
  await c.env.DB
    .prepare("INSERT INTO sessions (token, user_id, created_at) VALUES (?, ?, ?)")
    .bind(token, user.id, Date.now()).run();

  return c.json({ token, user });
});

// ---------- rooms ----------
app.get("/rooms", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const { results } = await c.env.DB
    .prepare("SELECT id, name FROM rooms ORDER BY created_at DESC")
    .all();
  return c.json({ rooms: results });
});

app.post("/rooms", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const { name } = await c.req.json<{ name: string }>();
  if (!name) return c.json({ error: "name required" }, 400);
  const id = uuid();
  await c.env.DB
    .prepare("INSERT INTO rooms (id, name, created_at) VALUES (?, ?, ?)")
    .bind(id, name, Date.now()).run();
  return c.json({ id, name });
});

app.get("/rooms/:id/history", async (c) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  const roomId = c.req.param("id");
  const { results } = await c.env.DB
    .prepare(
      "SELECT id, user_id, username, text, created_at FROM messages WHERE room_id = ? ORDER BY created_at DESC LIMIT 50"
    )
    .bind(roomId).all();
  return c.json({ messages: (results as unknown[]).reverse() });
});

// ---------- websocket ----------
app.get("/rooms/:id/ws", async (c) => {
  // токен передаётся query-параметром, потому что WS не позволяет легко слать заголовки
  const token = c.req.query("token");
  const user = await authUser(c.env, token);
  if (!user) return c.json({ error: "unauthorized" }, 401);

  const roomId = c.req.param("id");
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
