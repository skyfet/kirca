import { hashPassword, verifyPassword } from "../lib/auth";
import { checkRateLimit, clientIp } from "../lib/rate_limit";
import { authUser, bearer, createSession, getUser, requireAuth, uuid } from "../lib/middleware";
import {
  createApp,
  createRoute,
  errorResponse,
  jsonContent,
  unauthorized,
  z,
} from "../lib/openapi";
import {
  changePasswordBody,
  loginBody,
  registerBody,
} from "../lib/schemas";

const RL_REG_LIMIT = 10;
const RL_LOGIN_LIMIT = 20;
const RL_WINDOW_MS = 60 * 60 * 1000;

const UserSchema = z
  .object({
    id: z.string().uuid(),
    username: z.string(),
  })
  .openapi("User");

const AuthResponseSchema = z
  .object({
    token: z.string().uuid().describe("Bearer session token. TTL is 30 days."),
    user: UserSchema,
  })
  .openapi("AuthResponse");

export const authRoutes = createApp();

const registerRoute = createRoute({
  method: "post",
  path: "/register",
  tags: ["auth"],
  summary: "Create an account and a session",
  description:
    "Rate-limited per IP: 10 requests / hour. Password is hashed with scrypt (`s1:<salt>:<hash>`).",
  security: [],
  request: {
    body: { required: true, content: { "application/json": { schema: registerBody } } },
  },
  responses: {
    200: jsonContent(AuthResponseSchema, "Account created. Token TTL is 30 days."),
    400: errorResponse("Missing fields or password < 6 chars."),
    409: errorResponse("Username taken."),
    429: errorResponse("Rate limited."),
  },
});

authRoutes.openapi(registerRoute, async (c) => {
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
  return c.json({ token, user: { id, username } }, 200);
});

const loginRoute = createRoute({
  method: "post",
  path: "/login",
  tags: ["auth"],
  summary: "Exchange credentials for a session token",
  description:
    "Rate-limited per IP: 20 requests / hour. Legacy SHA-256 hashes are transparently upgraded to scrypt on successful login.",
  security: [],
  request: {
    body: { required: true, content: { "application/json": { schema: loginBody } } },
  },
  responses: {
    200: jsonContent(AuthResponseSchema, "OK."),
    400: errorResponse("Missing fields."),
    401: errorResponse("Invalid credentials."),
    429: errorResponse("Rate limited."),
  },
});

authRoutes.openapi(loginRoute, async (c) => {
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
  return c.json({ token, user: { id: row.id, username: row.username } }, 200);
});

const logoutRoute = createRoute({
  method: "post",
  path: "/logout",
  tags: ["auth"],
  summary: "Revoke the current session",
  description:
    "Deletes just the session bound to the Bearer token. Pass `?all=1` to revoke every session of the current user.",
  request: {
    query: z.object({
      all: z.enum(["1"]).optional().describe("When `1`, drop every session for the user."),
    }),
  },
  responses: {
    204: { description: "Session removed (or token already unknown — idempotent)." },
    401: errorResponse("Missing bearer token."),
  },
});

authRoutes.openapi(logoutRoute, async (c) => {
  const token = bearer(c.req.header("Authorization"));
  if (!token) return c.json({ error: "unauthorized" }, 401);
  if (c.req.valid("query").all === "1") {
    const u = await authUser(c.env, token);
    if (!u) return c.json({ error: "unauthorized" }, 401);
    await c.env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(u.id).run();
    return c.body(null, 204);
  }
  await c.env.DB.prepare("DELETE FROM sessions WHERE token = ?").bind(token).run();
  return c.body(null, 204);
});

const changePasswordRoute = createRoute({
  method: "post",
  path: "/change-password",
  tags: ["auth"],
  summary: "Rotate password and revoke other sessions",
  description: "On success, all sessions of this user except the current one are deleted.",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: changePasswordBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "OK."),
    400: errorResponse("Missing fields or new password too short."),
    401: unauthorized,
    403: errorResponse("Old password does not match."),
  },
});

authRoutes.openapi(changePasswordRoute, async (c) => {
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
  return c.json({ ok: true }, 200);
});
