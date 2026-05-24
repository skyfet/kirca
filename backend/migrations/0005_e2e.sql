-- 0005: end-to-end encryption.
--
-- The server is intentionally dumb about ciphertext: it never sees plaintext
-- bodies for E2E rooms, only opaque base64 blobs. Three new concepts:
--
-- 1. User identity key (X25519). identity_pub is the public half; clients can
--    fetch it to wrap a room key for that user. identity_priv_wrapped is the
--    private half AES-GCM-encrypted under a key derived from the user's
--    recovery phrase (PBKDF2-SHA512(phrase_seed, recovery_salt, 200k)).
--    Storing the wrapped form server-side lets a new device restore by
--    re-entering the phrase. Server cannot decrypt it.
--
-- 2. E2E room flag and sealed per-member room keys. rooms.e2e = 1 means
--    history is ciphertext-only. room_keys holds, for each (room, member,
--    key_version), an X25519 sealed-box wrapping of the room AES-256 key.
--
-- 3. Encrypted message + attachment blobs. messages.ciphertext / .iv /
--    .key_version replace the plaintext .text column for E2E rooms.
--    attachments grow wrapped_key / wrapped_key_iv / iv / key_version: the
--    per-blob AES key is wrapped with the room key, the blob itself is AES-GCM
--    encrypted with the per-blob key. R2 stores application/octet-stream.

ALTER TABLE users ADD COLUMN identity_pub TEXT;
ALTER TABLE users ADD COLUMN identity_priv_wrapped TEXT;
ALTER TABLE users ADD COLUMN identity_priv_iv TEXT;
ALTER TABLE users ADD COLUMN recovery_salt TEXT;
ALTER TABLE users ADD COLUMN identity_updated_at INTEGER;

ALTER TABLE rooms ADD COLUMN e2e INTEGER NOT NULL DEFAULT 0;
ALTER TABLE rooms ADD COLUMN key_version INTEGER NOT NULL DEFAULT 0;

-- Sealed room keys. One row per (room, member, version). When a new member
-- joins, an existing member publishes a row sealed for the new member's
-- public key. When the owner rotates the key (future), they publish a new
-- key_version row for every member.
CREATE TABLE room_keys (
  room_id        TEXT NOT NULL,
  member_user_id TEXT NOT NULL,
  key_version    INTEGER NOT NULL,
  sealed         TEXT NOT NULL,
  created_at     INTEGER NOT NULL,
  PRIMARY KEY (room_id, member_user_id, key_version)
);
CREATE INDEX idx_room_keys_room ON room_keys(room_id);
CREATE INDEX idx_room_keys_member ON room_keys(member_user_id);

-- Message ciphertext columns. For E2E rooms text is '' and these are set.
-- iv is base64(12 random bytes); ciphertext is base64(body || GCM tag).
ALTER TABLE messages ADD COLUMN ciphertext TEXT;
ALTER TABLE messages ADD COLUMN iv TEXT;
ALTER TABLE messages ADD COLUMN key_version INTEGER;

-- Attachment encryption. wrapped_key/wrapped_key_iv are the room-key
-- encrypted per-blob AES key; iv is the IV used when encrypting the blob
-- bytes themselves. For non-E2E attachments these are NULL.
ALTER TABLE attachments ADD COLUMN wrapped_key TEXT;
ALTER TABLE attachments ADD COLUMN wrapped_key_iv TEXT;
ALTER TABLE attachments ADD COLUMN iv TEXT;
ALTER TABLE attachments ADD COLUMN key_version INTEGER;
ALTER TABLE attachments ADD COLUMN room_id TEXT;
