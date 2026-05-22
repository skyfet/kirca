import { Hono } from "hono";
import { authUser, isRoomAccessible } from "../lib/middleware";
import type { Env, Vars } from "../lib/types";

export const wsRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

function rejectWebSocket(code = 1008, reason = "unauthorized"): Response {
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  server.accept();
  try { server.close(code, reason); } catch { /* */ }
  return new Response(null, { status: 101, webSocket: client });
}

wsRoutes.get("/rooms/:id/ws", async (c) => {
  if (c.req.header("Upgrade") !== "websocket") {
    return c.json({ error: "expected websocket" }, 426);
  }
  const token = c.req.query("token");
  const user = await authUser(c.env, token);
  if (!user) return rejectWebSocket(1008, "unauthorized");

  const roomId = c.req.param("id");
  if (!(await isRoomAccessible(c.env, roomId, user.id))) {
    return rejectWebSocket(1008, "forbidden");
  }

  const doId = c.env.ROOM.idFromName(roomId);
  const stub = c.env.ROOM.get(doId);

  const url = new URL(c.req.url);
  url.searchParams.set("userId", user.id);
  url.searchParams.set("username", user.username);
  url.searchParams.set("roomId", roomId);

  return stub.fetch(url.toString(), c.req.raw);
});
