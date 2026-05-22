import { getUser, requireAuth, uuid } from "../lib/middleware";
import {
  ALLOWED_IMAGE_MIMES,
  MAX_ATTACHMENT_BYTES,
} from "../lib/r2";
import {
  createApp,
  createRoute,
  errorResponse,
  forbidden,
  jsonContent,
  notFound,
  unauthorized,
  z,
} from "../lib/openapi";
import { uploadSignBody } from "../lib/schemas";

export const uploadRoutes = createApp();

// r2_key — историческое поле в таблице attachments (NOT NULL).
// Сейчас байты лежат в attachment_blobs, поэтому в r2_key пишем сам id —
// это уникальное непустое значение, не используется логикой.

const reserveUploadRoute = createRoute({
  method: "post",
  path: "/uploads",
  tags: ["devices"],
  summary: "Reserve an attachment slot",
  description:
    "Step 1 of upload: server returns {id, upload_url} — PUT the bytes to upload_url next.",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: uploadSignBody } } },
  },
  responses: {
    200: jsonContent(
      z.object({
        id: z.string(),
        upload_url: z.string(),
        public_url: z.string().nullable(),
      }),
      "Reserved.",
    ),
    401: unauthorized,
    415: errorResponse("Unsupported mime."),
  },
});

uploadRoutes.openapi(reserveUploadRoute, async (c) => {
  const u = getUser(c);
  const { mime, size, width, height } = c.req.valid("json");
  if (!ALLOWED_IMAGE_MIMES.has(mime.toLowerCase())) {
    return c.json({ error: "unsupported mime" }, 415);
  }
  const id = uuid();
  const now = Date.now();
  await c.env.DB
    .prepare(
      `INSERT INTO attachments (id, user_id, r2_key, mime, size, width, height, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(id, u.id, id, mime, size, width ?? null, height ?? null, now)
    .run();
  return c.json(
    {
      id,
      upload_url: `/uploads/${id}`,
      // Без R2/CDN прямого URL нет — клиент тянет через /attachments/:id с авторизацией.
      public_url: null,
    },
    200,
  );
});

const putUploadRoute = createRoute({
  method: "put",
  path: "/uploads/{id}",
  tags: ["devices"],
  summary: "Upload the bytes for a reserved attachment",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: jsonContent(
      z.object({ ok: z.boolean(), public_url: z.string().nullable() }),
      "Stored.",
    ),
    400: errorResponse("Empty body or content-length mismatch."),
    401: unauthorized,
    403: errorResponse("Not the owner."),
    404: notFound,
    409: errorResponse("Already uploaded."),
    413: errorResponse("Body exceeds D1 BLOB limit."),
    415: errorResponse("Mime mismatch."),
  },
});

uploadRoutes.openapi(putUploadRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const att = await c.env.DB
    .prepare("SELECT id, user_id, mime, size FROM attachments WHERE id = ?")
    .bind(id)
    .first<{ id: string; user_id: string; mime: string; size: number }>();
  if (!att) return c.json({ error: "not found" }, 404);
  if (att.user_id !== u.id) return c.json({ error: "forbidden" }, 403);
  const existing = await c.env.DB
    .prepare("SELECT 1 AS x FROM attachment_blobs WHERE attachment_id = ?")
    .bind(id)
    .first<{ x: number }>();
  if (existing) return c.json({ error: "already uploaded" }, 409);

  const ct = c.req.header("Content-Type") ?? "";
  if (ct.toLowerCase() !== att.mime.toLowerCase()) {
    return c.json({ error: "content-type mismatch" }, 415);
  }
  const len = parseInt(c.req.header("Content-Length") ?? "0", 10);
  if (!len || len !== att.size) {
    return c.json({ error: "content-length mismatch" }, 400);
  }
  if (len > MAX_ATTACHMENT_BYTES) {
    return c.json({ error: "too large" }, 413);
  }
  const buf = await c.req.raw.arrayBuffer();
  if (buf.byteLength === 0) return c.json({ error: "empty body" }, 400);
  if (buf.byteLength !== att.size) {
    return c.json({ error: "content-length mismatch" }, 400);
  }
  await c.env.DB
    .prepare("INSERT INTO attachment_blobs (attachment_id, bytes) VALUES (?, ?)")
    .bind(id, buf)
    .run();
  return c.json({ ok: true, public_url: null }, 200);
});

const downloadAttachmentRoute = createRoute({
  method: "get",
  path: "/attachments/{id}",
  tags: ["devices"],
  summary: "Download an attachment via the worker",
  description:
    "Streams the bytes from D1. Requires access to a room that references this attachment.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: { description: "Binary.", content: { "application/octet-stream": { schema: z.string() } } },
    401: unauthorized,
    403: forbidden,
    404: notFound,
  },
});

uploadRoutes.openapi(downloadAttachmentRoute, async (c) => {
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const att = await c.env.DB
    .prepare("SELECT mime FROM attachments WHERE id = ?")
    .bind(id)
    .first<{ mime: string }>();
  if (!att) return c.json({ error: "not found" }, 404);
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

  const row = await c.env.DB
    .prepare("SELECT bytes FROM attachment_blobs WHERE attachment_id = ?")
    .bind(id)
    .first<{ bytes: ArrayBuffer }>();
  if (!row) return c.json({ error: "not found" }, 404);
  return new Response(row.bytes, {
    headers: {
      "Content-Type": att.mime,
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
});
