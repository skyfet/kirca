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
  await env.DB.exec("DELETE FROM read_state");
  await env.DB.exec("DELETE FROM invites");
  await env.DB.exec("DELETE FROM attachments");
  await env.DB.exec("DELETE FROM attachment_blobs");
  await env.DB.exec("DELETE FROM user_avatars");
  return env.DB;
}
