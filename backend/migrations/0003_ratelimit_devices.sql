-- D11 (запуск): rate limiting и push-device-tokens.

-- Ограничители для HTTP-эндпоинтов. Ключи вида "register:<ip>" / "login:<ip>".
-- Алгоритм — fixed window, поэтому хранится счётчик и начало окна (ms).
CREATE TABLE rate_limits (
  key TEXT PRIMARY KEY,
  count INTEGER NOT NULL,
  window_start INTEGER NOT NULL
);

-- APNs device tokens. token — hex-строка из didRegisterForRemoteNotificationsWithDeviceToken.
-- При 410 от Apple строка удаляется.
CREATE TABLE devices (
  token TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  platform TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX idx_devices_user ON devices(user_id);
