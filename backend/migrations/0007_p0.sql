-- 0007_p0: P0 feature batch. Additive only. Pre-launch data assumed small.

-- F1 Reply/quote: reply_to_id references another message in the same room.
ALTER TABLE messages ADD COLUMN reply_to_id TEXT;
CREATE INDEX idx_messages_reply_to ON messages(reply_to_id);

-- F3 Mentions: JSON array. For non-E2E rooms it holds plaintext user_ids.
-- For E2E rooms it holds opaque keyed tokens (see room_mention_tags below).
ALTER TABLE messages ADD COLUMN mentions TEXT;

-- F18 Forwards: provenance of a forwarded message. NULL for normal messages.
ALTER TABLE messages ADD COLUMN forwarded_from_room_id TEXT;
ALTER TABLE messages ADD COLUMN forwarded_from_msg_id TEXT;
ALTER TABLE messages ADD COLUMN forwarded_from_username TEXT;

-- F10 Blurhash placeholder (NON-E2E images only; E2E carries it in the
-- encrypted body so it never reaches the server).
ALTER TABLE attachments ADD COLUMN blurhash TEXT;

-- F11 Voice messages: audio duration in ms (NON-E2E; E2E carries it in body).
ALTER TABLE attachments ADD COLUMN duration_ms INTEGER;

-- F2 Reactions: one row per (message, user, emoji).
CREATE TABLE reactions (
  message_id TEXT NOT NULL,
  room_id    TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  emoji      TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (message_id, user_id, emoji)
);
CREATE INDEX idx_reactions_message ON reactions(message_id);
CREATE INDEX idx_reactions_room ON reactions(room_id);

-- F5 Pin/archive chat (per-user, on memberships).
ALTER TABLE memberships ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0;
ALTER TABLE memberships ADD COLUMN archived INTEGER NOT NULL DEFAULT 0;

-- F9 Mute with TTL. muted_until: NULL=not muted, 0=forever, >0=epoch-ms.
-- Keep the old boolean `muted` for one release; backfill muted=1 -> 0 (forever).
ALTER TABLE memberships ADD COLUMN muted_until INTEGER;
UPDATE memberships SET muted_until = 0 WHERE muted = 1;

-- F8 Block user. Directed; symmetric checks done in code.
CREATE TABLE blocks (
  blocker_id TEXT NOT NULL,
  blocked_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (blocker_id, blocked_id)
);
CREATE INDEX idx_blocks_blocker ON blocks(blocker_id);
CREATE INDEX idx_blocks_blocked ON blocks(blocked_id);

-- F20 DM (1:1) rooms. kind discriminates 'group' (default) from 'dm'.
-- dm_key = canonical "minUserId:maxUserId", UNIQUE among non-NULL, giving
-- idempotent DM provisioning. DMs are created when a friend request is
-- accepted (friendship => DM room). NULL dm_key for group rooms.
ALTER TABLE rooms ADD COLUMN kind TEXT NOT NULL DEFAULT 'group';
ALTER TABLE rooms ADD COLUMN dm_key TEXT;
CREATE UNIQUE INDEX uq_rooms_dm_key ON rooms(dm_key) WHERE dm_key IS NOT NULL;

-- F12 NSE single-message ciphertext fetch: no new columns (reads existing
-- messages.ciphertext/iv/key_version). F4 jump-to-unread: no backend change.
-- F7 drafts: client-only.

-- F3 (E2E mentions, keyed-token routing). Each member publishes an opaque tag
-- tag = base64(HMAC(HKDF(room_key,"kirca-mention-v1"), user_id)). To push to a
-- mentioned member in an E2E room without learning the plaintext mention list,
-- the server matches a message's mention tokens against these tags. Unused for
-- non-E2E rooms (those store plaintext user_ids in messages.mentions).
CREATE TABLE room_mention_tags (
  room_id    TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  tag        TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (room_id, user_id)
);
CREATE INDEX idx_room_mention_tags_lookup ON room_mention_tags(room_id, tag);
