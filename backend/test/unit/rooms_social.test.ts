import { describe, it, expect, beforeEach } from "vitest";
import { SELF, env } from "cloudflare:test";
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

const authed = (token: string) => ({
  "Content-Type": "application/json",
  Authorization: `Bearer ${token}`,
});

async function createRoom(token: string): Promise<string> {
  const r = await SELF.fetch("http://x/rooms", {
    method: "POST",
    headers: authed(token),
    body: JSON.stringify({ name: "test room" }),
  });
  return (await j(r)).id as string;
}

describe("membership PATCH (mute/pin/archive)", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("sets muted_until/pinned/archived and keeps legacy muted in sync", async () => {
    const a = await register("alice", "secret123");
    const roomId = await createRoom(a.token);

    // Mute forever (0), pin, archive.
    const r1 = await SELF.fetch(`http://x/rooms/${roomId}/membership`, {
      method: "PATCH",
      headers: authed(a.token),
      body: JSON.stringify({ muted_until: 0, pinned: true, archived: true }),
    });
    expect(r1.status).toBe(200);
    const b1 = await j(r1);
    expect(b1.muted_until).toBe(0);
    expect(b1.pinned).toBe(true);
    expect(b1.archived).toBe(true);

    // Legacy `muted` column should be 1 (muted_until IS NOT NULL).
    const row1 = await env.DB
      .prepare("SELECT muted, muted_until, pinned, archived FROM memberships WHERE user_id = ? AND room_id = ?")
      .bind(a.userId, roomId)
      .first<{ muted: number; muted_until: number | null; pinned: number; archived: number }>();
    expect(row1?.muted).toBe(1);
    expect(row1?.muted_until).toBe(0);
    expect(row1?.pinned).toBe(1);
    expect(row1?.archived).toBe(1);

    // Unmute via muted_until: null — partial patch leaves pinned/archived intact.
    const r2 = await SELF.fetch(`http://x/rooms/${roomId}/membership`, {
      method: "PATCH",
      headers: authed(a.token),
      body: JSON.stringify({ muted_until: null }),
    });
    expect(r2.status).toBe(200);
    const b2 = await j(r2);
    expect(b2.muted_until).toBe(null);
    expect(b2.pinned).toBe(true);
    expect(b2.archived).toBe(true);

    const row2 = await env.DB
      .prepare("SELECT muted, muted_until FROM memberships WHERE user_id = ? AND room_id = ?")
      .bind(a.userId, roomId)
      .first<{ muted: number; muted_until: number | null }>();
    expect(row2?.muted).toBe(0);
    expect(row2?.muted_until).toBe(null);

    // Legacy boolean muted:true maps to muted_until=0.
    const r3 = await SELF.fetch(`http://x/rooms/${roomId}/membership`, {
      method: "PATCH",
      headers: authed(a.token),
      body: JSON.stringify({ muted: true }),
    });
    expect((await j(r3)).muted_until).toBe(0);
    const row3 = await env.DB
      .prepare("SELECT muted, muted_until FROM memberships WHERE user_id = ? AND room_id = ?")
      .bind(a.userId, roomId)
      .first<{ muted: number; muted_until: number | null }>();
    expect(row3?.muted).toBe(1);
    expect(row3?.muted_until).toBe(0);
  });

  it("404 when not a member", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const roomId = await createRoom(a.token);
    const r = await SELF.fetch(`http://x/rooms/${roomId}/membership`, {
      method: "PATCH",
      headers: authed(b.token),
      body: JSON.stringify({ pinned: true }),
    });
    expect(r.status).toBe(404);
  });

  it("listRooms exposes kind, dm_key, pinned, archived, muted_until", async () => {
    const a = await register("alice", "secret123");
    const roomId = await createRoom(a.token);
    await SELF.fetch(`http://x/rooms/${roomId}/membership`, {
      method: "PATCH",
      headers: authed(a.token),
      body: JSON.stringify({ pinned: true }),
    });
    const r = await SELF.fetch("http://x/rooms", { headers: authed(a.token) });
    const rooms = (await j(r)).rooms as Array<Record<string, unknown>>;
    const room = rooms.find((x) => x.id === roomId)!;
    expect(room.kind).toBe("group");
    expect(room.dm_key).toBe(null);
    expect(room.pinned).toBe(1);
    expect(room.archived).toBe(0);
  });
});

