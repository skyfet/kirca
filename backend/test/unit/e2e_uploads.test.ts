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

async function createE2eRoom(token: string): Promise<string> {
  const r = await SELF.fetch("http://x/rooms", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
    body: JSON.stringify({ name: "vault", e2e: true }),
  });
  return ((await r.json()) as { id: string }).id;
}

const b64 = (n: number) =>
  Buffer.from(Array.from({ length: n }, (_, i) => (i * 11 + 1) & 0xff)).toString("base64");

describe("E2E uploads", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("reserves an E2E attachment with octet-stream mime and stores wrapping fields", async () => {
    const a = await register("alice", "passwd123");
    const roomId = await createE2eRoom(a.token);

    const r = await SELF.fetch("http://x/uploads", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
      body: JSON.stringify({
        mime: "application/octet-stream",
        size: 1024,
        e2e: true,
        room_id: roomId,
        iv: b64(12),
        wrapped_key: b64(48),
        wrapped_key_iv: b64(12),
        key_version: 1,
      }),
    });
    expect(r.status).toBe(200);
    const body = (await r.json()) as { id: string; upload_url: string };

    const row = await env.DB
      .prepare(
        "SELECT mime, wrapped_key, wrapped_key_iv, iv, key_version, room_id FROM attachments WHERE id = ?",
      )
      .bind(body.id)
      .first<{
        mime: string;
        wrapped_key: string;
        wrapped_key_iv: string;
        iv: string;
        key_version: number;
        room_id: string;
      }>();
    expect(row?.mime).toBe("application/octet-stream");
    expect(row?.wrapped_key).toBeTruthy();
    expect(row?.wrapped_key_iv).toBeTruthy();
    expect(row?.iv).toBeTruthy();
    expect(row?.key_version).toBe(1);
    expect(row?.room_id).toBe(roomId);
  });

  it("rejects e2e=true without room_id", async () => {
    const a = await register("bob", "passwd123");
    const r = await SELF.fetch("http://x/uploads", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
      body: JSON.stringify({
        mime: "application/octet-stream",
        size: 1024,
        e2e: true,
      }),
    });
    // Caught by zod refine → 400 status from validator.
    expect([400, 422]).toContain(r.status);
  });

  it("rejects e2e upload for a non-E2E room", async () => {
    const a = await register("carol", "passwd123");
    const plain = (await (
      await SELF.fetch("http://x/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
        body: JSON.stringify({ name: "plain" }),
      })
    ).json()) as { id: string };

    const r = await SELF.fetch("http://x/uploads", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${a.token}` },
      body: JSON.stringify({
        mime: "application/octet-stream",
        size: 1024,
        e2e: true,
        room_id: plain.id,
        iv: b64(12),
        wrapped_key: b64(48),
        wrapped_key_iv: b64(12),
        key_version: 1,
      }),
    });
    expect(r.status).toBe(403);
  });
});
