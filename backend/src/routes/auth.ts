import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";

import { hashPassword, verifyPassword } from "../lib/auth";
import { checkRateLimit, clientIp } from "../lib/rate_limit";
import { authUser, bearer, createSession, getUser, requireAuth, uuid } from "../lib/middleware";
import {
  changePasswordBody,
  loginBody,
  registerBody,
} from "../lib/schemas";
import type { Env, Vars } from "../lib/types";

const RL_REG_LIMIT = 10;
const RL_LOGIN_LIMIT = 20;
const RL_WINDOW_MS = 60 * 60 * 1000;

export const authRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

authRoutes.post("/register", zValidator("json", registerBody), async (c) => {
  const ip = clientIp(c.req.raw.headers);
  const rl = await checkRateLimit(c.env.DB, `register:${ip}`, RL_REG_LIMIT, RL_WINDOW_MS);
  if (!rl.allowed) {
    return c.json({ error: "rate limited", retry_after: rl.retryAfterSec }, 429);
  }

  const { username, password } = c.req.valid("json");

  const exists = await c.env.DB
    .prepare("SELECT id FROM users WHERE username = ?")
    .bind(username)
    .first();
  if (exists) return c.json({ error: "username taken" }, 409);

  const id = uuid();
  const hash = hashPassword(password);
  const now = Date.now();
  await c.env.DB
    .prepare("INSERT INTO users (id, username, password_hash, created_at) VALUES (?, ?, ?, ?)")
    .bind(id, username, hash, now)
    .run();

  const { token } = await createSession(c.env, id);
  return c.json({ token, user: { id, username } });
});

authRoutes.post("/login", zValidator("json", loginBody), async (c) => {
  const ip = clientIp(c.req.raw.headers);
  const rl = await checkRateLimit(c.env.DB, `login:${ip}`, RL_LOGIN_LIMIT, RL_WINDOW_MS);
  if (!rl.allowed) {
    return c.json({ error: "rate limited", retry_after: rl.retryAfterSec }, 429);
  }

  const { username, password } = c.req.valid("json");

  const row = await c.env.DB
    .prepare("SELECT id, username, password_hash FROM users WHERE username = ?")
    .bind(username)
    .first<{ id: string; username: string; password_hash: string }>();
  if (!row) return c.json({ error: "invalid credentials" }, 401);

  const v = await verifyPassword(password, row.password_hash);
  if (!v.ok) return c.json({ error: "invalid credentials" }, 401);

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

authRoutes.post("/logout", async (c) => {
  const token = bearer(c.req.header("Authorization"));
  if (!token) return c.json({ error: "unauthorized" }, 401);
  // Поддерживаем ?all=1 — отозвать все сессии этого юзера.
  if (c.req.query("all") === "1") {
    const u = await authUser(c.env, token);
    if (!u) return c.json({ error: "unauthorized" }, 401);
    await c.env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(u.id).run();
    return new Response(null, { status: 204 });
  }
  await c.env.DB.prepare("DELETE FROM sessions WHERE token = ?").bind(token).run();
  return new Response(null, { status: 204 });
});

authRoutes.post("/change-password", requireAuth, zValidator("json", changePasswordBody), async (c) => {
  const u = getUser(c);
  const token = bearer(c.req.header("Authorization"))!;
  const { old_password, new_password } = c.req.valid("json");

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
  await c.env.DB
    .prepare("DELETE FROM sessions WHERE user_id = ? AND token <> ?")
    .bind(u.id, token)
    .run();
  return c.json({ ok: true });
});
