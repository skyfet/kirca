import { getUser, isRoomAccessible, requireAuth, uuid } from "../lib/middleware";
import {
  ALLOWED_AUDIO_MIMES,
  ALLOWED_IMAGE_MIMES,
  attachmentKey,
  publicUrl,
  r2Configured,
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
    400: errorResponse("Missing required E2E fields."),
    401: unauthorized,
    403: errorResponse("Room not accessible or not an E2E room."),
    415: errorResponse("Unsupported mime."),
    503: errorResponse("Uploads not configured."),
  },
});

uploadRoutes.openapi(reserveUploadRoute, async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const u = getUser(c);
  const body = c.req.valid("json");
  const e2e = body.e2e === true;

  if (e2e) {
    // Ciphertext attachment — server cannot inspect the bytes. Skip the
    // image-mime whitelist and require ownership of an E2E room.
    if (!body.room_id) return c.json({ error: "room_id required for e2e" }, 400);
    if (!(await isRoomAccessible(c.env, body.room_id, u.id))) {
      return c.json({ error: "room not accessible" }, 403);
    }
    const room = await c.env.DB
      .prepare("SELECT e2e FROM rooms WHERE id = ?")
      .bind(body.room_id)
      .first<{ e2e: number }>();
    if (room?.e2e !== 1) return c.json({ error: "room is not e2e" }, 403);
  } else {
    const m = body.mime.toLowerCase();
    if (!ALLOWED_IMAGE_MIMES.has(m) && !ALLOWED_AUDIO_MIMES.has(m)) {
      return c.json({ error: "unsupported mime" }, 415);
    }
  }

  const id = uuid();
  // For E2E we always store as octet-stream on R2 — the real mime lives only
  // inside the encrypted message body, where the client put it.
  const storedMime = e2e ? "application/octet-stream" : body.mime;
  const key = attachmentKey(id, storedMime);
  const now = Date.now();
  await c.env.DB
    .prepare(
      `INSERT INTO attachments
         (id, user_id, r2_key, mime, size, width, height, created_at,
          duration_ms, blurhash,
          wrapped_key, wrapped_key_iv, iv, key_version, room_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      id,
      u.id,
      key,
      storedMime,
      body.size,
      body.width ?? null,
      body.height ?? null,
      now,
      e2e ? null : (body.duration_ms ?? null),
      e2e ? null : (body.blurhash ?? null),
      e2e ? body.wrapped_key! : null,
      e2e ? body.wrapped_key_iv! : null,
      e2e ? body.iv! : null,
      e2e ? body.key_version! : null,
      e2e ? body.room_id! : null,
    )
    .run();
  return c.json(
    {
      id,
      upload_url: `/uploads/${id}`,
      public_url: publicUrl(c.env, key),
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
    415: errorResponse("Mime mismatch."),
    503: errorResponse("Uploads not configured."),
  },
});

uploadRoutes.openapi(putUploadRoute, async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const att = await c.env.DB
    .prepare("SELECT id, user_id, r2_key, mime, size FROM attachments WHERE id = ?")
    .bind(id)
    .first<{ id: string; user_id: string; r2_key: string; mime: string; size: number }>();
  if (!att) return c.json({ error: "not found" }, 404);
  if (att.user_id !== u.id) return c.json({ error: "forbidden" }, 403);
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
  return c.json({ ok: true, public_url: publicUrl(c.env, att.r2_key) }, 200);
});

const downloadAttachmentRoute = createRoute({
  method: "get",
  path: "/attachments/{id}",
  tags: ["devices"],
  summary: "Download an attachment via the worker",
  description:
    "Use when the bucket has no public domain. Requires access to a room that references this attachment.",
  middleware: [requireAuth] as const,
  request: { params: z.object({ id: z.string() }) },
  responses: {
    200: { description: "Binary.", content: { "application/octet-stream": { schema: z.string() } } },
    401: unauthorized,
    403: forbidden,
    404: notFound,
    503: errorResponse("Uploads not configured."),
  },
});

uploadRoutes.openapi(downloadAttachmentRoute, async (c) => {
  if (!r2Configured(c.env)) return c.json({ error: "uploads not configured" }, 503);
  const u = getUser(c);
  const { id } = c.req.valid("param");
  const att = await c.env.DB
    .prepare("SELECT r2_key, mime FROM attachments WHERE id = ?")
    .bind(id)
    .first<{ r2_key: string; mime: string }>();
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

  const obj = await c.env.ATTACHMENTS!.get(att.r2_key);
  if (!obj) return c.json({ error: "not found" }, 404);
  return new Response(obj.body, {
    headers: {
      "Content-Type": att.mime,
      "Cache-Control": "public, max-age=31536000, immutable",
    },
  });
});
