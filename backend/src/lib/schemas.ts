import { z } from "zod";

// Все request-body схемы лежат тут. Валидация — через @hono/zod-validator.

export const usernameSchema = z
  .string()
  .min(3)
  .max(32)
  .regex(/^[a-zA-Z0-9_.-]+$/, "username: only a-z, A-Z, 0-9, _, ., -");

export const passwordSchema = z.string().min(6).max(200);

export const registerBody = z.object({
  username: usernameSchema,
  password: passwordSchema,
});

export const loginBody = z.object({
  username: z.string().min(1).max(64),
  password: z.string().min(1).max(200),
});

export const changePasswordBody = z.object({
  old_password: z.string().min(1).max(200),
  new_password: passwordSchema,
});

export const deviceBody = z.object({
  token: z.string().min(1).max(256),
  platform: z.enum(["ios", "android"]),
});

export const createRoomBody = z.object({
  name: z.string().min(1).max(80).refine((s) => s.trim().length > 0, "name required"),
  is_public: z.boolean().optional(),
  e2e: z.boolean().optional().describe(
    "When true, server stores ciphertext only. Mutually exclusive with is_public=true at the UX level (no plaintext history for strangers to join into).",
  ),
});

export const messageEditBody = z.object({
  text: z.string().min(1).max(4000),
});

export const profileUpdateBody = z.object({
  display_name: z.string().min(1).max(80).nullable().optional(),
  avatar_url: z.string().url().max(1024).nullable().optional(),
});

export const inviteCreateBody = z.object({
  // принимаем либо username, либо user_id — клиенту удобнее username.
  username: usernameSchema.optional(),
  user_id: z.string().min(1).max(64).optional(),
}).refine((v) => v.username || v.user_id, {
  message: "username or user_id required",
});

export const muteBody = z.object({
  muted: z.boolean(),
});

export const readBody = z.object({
  // created_at последнего прочитанного сообщения.
  last_read_at: z.number().int().nonnegative(),
});

export const uploadSignBody = z.object({
  mime: z.string().min(1).max(128),
  size: z.number().int().positive().max(20 * 1024 * 1024), // 20 МБ
  width: z.number().int().positive().optional(),
  height: z.number().int().positive().optional(),
});

export const sendMessageBody = z.object({
  client_id: z.string().min(1).max(64),
  text: z.string().max(4000).optional(),
  attachment_id: z.string().min(1).max(64).optional(),
}).refine((v) => (v.text && v.text.trim().length > 0) || v.attachment_id, {
  message: "text or attachment_id required",
});

// ---- E2E (0005) ----------------------------------------------------------

// Base64-encoded opaque blob. Server stores as-is and never inspects.
const b64 = z.string().min(1).max(8192).regex(/^[A-Za-z0-9+/=_-]+$/, "base64");

export const identityPublishBody = z.object({
  identity_pub: b64.describe("base64(X25519 public key, 32 bytes)"),
  identity_priv_wrapped: b64.describe(
    "base64(AES-GCM ciphertext of the X25519 private key wrapped under recovery key)",
  ),
  identity_priv_iv: b64.describe("base64(12-byte IV used to wrap the private key)"),
  recovery_salt: b64.describe("base64(salt fed into PBKDF2 with the phrase)"),
});

export const roomKeyEntry = z.object({
  member_user_id: z.string().min(1).max(64),
  sealed: b64.describe("base64(sealed-box wrapping of the room key for this member)"),
});

export const publishRoomKeysBody = z.object({
  key_version: z.number().int().nonnegative(),
  keys: z.array(roomKeyEntry).min(1).max(256),
});

export const sendEncryptedMessageBody = z.object({
  client_id: z.string().min(1).max(64),
  ciphertext: b64,
  iv: b64,
  key_version: z.number().int().nonnegative(),
  attachment_id: z.string().min(1).max(64).optional(),
});

export const e2eUploadBody = z.object({
  room_id: z.string().min(1).max(64),
  size: z.number().int().positive().max(20 * 1024 * 1024),
  iv: b64,
  wrapped_key: b64,
  wrapped_key_iv: b64,
  key_version: z.number().int().nonnegative(),
});
