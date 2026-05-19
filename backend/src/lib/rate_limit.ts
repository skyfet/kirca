// Fixed-window rate limiter поверх D1.
// Один SQL UPDATE+SELECT на запрос. Для запуска норм, для нагрузки переедем на DO/KV.

export type RateLimitResult = { allowed: boolean; retryAfterSec: number };

export async function checkRateLimit(
  db: D1Database,
  key: string,
  limit: number,
  windowMs: number,
): Promise<RateLimitResult> {
  const now = Date.now();
  const row = await db
    .prepare("SELECT count, window_start FROM rate_limits WHERE key = ?")
    .bind(key)
    .first<{ count: number; window_start: number }>();

  if (!row || now - row.window_start >= windowMs) {
    await db
      .prepare(
        "INSERT INTO rate_limits (key, count, window_start) VALUES (?, 1, ?) " +
          "ON CONFLICT(key) DO UPDATE SET count = 1, window_start = excluded.window_start",
      )
      .bind(key, now)
      .run();
    return { allowed: true, retryAfterSec: 0 };
  }

  if (row.count >= limit) {
    return {
      allowed: false,
      retryAfterSec: Math.max(1, Math.ceil((row.window_start + windowMs - now) / 1000)),
    };
  }

  await db
    .prepare("UPDATE rate_limits SET count = count + 1 WHERE key = ?")
    .bind(key)
    .run();
  return { allowed: true, retryAfterSec: 0 };
}

export function clientIp(headers: Headers): string {
  return (
    headers.get("CF-Connecting-IP") ||
    headers.get("X-Forwarded-For")?.split(",")[0]?.trim() ||
    "0.0.0.0"
  );
}
