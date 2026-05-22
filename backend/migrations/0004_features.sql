-- 0004: edit/delete, read receipts, mute, профили, приглашения, вложения.

-- Edit/delete сообщений.
-- edited_at IS NOT NULL ⇒ сообщение редактировалось.
-- deleted_at IS NOT NULL ⇒ сообщение удалено (tombstone, text затирается на сервере).
ALTER TABLE messages ADD COLUMN edited_at INTEGER;
ALTER TABLE messages ADD COLUMN deleted_at INTEGER;

-- Профили: display_name (опционально, иначе берётся username) и avatar_url
-- (публичный URL в R2 или внешний). Длина text-полей не ограничивается SQLite, но
-- проверяется на уровне API.
ALTER TABLE users ADD COLUMN display_name TEXT;
ALTER TABLE users ADD COLUMN avatar_url TEXT;

-- Mute room: per-membership флаг. Если 1 — пуши и непрочитанные не считаются.
ALTER TABLE memberships ADD COLUMN muted INTEGER NOT NULL DEFAULT 0;

-- Last read per room/user — для бейджей «непрочитанные» и read receipts.
-- last_read_at — created_at последнего сообщения, которое юзер увидел.
CREATE TABLE read_state (
  user_id TEXT NOT NULL,
  room_id TEXT NOT NULL,
  last_read_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, room_id)
);
CREATE INDEX idx_read_state_room ON read_state(room_id);

-- Invites в приватные комнаты. Хозяин комнаты (или member) создаёт инвайт
-- адресно (invitee_user_id) — принимающий зовёт POST /invites/:id/accept.
-- status: pending | accepted | declined | revoked.
CREATE TABLE invites (
  id TEXT PRIMARY KEY,
  room_id TEXT NOT NULL,
  inviter_user_id TEXT NOT NULL,
  invitee_user_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  created_at INTEGER NOT NULL,
  responded_at INTEGER
);
CREATE INDEX idx_invites_invitee ON invites(invitee_user_id, status);
CREATE INDEX idx_invites_room ON invites(room_id);
CREATE UNIQUE INDEX uq_invites_pending ON invites(room_id, invitee_user_id) WHERE status = 'pending';

-- Вложения: запись о загруженном объекте в R2.
-- Один upload — одна attachment-строка. message.attachment_id ссылается сюда.
-- size/mime — для UI (превью, ограничения). r2_key — путь в bucket.
CREATE TABLE attachments (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  r2_key TEXT NOT NULL,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL,
  width INTEGER,
  height INTEGER,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_attachments_user ON attachments(user_id);

ALTER TABLE messages ADD COLUMN attachment_id TEXT;
