-- 0006: friend requests and friendships.
--
-- Two complementary concepts, kept in separate tables so the most common
-- queries (list pending requests, list confirmed friends) stay narrow:
--
--   friend_requests — outstanding outgoing/incoming requests. One row per
--   directed (from, to) pair while pending; on accept it produces a row in
--   friendships and the request row is marked accepted (kept for audit /
--   in case the friendship is later removed).
--
--   friendships — symmetric, deduped by storing the lower user_id in
--   user_a and the higher in user_b. PRIMARY KEY ensures one row per pair
--   regardless of who initiated, and listing my friends is a single
--   "WHERE user_a = ? OR user_b = ?".

CREATE TABLE friend_requests (
  id              TEXT PRIMARY KEY,
  from_user_id    TEXT NOT NULL,
  to_user_id      TEXT NOT NULL,
  status          TEXT NOT NULL DEFAULT 'pending',
  created_at      INTEGER NOT NULL,
  responded_at    INTEGER
);
CREATE INDEX idx_friend_requests_to ON friend_requests(to_user_id, status);
CREATE INDEX idx_friend_requests_from ON friend_requests(from_user_id, status);
-- Only one pending request per directed pair. Accepted/declined rows are
-- allowed to accumulate (history).
CREATE UNIQUE INDEX uq_friend_requests_pending
  ON friend_requests(from_user_id, to_user_id) WHERE status = 'pending';

CREATE TABLE friendships (
  user_a     TEXT NOT NULL,
  user_b     TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (user_a, user_b)
);
CREATE INDEX idx_friendships_a ON friendships(user_a);
CREATE INDEX idx_friendships_b ON friendships(user_b);
