import { Hono } from "hono";
import { validator } from "../lib/validator";

import { getUser, requireAuth, uuid } from "../lib/middleware";
import {
  ALLOWED_IMAGE_MIMES,
  attachmentKey,
  publicUrl,
  r2Configured,
} from "../lib/r2";
import { uploadSignBody } from "../lib/schemas";
import type { Env, Vars } from "../lib/types";

export const uploadRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

// Двухшаговый аплоад:
//   1) POST /uploads — клиент шлёт mime/size, получает attachment id.
//      Запись в attachments создаётся как pending (size фиксирован, r2_key известен).
//   2) PUT /uploads/:id — клиент шлёт тело. Worker валидирует и кладёт в R2.
// Дальше client_id-сообщение от клиента ссылается на attachment_id.
// Если PUT не пришёл — запись остаётся в БД, но без файла; в чат не попадёт.

uploadRoutes.post("/uploads", requireAuth, validator("json", uploadSignBody), async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const u = getUser(c);
  const { mime, size, width, height } = c.req.valid("json");
  if (!ALLOWED_IMAGE_MIMES.has(mime.toLowerCase())) {
    return c.json({ error: "unsupported mime" }, 415);
  }
  const id = uuid();
  const key = attachmentKey(id, mime);
  const now = Date.now();
  await c.env.DB
    .prepare(
      `INSERT INTO attachments (id, user_id, r2_key, mime, size, width, height, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(id, u.id, key, mime, size, width ?? null, height ?? null, now)
    .run();
  return c.json({
    id,
    upload_url: `/uploads/${id}`,
    public_url: publicUrl(c.env, key),
  });
});

uploadRoutes.put("/uploads/:id", requireAuth, async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const u = getUser(c);
  const id = c.req.param("id");
  const att = await c.env.DB
    .prepare("SELECT id, user_id, r2_key, mime, size FROM attachments WHERE id = ?")
    .bind(id)
    .first<{ id: string; user_id: string; r2_key: string; mime: string; size: number }>();
  if (!att) return c.json({ error: "not found" }, 404);
  if (att.user_id !== u.id) return c.json({ error: "forbidden" }, 403);
  // Уже залит?
  const head = await c.env.ATTACHMENTS!.head(att.r2_key);
  if (head) return c.json({ error: "already uploaded" }, 409);

  const ct = c.req.header("Content-Type") ?? "";
  if (ct.toLowerCase() !== att.mime.toLowerCase()) {
    return c.json({ error: "content-type mismatch" }, 415);
  }
  const len = parseInt(c.req.header("Content-Length") ?? "0", 10);
  if (!len || len !== att.size) {
    return c.json({ error: "content-length mismatch" }, 400);
  }
  const body = c.req.raw.body;
  if (!body) return c.json({ error: "empty body" }, 400);
  await c.env.ATTACHMENTS!.put(att.r2_key, body, {
    httpMetadata: { contentType: att.mime },
  });
  return c.json({ ok: true, public_url: publicUrl(c.env, att.r2_key) });
});

// Универсальный download, если bucket без публичного домена.
// Аутентифицированный пользователь может скачать любое вложение, у которого есть
// сообщение в доступной ему комнате. Без публичного R2 — обязательный путь.
uploadRoutes.get("/attachments/:id", requireAuth, async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const u = getUser(c);
  const id = c.req.param("id");
  const att = await c.env.DB
    .prepare("SELECT r2_key, mime FROM attachments WHERE id = ?")
    .bind(id)
    .first<{ r2_key: string; mime: string }>();
  if (!att) return c.json({ error: "not found" }, 404);
  // Привязано ли это вложение к сообщению, к комнате которого у юзера есть доступ?
  const access = await c.env.DB
    .prepare(
      `SELECT 1 AS x FROM messages m
       LEFT JOIN rooms r ON r.id = m.room_id
       LEFT JOIN memberships mb ON mb.room_id = m.room_id AND mb.user_id = ?
       WHERE m.attachment_id = ? AND (r.is_public = 1 OR mb.user_id IS NOT NULL)
       LIMIT 1`,
    )
    .bind(u.id, id)
    .first<{ x: number }>();
  if (!access) return c.json({ error: "forbidden" }, 403);

  const obj = await c.env.ATTACHMENTS!.get(att.r2_key);
  if (!obj) return c.json({ error: "not found" }, 404);
  return new Response(obj.body, {
    headers: {
      "Content-Type": att.mime,
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
});
