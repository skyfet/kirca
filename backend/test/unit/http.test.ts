import { describe, it, expect, beforeEach } from "vitest";
import { SELF } from "cloudflare:test";
import { freshDb } from "./setup";

const j = (r: Response) => r.json() as Promise<Record<string, unknown>>;

async function register(username: string, password: string): Promise<{ token: string; userId: string }> {
  const r = await SELF.fetch("http://x/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username, password }),
  });
  const body = await j(r);
  return { token: body.token as string, userId: (body.user as Record<string, string>).id };
}

describe("HTTP endpoints", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("/healthz публичен и возвращает ok", async () => {
    const r = await SELF.fetch("http://x/healthz");
    expect(r.status).toBe(200);
    const b = await j(r);
    expect(b.ok).toBe(true);
  });

  it("register/login дают токен, /rooms доступен", async () => {
    const r = await SELF.fetch("http://x/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: "alice", password: "secret123" }),
    });
    expect(r.status).toBe(200);
    const b = await j(r);
    expect(b.token).toBeTruthy();

    const list = await SELF.fetch("http://x/rooms", {
      headers: { Authorization: `Bearer ${b.token}` },
    });
    expect(list.status).toBe(200);
  });

  it("/logout отзывает сессию", async () => {
    const { token } = await register("bob", "secret123");
    const out = await SELF.fetch("http://x/logout", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(out.status).toBe(204);

    const after = await SELF.fetch("http://x/rooms", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(after.status).toBe(401);
  });

  it("/change-password требует старый пароль и инвалидирует другие сессии", async () => {
    const { token: t1 } = await register("carol", "old-pw-123");
    // Создаём вторую сессию (как логин с другого устройства).
    const r2 = await SELF.fetch("http://x/login", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ username: "carol", password: "old-pw-123" }),
    });
    const b2 = await j(r2);
    const t2 = b2.token as string;
    expect(t1).not.toEqual(t2);

    // Неправильный старый — 403.
    const bad = await SELF.fetch("http://x/change-password", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${t1}` },
      body: JSON.stringify({ old_password: "wrong", new_password: "new-pw-12" }),
    });
    expect(bad.status).toBe(403);

    // Правильный — 200, t1 живой, t2 — отозван.
    const ok = await SELF.fetch("http://x/change-password", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${t1}` },
      body: JSON.stringify({ old_password: "old-pw-123", new_password: "new-pw-12" }),
    });
    expect(ok.status).toBe(200);

    const t1Still = await SELF.fetch("http://x/rooms", {
      headers: { Authorization: `Bearer ${t1}` },
    });
    expect(t1Still.status).toBe(200);

    const t2Dead = await SELF.fetch("http://x/rooms", {
      headers: { Authorization: `Bearer ${t2}` },
    });
    expect(t2Dead.status).toBe(401);
  });

  it("/register rate-limit срабатывает после порога с одного IP", async () => {
    // CF-Connecting-IP — синтетический.
    let lastStatus = 0;
    for (let i = 0; i < 12; i++) {
      const r = await SELF.fetch("http://x/register", {
        method: "POST",
        headers: { "Content-Type": "application/json", "CF-Connecting-IP": "1.2.3.4" },
        body: JSON.stringify({ username: `rl_${i}`, password: "secret123" }),
      });
      lastStatus = r.status;
      if (r.status === 429) break;
    }
    expect(lastStatus).toBe(429);
  });

  it("приватная комната недоступна посторонним", async () => {
    const a = await register("alice2", "secret123");
    const b = await register("bob2", "secret123");

    const create = await SELF.fetch("http://x/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
      body: JSON.stringify({ name: "secret room", is_public: false }),
    });
    const room = (await j(create)) as { id: string };

    const history = await SELF.fetch(`http://x/rooms/${room.id}/history`, {
      headers: { Authorization: `Bearer ${b.token}` },
    });
    expect(history.status).toBe(403);

    const join = await SELF.fetch(`http://x/rooms/${room.id}/join`, {
      method: "POST",
      headers: { Authorization: `Bearer ${b.token}` },
    });
    expect(join.status).toBe(403);
  });

  it("/devices регистрирует и удаляет токен", async () => {
    const { token } = await register("dave", "secret123");
    const reg = await SELF.fetch("http://x/devices", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ token: "deadbeef".repeat(8), platform: "ios" }),
    });
    expect(reg.status).toBe(200);

    const del = await SELF.fetch(`http://x/devices/${"deadbeef".repeat(8)}`, {
      method: "DELETE",
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(del.status).toBe(204);
  });
});
