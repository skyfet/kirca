-- 0005: переезд хранилища вложений с R2 на D1 BLOB.
-- В этом аккаунте Cloudflare R2 не подключён, поэтому байты лежат прямо в D1.
-- Лимиты строго на ингрессе (см. backend/src/lib/r2.ts).

-- Байты вложений сообщений. Один к одному с attachments.id.
-- Отдельная таблица, чтобы выборка метаданных (mime/width/height) не тянула BLOB.
CREATE TABLE attachment_blobs (
  attachment_id TEXT PRIMARY KEY,
  bytes BLOB NOT NULL
);

-- Аватары пользователей. Один аватар на пользователя; апдейт перезаписывает строку.
-- updated_at используется как cache-buster в users.avatar_url.
CREATE TABLE user_avatars (
  user_id TEXT PRIMARY KEY,
  bytes BLOB NOT NULL,
  mime TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
