import { logInfo, logError } from "./log";
import type { Env } from "./types";

// Раз в сутки чистит просроченные сессии и rate-limit-окна.
// Триггер — [triggers] crons в wrangler.toml.
export async function runDailySweep(env: Env): Promise<void> {
  const now = Date.now();
  try {
    const sessions = await env.DB
      .prepare("DELETE FROM sessions WHERE expires_at IS NOT NULL AND expires_at < ?")
      .bind(now)
      .run();
    // rate-limit окна максимум час (см. lib/rate_limit.ts) — но миграция на DO/KV когда-нибудь.
    // Чистим всё, что старше суток — для надёжности.
    const rl = await env.DB
      .prepare("DELETE FROM rate_limits WHERE window_start < ?")
      .bind(now - 24 * 60 * 60 * 1000)
      .run();
    // Принятые/отклонённые/отозванные инвайты старше 90 дней — выкидываем.
    const inv = await env.DB
      .prepare("DELETE FROM invites WHERE status <> 'pending' AND responded_at IS NOT NULL AND responded_at < ?")
      .bind(now - 90 * 24 * 60 * 60 * 1000)
      .run();
    logInfo({
      cron: "daily-sweep",
      sessions: sessions.meta.changes ?? 0,
      rate_limits: rl.meta.changes ?? 0,
      invites: inv.meta.changes ?? 0,
    });
  } catch (e) {
    logError({ cron: "daily-sweep", err: (e as Error).message });
  }
}
