-- D7: at-least-once + dedup
-- client_id — клиентский UUID v4 для идемпотентной записи. NULL допустим для старых сообщений.
ALTER TABLE messages ADD COLUMN client_id TEXT;
CREATE UNIQUE INDEX uq_messages_room_client ON messages(room_id, client_id);

-- D9: сессии с TTL
ALTER TABLE sessions ADD COLUMN expires_at INTEGER;
CREATE INDEX idx_sessions_expires ON sessions(expires_at);

-- D10: memberships и публичность комнат
ALTER TABLE rooms ADD COLUMN is_public INTEGER NOT NULL DEFAULT 1;
ALTER TABLE rooms ADD COLUMN created_by TEXT;

CREATE TABLE memberships (
  user_id TEXT NOT NULL,
  room_id TEXT NOT NULL,
  role TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, room_id)
);
CREATE INDEX idx_memberships_user ON memberships(user_id);
CREATE INDEX idx_memberships_room ON memberships(room_id);
