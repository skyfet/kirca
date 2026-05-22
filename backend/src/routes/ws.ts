import { authUser, isRoomAccessible } from "../lib/middleware";
import {
  createApp,
  createRoute,
  errorResponse,
  z,
} from "../lib/openapi";

export const wsRoutes = createApp();

function rejectWebSocket(code = 1008, reason = "unauthorized"): Response {
  const pair = new WebSocketPair();
  const [client, server] = Object.values(pair);
  server.accept();
  try { server.close(code, reason); } catch { /* */ }
  return new Response(null, { status: 101, webSocket: client });
}

const wsRoute = createRoute({
  method: "get",
  path: "/rooms/{id}/ws",
  tags: ["realtime"],
  summary: "WebSocket upgrade for live chat",
  description:
    "Open with `Upgrade: websocket`. Auth is via `?token=<sessionToken>`.\n\n**Client → server**\n- `{type:'msg', client_id, text?, attachment_id?}` — at least one of `text`/`attachment_id` required.\n- `{type:'typing', is_typing:boolean}` — ephemeral, no D1.\n\n**Server → client**\n- `{type:'msg', id, client_id, user_id, username, text, created_at, attachment?}` — broadcast/ack.\n- `{type:'edit', id, text, edited_at}` — message text changed.\n- `{type:'delete', id, deleted_at}` — message tombstoned.\n- `{type:'read', user_id, last_read_at}` — read receipt update.\n- `{type:'typing', user_id, username, is_typing}` — peer typing.\n- `{type:'presence', user_id, online}` — connection lifecycle.\n- `{type:'error', code}` — e.g. `rate_limited`.\n\nPer-user send rate limit: 10 msg / 5s. Invalid token → close with code 1008.",
  security: [],
  request: {
    params: z.object({ id: z.string().uuid() }),
    // token валидируется в хендлере — иначе zod-валидация
    // даёт 400 раньше, чем мы успеваем отдать 426 на отсутствие Upgrade.
    query: z.object({
      token: z.string().uuid().optional().describe("Session token."),
    }),
  },
  responses: {
    101: { description: "Switching Protocols — socket open." },
    426: errorResponse("Missing `Upgrade: websocket`."),
  },
});

wsRoutes.openapi(wsRoute, async (c) => {
  if (c.req.header("Upgrade") !== "websocket") {
    return c.json({ error: "expected websocket" }, 426);
  }
  const { token } = c.req.valid("query");
  const user = await authUser(c.env, token);
  if (!user) return rejectWebSocket(1008, "unauthorized");

  const { id: roomId } = c.req.valid("param");
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
