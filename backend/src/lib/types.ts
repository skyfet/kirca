import type { ApnsEnv } from "./apns";

export type Env = ApnsEnv & {
  DB: D1Database;
  ROOM: DurableObjectNamespace;
  USER_HUB: DurableObjectNamespace;
  // R2-бакет под вложения; опционален — если не задан, /uploads отвечают 503.
  ATTACHMENTS?: R2Bucket;
  // Публичный URL-префикс для R2 (custom domain или *.r2.dev), без слэша на конце.
  R2_PUBLIC_BASE?: string;
};

export type UserRow = { id: string; username: string };

export type Vars = { rid: string; user?: UserRow };
