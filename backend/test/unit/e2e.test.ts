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

const fakeB64 = (n: number) =>
  Buffer.from(Array.from({ length: n }, (_, i) => i & 0xff)).toString("base64");

describe("E2E endpoints", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("PUT /me/identity stores the bundle and GET reads it back", async () => {
    const { token } = await register("alice", "passwd123");
    const bundle = {
      identity_pub: fakeB64(32),
      identity_priv_wrapped: fakeB64(48), // 32 + 16 GCM tag
      identity_priv_iv: fakeB64(12),
      recovery_salt: fakeB64(16),
    };
    const put = await SELF.fetch("http://x/me/identity", {
      method: "PUT",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify(bundle),
    });
    expect(put.status).toBe(200);
    const putBody = await j(put);
    expect(putBody.ok).toBe(true);

    const get = await SELF.fetch("http://x/me/identity", {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(get.status).toBe(200);
    const got = await j(get);
    expect(got.identity_pub).toBe(bundle.identity_pub);
    expect(got.identity_priv_wrapped).toBe(bundle.identity_priv_wrapped);
    expect(got.identity_priv_iv).toBe(bundle.identity_priv_iv);
    expect(got.recovery_salt).toBe(bundle.recovery_salt);
    expect(got.identity_updated_at).toBeTypeOf("number");
  });

  it("GET /users/:id/identity returns only the public key", async () => {
    const { token, userId } = await register("bob", "passwd123");
    await SELF.fetch("http://x/me/identity", {
      method: "PUT",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        identity_pub: fakeB64(32),
        identity_priv_wrapped: fakeB64(48),
        identity_priv_iv: fakeB64(12),
        recovery_salt: fakeB64(16),
      }),
    });
    const r = await SELF.fetch(`http://x/users/${userId}/identity`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    expect(r.status).toBe(200);
    const body = await j(r);
    expect(body.user_id).toBe(userId);
    expect(body.identity_pub).toBeTypeOf("string");
    expect(body).not.toHaveProperty("identity_priv_wrapped");
    expect(body).not.toHaveProperty("recovery_salt");
  });

  it("creating a room with e2e:true forces private and seeds key_version=1", async () => {
    const { token } = await register("carol", "passwd123");
    const r = await SELF.fetch("http://x/rooms", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({ name: "secret", is_public: true, e2e: true }),
    });
    expect(r.status).toBe(200);
    const body = await j(r);
    expect(body.e2e).toBe(true);
    expect(body.is_public).toBe(false); // e2e overrides public
    expect(body.key_version).toBe(1);
  });

  it("publish + read sealed room keys", async () => {
    const { token: aT, userId: aId } = await register("dave", "passwd123");
    const { userId: bId } = await register("erin", "passwd123");

    const room = await j(
      await SELF.fetch("http://x/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${aT}` },
        body: JSON.stringify({ name: "vault", e2e: true }),
      }),
    );
    const roomId = room.id as string;

    const publish = await SELF.fetch(`http://x/rooms/${roomId}/keys`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${aT}` },
      body: JSON.stringify({
        key_version: 1,
        keys: [
          { member_user_id: aId, sealed: fakeB64(80) },
          { member_user_id: bId, sealed: fakeB64(80) },
        ],
      }),
    });
    expect(publish.status).toBe(200);
    expect((await j(publish)).stored).toBe(2);

    const fetchSelf = await SELF.fetch(`http://x/rooms/${roomId}/keys`, {
      headers: { Authorization: `Bearer ${aT}` },
    });
    expect(fetchSelf.status).toBe(200);
    const selfBody = await j(fetchSelf);
    const keys = selfBody.keys as Array<Record<string, unknown>>;
    expect(keys.length).toBe(1);
    expect(keys[0].member_user_id).toBe(aId);
    expect(keys[0].key_version).toBe(1);
  });

  it("publish keys rejects non-E2E room", async () => {
    const { token, userId } = await register("frank", "passwd123");
    const room = await j(
      await SELF.fetch("http://x/rooms", {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify({ name: "plain" }),
      }),
    );
    const r = await SELF.fetch(`http://x/rooms/${room.id}/keys`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
      body: JSON.stringify({
        key_version: 1,
        keys: [{ member_user_id: userId, sealed: fakeB64(80) }],
      }),
    });
    expect(r.status).toBe(403);
  });
});
