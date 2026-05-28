// Helpers для работы с R2-вложениями.
// Worker сам пишет в R2 через binding ATTACHMENTS — presigned URL не нужны.
// Загрузка идёт через PUT /uploads/:id с телом — Worker валидирует mime/size, кладёт в R2.

import type { Env } from "./types";

export function r2Configured(env: Env): boolean {
  return !!env.ATTACHMENTS;
}

export function attachmentKey(attachmentId: string, mime: string): string {
  // mime приходит после валидации, и в URL мы не используем расширение,
  // но в ключе R2 — да, чтобы content-type на download был корректным.
  const ext = extFromMime(mime);
  return `att/${attachmentId}${ext}`;
}

export function avatarKey(userId: string, mime: string): string {
  const ext = extFromMime(mime);
  return `avatar/${userId}${ext}`;
}

export function extFromMime(mime: string): string {
  const m = mime.toLowerCase();
  if (m === "image/jpeg" || m === "image/jpg") return ".jpg";
  if (m === "image/png") return ".png";
  if (m === "image/webp") return ".webp";
  if (m === "image/gif") return ".gif";
  if (m === "image/heic") return ".heic";
  if (m === "audio/mp4" || m === "audio/m4a") return ".m4a";
  if (m === "audio/aac") return ".aac";
  if (m === "audio/ogg") return ".ogg";
  if (m === "audio/mpeg") return ".mp3";
  if (m === "audio/webm") return ".webm";
  return "";
}

export function publicUrl(env: Env, key: string): string | null {
  if (!env.R2_PUBLIC_BASE) return null;
  const base = env.R2_PUBLIC_BASE.replace(/\/+$/, "");
  return `${base}/${key}`;
}

export const ALLOWED_IMAGE_MIMES = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
  "image/heic",
]);

export const ALLOWED_AUDIO_MIMES = new Set([
  "audio/mp4",
  "audio/aac",
  "audio/ogg",
  "audio/mpeg",
  "audio/m4a",
  "audio/webm",
]);
