import { env, applyD1Migrations } from "cloudflare:test";

// Перед каждым тестом гоним миграции по in-memory D1.
// Затем чистим строки, чтобы тесты были изолированы.
export async function freshDb(): Promise<D1Database> {
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  await env.DB.exec("DELETE FROM messages");
  await env.DB.exec("DELETE FROM memberships");
  await env.DB.exec("DELETE FROM rooms");
  await env.DB.exec("DELETE FROM sessions");
  await env.DB.exec("DELETE FROM users");
  await env.DB.exec("DELETE FROM rate_limits");
  await env.DB.exec("DELETE FROM devices");
  return env.DB;
}