describe("DM auto-provisioning on friendship", () => {
  beforeEach(async () => {
    await freshDb();
  });

  async function friendByAccept(a: { token: string }, b: { token: string }): Promise<void> {
    const send = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    const id = (await j(send)).id as string;
    await SELF.fetch(`http://x/friend-requests/${id}/accept`, {
      method: "POST",
      headers: authed(b.token),
    });
  }

  it("accepting a friend request provisions exactly one E2E DM room", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await friendByAccept(a, b);

    const sorted = [a.userId, b.userId].sort();
    const expectedKey = `${sorted[0]}:${sorted[1]}`;

    const { results } = await env.DB
      .prepare("SELECT id, kind, dm_key, e2e, key_version, name FROM rooms WHERE dm_key = ?")
      .bind(expectedKey)
      .all<{ id: string; kind: string; dm_key: string; e2e: number; key_version: number; name: string }>();
    expect(results).toHaveLength(1);
    expect(results[0].kind).toBe("dm");
    expect(results[0].e2e).toBe(1);
    expect(results[0].key_version).toBe(1);
    expect(results[0].name).toBe("");

    // Both users are members.
    const roomId = results[0].id;
    for (const uid of [a.userId, b.userId]) {
      const m = await env.DB
        .prepare("SELECT role FROM memberships WHERE user_id = ? AND room_id = ?")
        .bind(uid, roomId)
        .first<{ role: string }>();
      expect(m?.role).toBe("member");
    }
  });

  it("is idempotent across re-friend (remove + re-accept) — still one room", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await friendByAccept(a, b);

    const sorted = [a.userId, b.userId].sort();
    const key = `${sorted[0]}:${sorted[1]}`;

    // Remove friendship then re-add via reverse-pending auto-accept path.
    await SELF.fetch(`http://x/friends/${b.userId}`, { method: "DELETE", headers: authed(a.token) });
    // a sends, then b sends -> auto-accept (reverse pending).
    await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    const cross = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(b.token),
      body: JSON.stringify({ username: "alice" }),
    });
    expect((await j(cross)).friendship).toBe(true);

    const { results } = await env.DB
      .prepare("SELECT id FROM rooms WHERE dm_key = ?")
      .bind(key)
      .all();
    expect(results).toHaveLength(1);
  });

  it("auto-accept via reverse-pending provisions one DM room", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    const cross = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(b.token),
      body: JSON.stringify({ username: "alice" }),
    });
    expect((await j(cross)).friendship).toBe(true);

    const sorted = [a.userId, b.userId].sort();
    const key = `${sorted[0]}:${sorted[1]}`;
    const { results } = await env.DB.prepare("SELECT id FROM rooms WHERE dm_key = ?").bind(key).all();
    expect(results).toHaveLength(1);
  });
});

describe("blocks", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("block, list, unblock", async () => {
    const a = await register("alice", "secret123");
    await register("bob", "secret123");

    const block = await SELF.fetch("http://x/blocks", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    expect(block.status).toBe(200);
    const blockBody = await j(block);
    expect(blockBody.ok).toBe(true);
    const targetId = blockBody.user_id as string;

    const list = await SELF.fetch("http://x/blocks", { headers: authed(a.token) });
    const blocks = (await j(list)).blocks as Array<Record<string, unknown>>;
    expect(blocks).toHaveLength(1);
    expect(blocks[0].username).toBe("bob");

    // Idempotent re-block.
    const block2 = await SELF.fetch("http://x/blocks", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ user_id: targetId }),
    });
    expect(block2.status).toBe(200);
    const list2 = await SELF.fetch("http://x/blocks", { headers: authed(a.token) });
    expect(((await j(list2)).blocks as unknown[])).toHaveLength(1);

    // Unblock.
    const del = await SELF.fetch(`http://x/blocks/${targetId}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(del.status).toBe(204);
    const list3 = await SELF.fetch("http://x/blocks", { headers: authed(a.token) });
    expect(((await j(list3)).blocks as unknown[])).toHaveLength(0);
  });

  it("self-block is 400, unknown user is 404", async () => {
    const a = await register("alice", "secret123");
    const self = await SELF.fetch("http://x/blocks", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "alice" }),
    });
    expect(self.status).toBe(400);
    const missing = await SELF.fetch("http://x/blocks", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ user_id: "does-not-exist" }),
    });
    expect(missing.status).toBe(404);
  });

  it("a block prevents a friend request in either direction (403)", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");

    // alice blocks bob.
    await SELF.fetch("http://x/blocks", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });

    // alice -> bob blocked.
    const r1 = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    expect(r1.status).toBe(403);

    // bob -> alice also blocked (symmetric).
    const r2 = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(b.token),
      body: JSON.stringify({ username: "alice" }),
    });
    expect(r2.status).toBe(403);
  });

  it("auth required for block endpoints", async () => {
    for (const [method, path] of [
      ["POST", "/blocks"],
      ["GET", "/blocks"],
      ["DELETE", "/blocks/u1"],
    ] as const) {
      const r = await SELF.fetch(`http://x${path}`, { method });
      expect(r.status, `${method} ${path}`).toBe(401);
    }
  });
});
