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

const authed = (token: string) => ({
  "Content-Type": "application/json",
  Authorization: `Bearer ${token}`,
});

describe("friends + friend-requests", () => {
  beforeEach(async () => {
    await freshDb();
  });

  it("send → list → accept produces a symmetric friendship", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");

    const send = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    expect(send.status).toBe(200);
    const body = await j(send);
    expect(body.status).toBe("pending");

    const list = await SELF.fetch("http://x/friend-requests", {
      headers: authed(b.token),
    });
    expect(list.status).toBe(200);
    const reqs = ((await j(list)).requests as Array<Record<string, unknown>>);
    expect(reqs).toHaveLength(1);
    expect(reqs[0].from_username).toBe("alice");

    const accept = await SELF.fetch(`http://x/friend-requests/${reqs[0].id}/accept`, {
      method: "POST",
      headers: authed(b.token),
    });
    expect(accept.status).toBe(200);

    // Both sides now see one friend.
    for (const tok of [a.token, b.token]) {
      const friends = await SELF.fetch("http://x/friends", { headers: authed(tok) });
      expect(friends.status).toBe(200);
      const list = (await j(friends)).friends as Array<Record<string, unknown>>;
      expect(list).toHaveLength(1);
    }
  });

  it("self-request rejected", async () => {
    const a = await register("alice", "secret123");
    const r = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "alice" }),
    });
    expect(r.status).toBe(400);
  });

  it("duplicate pending request returns 409", async () => {
    const a = await register("alice", "secret123");
    await register("bob", "secret123");
    const first = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    expect(first.status).toBe(200);
    const dup = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    expect(dup.status).toBe(409);
  });

  it("reverse pending request auto-accepts into friendship", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    // Bob sends back — should not create a second request, should just friend.
    const cross = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(b.token),
      body: JSON.stringify({ username: "alice" }),
    });
    expect(cross.status).toBe(200);
    const body = await j(cross);
    expect(body.friendship).toBe(true);

    const friends = await SELF.fetch("http://x/friends", { headers: authed(a.token) });
    const list = (await j(friends)).friends as Array<Record<string, unknown>>;
    expect(list).toHaveLength(1);
  });

  it("decline keeps no friendship, list shrinks", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
    const send = await SELF.fetch("http://x/friend-requests", {
      method: "POST",
      headers: authed(a.token),
      body: JSON.stringify({ username: "bob" }),
    });
    const id = (await j(send)).id as string;
    const decline = await SELF.fetch(`http://x/friend-requests/${id}/decline`, {
      method: "POST",
      headers: authed(b.token),
    });
    expect(decline.status).toBe(200);
    const list = await SELF.fetch("http://x/friend-requests", { headers: authed(b.token) });
    expect(((await j(list)).requests as unknown[]).length).toBe(0);
  });

  it("remove friend is idempotent and symmetric", async () => {
    const a = await register("alice", "secret123");
    const b = await register("bob", "secret123");
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

    const del = await SELF.fetch(`http://x/friends/${b.userId}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(del.status).toBe(204);

    for (const tok of [a.token, b.token]) {
      const friends = await SELF.fetch("http://x/friends", { headers: authed(tok) });
      const list = (await j(friends)).friends as unknown[];
      expect(list).toHaveLength(0);
    }

    // Re-delete is still 204.
    const del2 = await SELF.fetch(`http://x/friends/${b.userId}`, {
      method: "DELETE",
      headers: authed(a.token),
    });
    expect(del2.status).toBe(204);
  });

  it("auth required for all endpoints", async () => {
    for (const [method, path] of [
      ["GET", "/friends"],
      ["DELETE", "/friends/u1"],
      ["POST", "/friend-requests"],
      ["GET", "/friend-requests"],
      ["POST", "/friend-requests/x/accept"],
      ["POST", "/friend-requests/x/decline"],
      ["DELETE", "/friend-requests/x"],
    ] as const) {
      const r = await SELF.fetch(`http://x${path}`, { method });
      expect(r.status, `${method} ${path}`).toBe(401);
    }
  });
});
