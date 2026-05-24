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

  // Pass the room's e2e flag to the DO so it knows which message shape to
  // accept on this socket.
  const roomRow = await c.env.DB
    .prepare("SELECT e2e FROM rooms WHERE id = ?")
    .bind(roomId)
    .first<{ e2e: number }>();

  const doId = c.env.ROOM.idFromName(roomId);
  const stub = c.env.ROOM.get(doId);

  const url = new URL(c.req.url);
  url.searchParams.set("userId", user.id);
  url.searchParams.set("username", user.username);
  url.searchParams.set("roomId", roomId);
  if (roomRow?.e2e === 1) url.searchParams.set("e2e", "1");

  return stub.fetch(url.toString(), c.req.raw);
});

// ---- global per-user WS ----------------------------------------------------

const userWsRoute = createRoute({
  method: "get",
  path: "/v1/ws",
  tags: ["realtime"],
  summary: "Global per-user WebSocket",
  description:
    "Open with `Upgrade: websocket`. Auth via `?token=<sessionToken>`.\n\n" +
    "Один WS-канал на пользователя со всех устройств. Сюда приходят события,\n" +
    "которые касаются юзера, но не привязаны к конкретно открытой комнате —\n" +
    "чтобы список комнат, инвайтов и неprочитанных обновлялся в фоне.\n\n" +
    "**Server → client**\n" +
    "- `{type:'hello'}` — соединение принято.\n" +
    "- `{type:'new_message', room_id, room_name, message}` — новое сообщение в любой видимой пользователю комнате.\n" +
    "- `{type:'message_edited', room_id, id, text, edited_at}`\n" +
    "- `{type:'message_deleted', room_id, id, deleted_at}`\n" +
    "- `{type:'read_self', room_id, last_read_at}` — мульти-девайс sync счётчика unread.\n" +
    "- `{type:'room_added', room}` — после createRoom / joinRoom / acceptInvite.\n" +
    "- `{type:'room_removed', room_id}` — после leaveRoom.\n" +
    "- `{type:'invite_received', invite}` — кто-то пригласил.\n" +
    "- `{type:'invite_revoked', id}` — приглашающий отозвал.\n\n" +
    "Канал односторонний; client→server игнорируется. Невалидный токен → close 1008.",
  security: [],
  request: {
    query: z.object({
      token: z.string().uuid().optional().describe("Session token."),
    }),
  },
  responses: {
    101: { description: "Switching Protocols — socket open." },
    426: errorResponse("Missing `Upgrade: websocket`."),
  },
});

wsRoutes.openapi(userWsRoute, async (c) => {
  if (c.req.header("Upgrade") !== "websocket") {
    return c.json({ error: "expected websocket" }, 426);
  }
  const { token } = c.req.valid("query");
  const user = await authUser(c.env, token);
  if (!user) return rejectWebSocket(1008, "unauthorized");

  const stub = c.env.USER_HUB.get(c.env.USER_HUB.idFromName(user.id));

  const url = new URL(c.req.url);
  url.searchParams.set("userId", user.id);

  return stub.fetch(url.toString(), c.req.raw);
});
