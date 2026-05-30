import { describe, it, expect, beforeEach } from "vitest";
import { SELF, env } from "cloudflare:test";
import { freshDb } from "./setup";

async function register(u: string, p: string) {
  const r = await SELF.fetch("http://x/register", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ username: u, password: p }),
  });
  const b = (await r.json()) as { token: string; user: { id: string } };
  return { token: b.token, userId: b.user.id };
}

describe("uploads media (audio mimes, duration)", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("reserves a non-E2E audio upload and stores duration_ms", async () => {
    const a = await register("alice", "passwd123");

    const r = await SELF.fetch("http://x/uploads", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
      body: JSON.stringify({
        mime: "audio/mp4",
        size: 2048,
        duration_ms: 4200,
      }),
    });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { id: string };

    const row = await env.DB
      .prepare("SELECT mime, duration_ms, blurhash FROM attachments WHERE id = ?")
      .bind(body.id)
      .first<{ mime: string; duration_ms: number; blurhash: string | null }>();
    expect(row?.mime).toBe("audio/mp4");
    expect(row?.duration_ms).toBe(4200);
    expect(row?.blurhash).toBeNull();
  });

  it("rejects an unsupported mime with 415", async () => {
    const a = await register("bob", "passwd123");
    const r = await SELF.fetch("http://x/uploads", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
      body: JSON.stringify({
        mime: "application/x-msdownload",
        size: 1024,
      }),
    });
    expect(r.status).toBe(415);
  });
});
