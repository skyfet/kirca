import { describe, it, expect, beforeEach } from "vitest";
import { SELF } from "cloudflare:test";
import { freshDb } from "./setup";

// Two-sided coverage for the friend → DM-room provisioning flow. Where
// friends.test.ts checks the friend_requests/friendships state machine, this
// file asserts the *symmetry* of everything a freshly-formed friendship gives
// both sides: each peer sees the friend, each peer is a member of the same
// 1:1 E2E room, and each peer can fetch the other's identity public key (the
// material both clients need to derive the DM pairing key locally).

const j = (r: Response) => r.json() as Promise<Record<string, unknown>>;

async function register(
  username: string,
  password: string,
): Promise<{ token: string; userId: string }> {
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

const fakeB64 = (n: number) =>
  Buffer.from(Array.from({ length: n }, (_, i) => (i * 7) & 0xff)).toString("base64");

async function publishIdentity(token: string): Promise<string> {
  const pub = fakeB64(32);
  const r = await SELF.fetch("http://x/me/identity", {
    method: "PUT",
    headers: authed(token),
    body: JSON.stringify({
      identity_pub: pub,
      identity_priv_wrapped: fakeB64(48),
      identity_priv_iv: fakeB64(12),
      recovery_salt: fakeB64(16),
    }),
  });
  expect(r.status).toBe(200);
  return pub;
}

async function listFriends(token: string): Promise<Array<Record<string, unknown>>> {
  const r = await SELF.fetch("http://x/friends", { headers: authed(token) });
  expect(r.status).toBe(200);
  return (await j(r)).friends as Array<Record<string, unknown>>;
}

async function listRooms(token: string): Promise<Array<Record<string, unknown>>> {
  const r = await SELF.fetch("http://x/rooms", { headers: authed(token) });
  expect(r.status).toBe(200);
  return (await j(r)).rooms as Array<Record<string, unknown>>;
}

function dmRooms(rooms: Array<Record<string, unknown>>): Array<Record<string, unknown>> {
  return rooms.filter((r) => r.kind === "dm");
}

async function sendRequest(token: string, username: string): Promise<Response> {
  return SELF.fetch("http://x/friend-requests", {
    method: "POST",
    headers: authed(token),
    body: JSON.stringify({ username }),
  });
}

async function incoming(token: string): Promise<Array<Record<string, unknown>>> {
  const r = await SELF.fetch("http://x/friend-requests", { headers: authed(token) });
  expect(r.status).toBe(200);
  return (await j(r)).requests as Array<Record<string, unknown>>;
}

/** Send alice→bob and have bob accept. Returns the parsed accept body. */
async function befriend(
  a: { token: string; userId: string },
  b: { token: string; userId: string },
): Promise<Record<string, unknown>> {
  const send = await sendRequest(a.token, "bob");
  expect(send.status).toBe(200);
  const reqs = await incoming(b.token);
  expect(reqs).toHaveLength(1);
  const accept = await SELF.fetch(`http://x/friend-requests/${reqs[0].id}/accept`, {
    method: "POST",
    headers: authed(b.token),
  });
  expect(accept.status).toBe(200);
  return j(accept);
}

describe("friends → DM room provisioning (two-sided)", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("accept provisions ONE shared E2E DM room both sides are members of", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await befriend(a, b);

    const aDms = dmRooms(await listRooms(a.token));
    const bDms = dmRooms(await listRooms(b.token));

    expect(aDms).toHaveLength(1);
    expect(bDms).toHaveLength(1);
    // Same physical room on both sides.
    expect(aDms[0].id).toBe(bDms[0].id);

    for (const dm of [aDms[0], bDms[0]]) {
      expect(dm.kind).toBe("dm");
      // e2e / is_member come back as 1 (sqlite int) for both peers.
      expect(dm.e2e).toBe(1);
      expect(dm.is_member).toBe(1);
      expect(dm.key_version).toBe(1);
      expect(dm.is_public).toBe(0);
      expect(dm.name).toBe("");
    }
  });

  it("the DM room lists exactly the two friends as members", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await befriend(a, b);

    const dm = dmRooms(await listRooms(a.token))[0];
    const r = await SELF.fetch(`http://x/rooms/${dm.id}/members`, {
      headers: authed(a.token),
    });
    expect(r.status).toBe(200);
    const members = (await j(r)).members as Array<Record<string, unknown>>;
    const ids = members.map((m) => m.id).sort();
    expect(ids).toEqual([a.userId, b.userId].sort());
  });

  it("both peers see each other in /friends after accept", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await befriend(a, b);

    const aFriends = await listFriends(a.token);
    const bFriends = await listFriends(b.token);
    expect(aFriends).toHaveLength(1);
    expect(bFriends).toHaveLength(1);
    expect(aFriends[0].user_id).toBe(b.userId);
    expect(aFriends[0].username).toBe("bob");
    expect(bFriends[0].user_id).toBe(a.userId);
    expect(bFriends[0].username).toBe("alice");
  });

  it("auto-accept (reverse pending) also provisions the shared DM room for both", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");

    expect((await sendRequest(a.token, "bob")).status).toBe(200);
    // bob sends back -> collapses into an immediate friendship.
    const cross = await sendRequest(b.token, "alice");
    expect(cross.status).toBe(200);
    expect((await j(cross)).friendship).toBe(true);

    const aDms = dmRooms(await listRooms(a.token));
    const bDms = dmRooms(await listRooms(b.token));
    expect(aDms).toHaveLength(1);
    expect(bDms).toHaveLength(1);
    expect(aDms[0].id).toBe(bDms[0].id);
    expect(aDms[0].e2e).toBe(1);
  });

  it("each peer can fetch the other's identity_pub (DM pairing-key prerequisite)", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const aPub = await publishIdentity(a.token);
    const bPub = await publishIdentity(b.token);
    await befriend(a, b);

    const aSeesB = await j(
      await SELF.fetch(`http://x/users/${b.userId}/identity`, { headers: authed(a.token) }),
    );
    const bSeesA = await j(
      await SELF.fetch(`http://x/users/${a.userId}/identity`, { headers: authed(b.token) }),
    );
    expect(aSeesB.identity_pub).toBe(bPub);
    expect(bSeesA.identity_pub).toBe(aPub);
    // The private half is never exposed through this endpoint.
    expect(aSeesB).not.toHaveProperty("identity_priv_wrapped");
    expect(bSeesA).not.toHaveProperty("recovery_salt");
  });

  it("DM room is idempotent: re-friending the same pair reuses the same room", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await befriend(a, b);
    const firstDm = dmRooms(await listRooms(a.token))[0];

    // Remove the friendship (DM room + memberships survive) and befriend again.
    const del = await SELF.fetch(`http://x/friends/${b.userId}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(del.status).toBe(204);
    await befriend(a, b);

    const dmsAfter = dmRooms(await listRooms(a.token));
    // dm_key is unique, so we never spawn a second 1:1 room for the same pair.
    expect(dmsAfter).toHaveLength(1);
    expect(dmsAfter[0].id).toBe(firstDm.id);
  });

  it("no DM room exists before the friendship is accepted", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    expect((await sendRequest(a.token, "bob")).status).toBe(200);

    expect(dmRooms(await listRooms(a.token))).toHaveLength(0);
    expect(dmRooms(await listRooms(b.token))).toHaveLength(0);
  });
});

describe("friend-request edge cases (two-sided)", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("incoming list is recipient-only — the sender sees nothing incoming", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    expect((await sendRequest(a.token, "bob")).status).toBe(200);

    expect(await incoming(a.token)).toHaveLength(0);
    expect(await incoming(b.token)).toHaveLength(1);
  });

  it("cancel outgoing request removes it from the recipient's incoming list", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const send = await sendRequest(a.token, "bob");
    const id = (await j(send)).id as string;

    const cancel = await SELF.fetch(`http://x/friend-requests/${id}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(cancel.status).toBe(204);
    expect(await incoming(b.token)).toHaveLength(0);

    // Cancelling again is a clean 404 (nothing pending).
    const again = await SELF.fetch(`http://x/friend-requests/${id}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(again.status).toBe(404);
  });

  it("the recipient cannot cancel an incoming request (only the sender can)", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const id = (await j(await sendRequest(a.token, "bob"))).id as string;

    const wrong = await SELF.fetch(`http://x/friend-requests/${id}`, {
      method: "DELETE",
      headers: authed(b.token),
    });
    expect(wrong.status).toBe(404);
    // Still pending for bob.
    expect(await incoming(b.token)).toHaveLength(1);
  });

  it("the sender cannot accept their own outgoing request", async () => {
    const a = await register("alice", "secret123");
    await register("bob", "secret123");
    const id = (await j(await sendRequest(a.token, "bob"))).id as string;

    const r = await SELF.fetch(`http://x/friend-requests/${id}/accept`, {
      method: "POST",
      headers: authed(a.token),
    });
    expect(r.status).toBe(404);
  });

  it("accepting twice returns 409 the second time", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const id = (await j(await sendRequest(a.token, "bob"))).id as string;

    const first = await SELF.fetch(`http://x/friend-requests/${id}/accept`, {
      method: "POST",
      headers: authed(b.token),
    });
    expect(first.status).toBe(200);
    const second = await SELF.fetch(`http://x/friend-requests/${id}/accept`, {
      method: "POST",
      headers: authed(b.token),
    });
    expect(second.status).toBe(409);
  });

  it("declined request can be re-sent (a fresh pending row is allowed)", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const id = (await j(await sendRequest(a.token, "bob"))).id as string;
    await SELF.fetch(`http://x/friend-requests/${id}/decline`, {
      method: "POST",
      headers: authed(b.token),
    });

    const resend = await sendRequest(a.token, "bob");
    expect(resend.status).toBe(200);
    expect((await j(resend)).status).toBe("pending");
    expect(await incoming(b.token)).toHaveLength(1);
  });

  it("a friend request to an unknown username is 404", async () => {
    const a = await register("alice", "secret123");
    const r = await sendRequest(a.token, "ghost");
    expect(r.status).toBe(404);
  });

  it("blocking prevents friend requests in BOTH directions", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");

    // alice blocks bob.
    const block = await SELF.fetch("http://x/blocks", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ user_id: b.userId }),
    });
    expect(block.status).toBe(200);

    // Neither side can now send a request.
    expect((await sendRequest(a.token, "bob")).status).toBe(403);
    expect((await sendRequest(b.token, "alice")).status).toBe(403);
  });

  it("removing a friend is reflected on BOTH sides' friend lists", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await befriend(a, b);
    expect(await listFriends(a.token)).toHaveLength(1);
    expect(await listFriends(b.token)).toHaveLength(1);

    // Either side may remove; here the requester (alice) does.
    const del = await SELF.fetch(`http://x/friends/${b.userId}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(del.status).toBe(204);

    expect(await listFriends(a.token)).toHaveLength(0);
    expect(await listFriends(b.token)).toHaveLength(0);
  });
});
