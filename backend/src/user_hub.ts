import { DurableObject } from "cloudflare:workers";

type Env = unknown;

type Attachment = { userId: string };

/**
 * Один Durable Object на одного пользователя (idFromName(user.id)).
 * Держит активные WebSocket-соединения этого юзера со всех устройств
 * и рассылает им события, которые приходят от Room DO и REST-роутов
 * через internal POST /notify.
 *
 * События формата `{type, ...}` — расширяются без поломки клиентов
 * (неизвестные типы игнорируются на стороне клиента).
 *
 * Сейчас события только server→client; client→server по этому каналу не нужен.
 */
export class UserHub extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/notify" && request.method === "POST") {
      const payload = await request.text();
      this.broadcast(payload);
      return new Response(null, { status: 204 });
    }

    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("expected websocket", { status: 426 });
    }

    const userId = url.searchParams.get("userId") ?? "";
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ userId } satisfies Attachment);

    // Ответный «hello» — клиент видит, что подключение принято.
    try { server.send(JSON.stringify({ type: "hello" })); } catch { /* */ }

    return new Response(null, { status: 101, webSocket: client });
  }

  private broadcast(payload: string): void {
    for (const ws of this.ctx.getWebSockets()) {
      try { ws.send(payload); } catch { /* dead socket */ }
    }
  }

  // Клиент → сервер пинги/пр. Сейчас игнорируем всё.
  async webSocketMessage(_ws: WebSocket, _raw: string | ArrayBuffer) {
    /* no-op */
  }

  async webSocketClose(ws: WebSocket, code: number) {
    try { ws.close(code, "bye"); } catch { /* */ }
  }

  async webSocketError(ws: WebSocket) {
    try { ws.close(1011, "error"); } catch { /* */ }
  }
}
