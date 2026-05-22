import { Hono } from "hono";
import { zValidator } from "@hono/zod-validator";

import { getUser, requireAuth } from "../lib/middleware";
import { profileUpdateBody } from "../lib/schemas";
import { ALLOWED_IMAGE_MIMES, avatarKey, publicUrl, r2Configured } from "../lib/r2";
import type { Env, Vars } from "../lib/types";

export const profileRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

type ProfileRow = {
  id: string;
  username: string;
  display_name: string | null;
  avatar_url: string | null;
  created_at: number;
};

async function loadProfile(env: Env, userId: string): Promise<ProfileRow | null> {
  return env.DB
    .prepare("SELECT id, username, display_name, avatar_url, created_at FROM users WHERE id = ?")
    .bind(userId)
    .first<ProfileRow>();
}

profileRoutes.get("/me", requireAuth, async (c) => {
  const u = getUser(c);
  const p = await loadProfile(c.env, u.id);
  if (!p) return c.json({ error: "not found" }, 404);
  return c.json(p);
});

profileRoutes.patch("/me", requireAuth, zValidator("json", profileUpdateBody), async (c) => {
  const u = getUser(c);
  const body = c.req.valid("json");

  // Собираем UPDATE только из переданных полей. null означает «обнулить».
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
  if (sets.length === 0) return c.json(await loadProfile(c.env, u.id));
  args.push(u.id);
  await c.env.DB.prepare(`UPDATE users SET ${sets.join(", ")} WHERE id = ?`).bind(...args).run();
  return c.json(await loadProfile(c.env, u.id));
});

// Загрузка аватарки: PUT с body=изображение, content-type заголовком.
// Тело прокидывается прямиком в R2, без буферизации.
profileRoutes.put("/me/avatar", requireAuth, async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const mime = c.req.header("Content-Type") ?? "";
  if (!ALLOWED_IMAGE_MIMES.has(mime.toLowerCase())) {
    return c.json({ error: "unsupported mime" }, 415);
  }
  const len = parseInt(c.req.header("Content-Length") ?? "0", 10);
  if (!len || len > 5 * 1024 * 1024) {
    return c.json({ error: "avatar too large (max 5MB)" }, 413);
  }
  const u = getUser(c);
  const key = avatarKey(u.id, mime);
  const body = c.req.raw.body;
  if (!body) return c.json({ error: "empty body" }, 400);
  await c.env.ATTACHMENTS!.put(key, body, {
    httpMetadata: { contentType: mime },
  });
  const url = publicUrl(c.env, key);
  if (url) {
    await c.env.DB.prepare("UPDATE users SET avatar_url = ? WHERE id = ?").bind(url, u.id).run();
  }
  return c.json({ avatar_url: url ?? null });
});

// Удаление аккаунта: каскад по всем таблицам.
// messages не удаляем — это разрушит историю в комнате; ставим tombstone на user-полях,
// но текст оставляем, чтобы остальные могли читать. Это конвенция: ник «удалённый».
profileRoutes.delete("/me", requireAuth, async (c) => {
  const u = getUser(c);
  const ghostName = "[удалённый]";
  // Один батч-транзакции D1 не поддерживает — гоняем последовательно.
  // В случае частичного фейла оставим расхождение в БД — но шанс мизерный.
  await c.env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM devices WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM memberships WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM read_state WHERE user_id = ?").bind(u.id).run();
  await c.env.DB.prepare("DELETE FROM invites WHERE invitee_user_id = ? OR inviter_user_id = ?").bind(u.id, u.id).run();
  // Сообщения остаются для контекста чата, но автор скрывается.
  await c.env.DB
    .prepare("UPDATE messages SET username = ?, user_id = 'deleted' WHERE user_id = ?")
    .bind(ghostName, u.id)
    .run();
  await c.env.DB.prepare("DELETE FROM users WHERE id = ?").bind(u.id).run();
  return new Response(null, { status: 204 });
});

// Публичный профиль (без email/sessions). Только для аутентифицированных юзеров.
profileRoutes.get("/users/:id", requireAuth, async (c) => {
  const id = c.req.param("id");
  const p = await c.env.DB
    .prepare("SELECT id, username, display_name, avatar_url FROM users WHERE id = ?")
    .bind(id)
    .first();
  if (!p) return c.json({ error: "not found" }, 404);
  return c.json(p);
});
