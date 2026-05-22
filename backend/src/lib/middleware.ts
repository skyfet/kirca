import type { Context, MiddlewareHandler } from "hono";
import { SESSION_TTL_MS } from "./auth";
import type { Env, UserRow, Vars } from "./types";

export type { UserRow };

export const uuid = () => crypto.randomUUID();

export const bearer = (h: string | undefined) => h?.replace(/^Bearer\s+/i, "");

export async function authUser(
  env: Env,
  token: string | undefined | null,
): Promise<UserRow | null> {
  if (!token) return null;
  const now = Date.now();
  const row = await env.DB
    .prepare(
      `SELECT u.id AS id, u.username AS username
       FROM sessions s JOIN users u ON u.id = s.user_id
       WHERE s.token = ? AND (s.expires_at IS NULL OR s.expires_at > ?)`,
    )
    .bind(token, now)
    .first<UserRow>();
  return row ?? null;
}

export async function createSession(
  env: Env,
  userId: string,
): Promise<{ token: string; expiresAt: number }> {
  const token = uuid();
  const now = Date.now();
  const expiresAt = now + SESSION_TTL_MS;
  await env.DB
    .prepare("INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(token, userId, now, expiresAt)
    .run();
  return { token, expiresAt };
}

// Middleware: требует Bearer-токен. Кладёт user в c.var.user.
export const requireAuth: MiddlewareHandler<{ Bindings: Env; Variables: Vars }> = async (c, next) => {
  const u = await authUser(c.env, bearer(c.req.header("Authorization")));
  if (!u) return c.json({ error: "unauthorized" }, 401);
  c.set("user", u);
  await next();
};

// Доступ к комнате: публичная — всем, приватная — только участникам.
export async function isRoomAccessible(env: Env, roomId: string, userId: string): Promise<boolean> {
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

export function getUser(c: Context<{ Bindings: Env; Variables: Vars }>): UserRow {
  return c.get("user") as UserRow;
}
