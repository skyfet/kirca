import { getUser, requireAuth } from "../lib/middleware";
import {
  createApp,
  createRoute,
  errorResponse,
  jsonContent,
  notFound,
  unauthorized,
  z,
} from "../lib/openapi";
import { profileUpdateBody } from "../lib/schemas";
import { ALLOWED_IMAGE_MIMES, MAX_AVATAR_BYTES } from "../lib/r2";
import type { Env } from "../lib/types";

export const profileRoutes = createApp();

type ProfileRow = {
  id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  created_at: number;
};

const ProfileSchema = z
  .object({
    id: z.string(),
    username: z.string(),
    display_name: z.string().nullable(),
    avatar_url: z.string().nullable(),
    created_at: z.number().int(),
  })
  .openapi("Profile");

async function loadProfile(env: Env, userId: string): Promise<ProfileRow | null> {
  return env.DB
    .prepare("SELECT id, username, display_name, avatar_url, created_at FROM users WHERE id = ?")
    .bind(userId)
    .first<ProfileRow>();
}

const getMeRoute = createRoute({
  method: "get",
  path: "/me",
  tags: ["auth"],
  summary: "Get the current user profile",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(ProfileSchema, "Profile."),
    401: unauthorized,
    404: notFound,
  },
});

profileRoutes.openapi(getMeRoute, async (c) => {
  const u = getUser(c);
  const p = await loadProfile(c.env, u.id);
  if (!p) return c.json({ error: "not found" }, 404);
  return c.json(p, 200);
});

const patchMeRoute = createRoute({
  method: "patch",
  path: "/me",
  tags: ["auth"],
  summary: "Update display_name / avatar_url",
  middleware: [requireAuth] as const,
  request: {
    body: { content: { "application/json": { schema: profileUpdateBody } } },
  },
  responses: {
    200: jsonContent(ProfileSchema.nullable(), "Updated profile."),
    401: unauthorized,
  },
});

profileRoutes.openapi(patchMeRoute, async (c) => {
  const u = getUser(c);
  const body = c.req.valid("json");

  const sets: string[] = [];
  const args: unknown[] = [];
  if ("display_name" in body) {
    sets.push("display_name = ?");
    args.push(body.display_name ?? null);
  }
  if ("avatar_url" in body) {
    sets.push("avatar_url = ?");
    args.push(body.avatar_url ?? null);
  }
  if (sets.length === 0) return c.json((await loadProfile(c.env, u.id)) as never, 200);
  args.push(u.id);
  await c.env.DB.prepare(`UPDATE users SET ${sets.join(", ")} WHERE id = ?`).bind(...args).run();
  return c.json((await loadProfile(c.env, u.id)) as never, 200);
});

const avatarRoute = createRoute({
  method: "put",
  path: "/me/avatar",
  tags: ["auth"],
  summary: "Upload avatar image",
  description:
    "PUT body is the raw image (image/jpeg|png|webp|gif|heic). " +
    "Stored in D1 BLOB; client must compress (256 KB max).",
  middleware: [requireAuth] as const,
  responses: {
    200: jsonContent(z.object({ avatar_url: z.string().nullable() }), "Avatar uploaded."),
    400: errorResponse("Empty body."),
    401: unauthorized,
    413: errorResponse("Too large."),
    415: errorResponse("Unsupported mime."),
  },
});

profileRoutes.openapi(avatarRoute, async (c) => {
  const mime = c.req.header("Content-Type") ?? "";
  if (!ALLOWED_IMAGE_MIMES.has(mime.toLowerCase())) {
    return c.json({ error: "unsupported mime" }, 415);
  }
  const len = parseInt(c.req.header("Content-Length") ?? "0", 10);
  if (!len) return c.json({ error: "empty body" }, 400);
  if (len > MAX_AVATAR_BYTES) {
    return c.json({ error: "avatar too large" }, 413);
  }
  const u = getUser(c);
  const buf = await c.req.raw.arrayBuffer();
  if (buf.byteLength === 0) return c.json({ error: "empty body" }, 400);
  if (buf.byteLength > MAX_AVATAR_BYTES) {
    return c.json({ error: "avatar too large" }, 413);
  }
  const now = Date.now();
  // INSERT OR REPLACE — у каждого пользователя одна строка с аватаром.
  await c.env.DB
    .prepare(
      "INSERT OR REPLACE INTO user_avatars (user_id, bytes, mime, updated_at) VALUES (?, ?, ?, ?)",
    )
    .bind(u.id, buf, mime, now)
    .run();
  // avatar_url — относительный путь с cache-buster'ом по updated_at.
  // Клиент подставляет apiBase и шлёт Authorization.
  const url = `/users/${u.id}/avatar?v=${now}`;
  await c.env.DB.prepare("UPDATE users SET avatar_url = ? WHERE id = ?").bind(url, u.id).run();
  return c.json({ avatar_url: url }, 200);
});

const getAvatarRoute = createRoute({
  method: "get",
  path: "/users/{id}/avatar",
  tags: ["auth"],
  summary: "Download a user's avatar",
  description: "Streams bytes from D1. Any authenticated user can fetch any avatar.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: { description: "Binary.", content: { "application/octet-stream": { schema: z.string() } } },
    401: unauthorized,
    404: notFound,
  },
});

profileRoutes.openapi(getAvatarRoute, async (c) => {
  const { id } = c.req.valid("param");
  const row = await c.env.DB
    .prepare("SELECT bytes, mime FROM user_avatars WHERE user_id = ?")
    .bind(id)
    .first<{ bytes: ArrayBuffer; mime: string }>();
  if (!row) return c.json({ error: "not found" }, 404);
  return new Response(row.bytes, {
    headers: {
      "Content-Type": row.mime,
      // Cache-buster в query param (?v=ts) — иммутабельный кеш для каждой версии.
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
});

const deleteMeRoute = createRoute({
  method: "delete",
  path: "/me",
  tags: ["auth"],
  summary: "Delete the current account",
  description:
    "Cascades: sessions, devices, memberships, read_state, invites. Messages stay but author is masked.",
  middleware: [requireAuth] as const,
  responses: {
    204: { description: "Account deleted." },
    401: unauthorized,
  },
});

profileRoutes.openapi(deleteMeRoute, async (c) => {
  const u = getUser(c);
  const ghostName = "[удалённый]";
  await c.env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM memberships WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM read_state WHERE user_id = ?").bind(u.id).run();
  await c.env.DB
    .prepare("DELETE FROM invites WHERE invitee_user_id = ? OR inviter_user_id = ?")
    .bind(u.id, u.id)
    .run();
  await c.env.DB
    .prepare("UPDATE messages SET username = ?, user_id = 'deleted' WHERE user_id = ?")
    .bind(ghostName, u.id)
    .run();
  await c.env.DB.prepare("DELETE FROM users WHERE id = ?").bind(u.id).run();
  return c.body(null, 204);
});

const userByIdRoute = createRoute({
  method: "get",
  path: "/users/{id}",
  tags: ["auth"],
  summary: "Public profile by user id",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(z.record(z.unknown()), "Profile."),
    401: unauthorized,
    404: notFound,
  },
});

profileRoutes.openapi(userByIdRoute, async (c) => {
  const { id } = c.req.valid("param");
  const p = await c.env.DB
    .prepare("SELECT id, username, display_name, avatar_url FROM users WHERE id = ?")
    .bind(id)
    .first();
  if (!p) return c.json({ error: "not found" }, 404);
  return c.json(p as never, 200);
});
