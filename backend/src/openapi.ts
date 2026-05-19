// OpenAPI 3.1 spec for the kirca API. Hand-maintained — when you change a
// route in index.ts, mirror the change here. Served at /openapi.json and
// consumed by /docs (Scalar).

export const openapiSpec = {
  openapi: "3.1.0",
  info: {
    title: "kirca API",
    version: "0.1.0",
    description:
      "Chat backend running on Cloudflare Workers. HTTP for auth and history, WebSocket (`/rooms/{id}/ws`) for live messaging through a Durable Object per room.",
    license: { name: "MIT", identifier: "MIT" },
  },
  servers: [
    { url: "https://kirca-api.gdetemka.workers.dev", description: "production" },
    { url: "http://127.0.0.1:8787", description: "local wrangler dev" },
  ],
  tags: [
    { name: "meta", description: "Health, docs." },
    { name: "auth", description: "Register, login, password, sessions." },
    { name: "devices", description: "APNs push tokens." },
    { name: "rooms", description: "Rooms and history." },
    { name: "realtime", description: "WebSocket chat (separate protocol)." },
  ],
  components: {
    securitySchemes: {
      bearerAuth: {
        type: "http",
        scheme: "bearer",
        description:
          "Session token issued by `/register` or `/login`. TTL is 30 days. Sent as `Authorization: Bearer <token>`.",
      },
    },
    schemas: {
      Error: {
        type: "object",
        required: ["error"],
        properties: {
          error: { type: "string" },
          retry_after: {
            type: "integer",
            description: "Only on 429. Seconds until the rate-limit window resets.",
          },
        },
      },
      User: {
        type: "object",
        required: ["id", "username"],
        properties: {
          id: { type: "string", format: "uuid" },
          username: { type: "string" },
        },
      },
      AuthResponse: {
        type: "object",
        required: ["token", "user"],
        properties: {
          token: {
            type: "string",
            format: "uuid",
            description: "Bearer session token. Store securely on the client.",
          },
          user: { $ref: "#/components/schemas/User" },
        },
      },
      Credentials: {
        type: "object",
        required: ["username", "password"],
        properties: {
          username: { type: "string", minLength: 1 },
          password: { type: "string", minLength: 6 },
        },
      },
      Room: {
        type: "object",
        required: ["id", "name", "is_public"],
        properties: {
          id: { type: "string", format: "uuid" },
          name: { type: "string" },
          is_public: {
            description: "1/true if anyone can join via POST /rooms/{id}/join.",
            oneOf: [{ type: "integer", enum: [0, 1] }, { type: "boolean" }],
          },
        },
      },
      Message: {
        type: "object",
        required: ["id", "client_id", "user_id", "username", "text", "created_at"],
        properties: {
          id: { type: "integer", description: "Monotonic server id." },
          client_id: {
            type: "string",
            format: "uuid",
            description: "Idempotency key produced by the client. Used for dedup on WS send.",
          },
          user_id: { type: "string", format: "uuid" },
          username: { type: "string" },
          text: { type: "string" },
          created_at: { type: "integer", description: "Unix epoch milliseconds." },
        },
      },
    },
  },
  security: [{ bearerAuth: [] }],
  paths: {
    "/": {
      get: {
        tags: ["meta"],
        summary: "Landing page",
        description: "Minimal HTML with links to docs, repo, and healthz.",
        security: [],
        responses: { "200": { description: "HTML.", content: { "text/html": {} } } },
      },
    },
    "/healthz": {
      get: {
        tags: ["meta"],
        summary: "Health check",
        description: "Public. Suitable for UptimeRobot / external monitoring.",
        security: [],
        responses: {
          "200": {
            description: "Service is up.",
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  required: ["ok", "t"],
                  properties: {
                    ok: { type: "boolean", const: true },
                    t: { type: "integer", description: "Server time, epoch ms." },
                  },
                },
              },
            },
          },
        },
      },
    },
    "/docs": {
      get: {
        tags: ["meta"],
        summary: "Interactive API reference",
        description: "Scalar UI rendered from `/openapi.json`.",
        security: [],
        responses: { "200": { description: "HTML.", content: { "text/html": {} } } },
      },
    },
    "/openapi.json": {
      get: {
        tags: ["meta"],
        summary: "This spec",
        security: [],
        responses: {
          "200": {
            description: "OpenAPI 3.1 document.",
            content: { "application/json": {} },
          },
        },
      },
    },
    "/register": {
      post: {
        tags: ["auth"],
        summary: "Create an account and a session",
        description:
          "Rate-limited per IP: 10 requests / hour. Password is hashed with scrypt (`s1:<salt>:<hash>`).",
        security: [],
        requestBody: {
          required: true,
          content: { "application/json": { schema: { $ref: "#/components/schemas/Credentials" } } },
        },
        responses: {
          "200": {
            description: "Account created. Token TTL is 30 days.",
            content: { "application/json": { schema: { $ref: "#/components/schemas/AuthResponse" } } },
          },
          "400": { description: "Missing fields or password < 6 chars.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "409": { description: "Username taken.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "429": { description: "Rate limited.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/login": {
      post: {
        tags: ["auth"],
        summary: "Exchange credentials for a session token",
        description:
          "Rate-limited per IP: 20 requests / hour. Legacy SHA-256 hashes are transparently upgraded to scrypt on successful login.",
        security: [],
        requestBody: {
          required: true,
          content: { "application/json": { schema: { $ref: "#/components/schemas/Credentials" } } },
        },
        responses: {
          "200": {
            description: "OK.",
            content: { "application/json": { schema: { $ref: "#/components/schemas/AuthResponse" } } },
          },
          "400": { description: "Missing fields.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "401": { description: "Invalid credentials.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "429": { description: "Rate limited.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/logout": {
      post: {
        tags: ["auth"],
        summary: "Revoke the current session",
        description: "Deletes just the session bound to the Bearer token. Other sessions of the same user are kept.",
        responses: {
          "204": { description: "Session removed (or token already unknown — idempotent)." },
          "401": { description: "Missing bearer token.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/change-password": {
      post: {
        tags: ["auth"],
        summary: "Rotate password and revoke other sessions",
        description: "On success, all sessions of this user except the current one are deleted.",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["old_password", "new_password"],
                properties: {
                  old_password: { type: "string" },
                  new_password: { type: "string", minLength: 6 },
                },
              },
            },
          },
        },
        responses: {
          "200": {
            description: "OK.",
            content: { "application/json": { schema: { type: "object", properties: { ok: { type: "boolean" } } } } },
          },
          "400": { description: "Missing fields or new password too short.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "403": { description: "Old password does not match.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/devices": {
      post: {
        tags: ["devices"],
        summary: "Register a device token for push",
        description: "Upserts by token — re-registering moves the token to the current user (handles device hand-off).",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["token", "platform"],
                properties: {
                  token: { type: "string", description: "APNs device token (hex) for iOS." },
                  platform: { type: "string", enum: ["ios", "android"] },
                },
              },
            },
          },
        },
        responses: {
          "200": { description: "Stored." },
          "400": { description: "Bad input.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/devices/{token}": {
      delete: {
        tags: ["devices"],
        summary: "Unregister a device token",
        parameters: [
          { name: "token", in: "path", required: true, schema: { type: "string" } },
        ],
        responses: {
          "204": { description: "Removed (idempotent — only deletes if the token belongs to the current user)." },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/rooms": {
      get: {
        tags: ["rooms"],
        summary: "List visible rooms",
        description: "Returns all public rooms plus private rooms where the user is a member.",
        responses: {
          "200": {
            description: "OK.",
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  properties: { rooms: { type: "array", items: { $ref: "#/components/schemas/Room" } } },
                },
              },
            },
          },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
      post: {
        tags: ["rooms"],
        summary: "Create a room",
        description: "Caller becomes the owner. Public by default — set `is_public: false` for a private room.",
        requestBody: {
          required: true,
          content: {
            "application/json": {
              schema: {
                type: "object",
                required: ["name"],
                properties: {
                  name: { type: "string", minLength: 1 },
                  is_public: { type: "boolean", default: true },
                },
              },
            },
          },
        },
        responses: {
          "200": {
            description: "Created.",
            content: { "application/json": { schema: { $ref: "#/components/schemas/Room" } } },
          },
          "400": { description: "Missing name.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/rooms/{id}/join": {
      post: {
        tags: ["rooms"],
        summary: "Join a public room",
        description: "Only works for public rooms. For private rooms the owner must add you out-of-band.",
        parameters: [
          { name: "id", in: "path", required: true, schema: { type: "string", format: "uuid" } },
        ],
        responses: {
          "200": { description: "Joined (idempotent)." },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "403": { description: "Room is private.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "404": { description: "Room not found.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/rooms/{id}/history": {
      get: {
        tags: ["rooms"],
        summary: "Fetch message history",
        description:
          "Three modes:\n- no params → last 50 messages, ascending\n- `?after=<ts>` → messages strictly after `ts` (used after reconnect to fill gaps), ascending, up to 200\n- `?before=<ts>&limit=N` → older messages, ascending after a server-side reverse, up to 200\n\nTimestamps are unix epoch milliseconds.",
        parameters: [
          { name: "id", in: "path", required: true, schema: { type: "string", format: "uuid" } },
          { name: "after", in: "query", required: false, schema: { type: "integer" }, description: "Return messages with `created_at > after`." },
          { name: "before", in: "query", required: false, schema: { type: "integer" }, description: "Return messages with `created_at < before`." },
          { name: "limit", in: "query", required: false, schema: { type: "integer", minimum: 1, maximum: 200, default: 50 } },
        ],
        responses: {
          "200": {
            description: "OK.",
            content: {
              "application/json": {
                schema: {
                  type: "object",
                  properties: {
                    messages: { type: "array", items: { $ref: "#/components/schemas/Message" } },
                  },
                },
              },
            },
          },
          "401": { description: "Unauthorized.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
          "403": { description: "Not a member of a private room.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
    "/rooms/{id}/ws": {
      get: {
        tags: ["realtime"],
        summary: "WebSocket upgrade for live chat",
        description:
          "Open with `Upgrade: websocket`. Auth is via `?token=<sessionToken>` (browsers can't set headers on `WebSocket`). Server routes to the room's Durable Object, which uses WebSocket Hibernation.\n\nMessages on the socket are JSON:\n\n**Client → server**\n- `{ \"type\": \"msg\", \"client_id\": \"<uuid>\", \"text\": \"...\" }` — `client_id` is the idempotency key; the DO dedups on `UNIQUE(room_id, client_id)`.\n\n**Server → client**\n- `{ \"type\": \"msg\", \"id\": <int>, \"client_id\": \"<uuid>\", \"user_id\": \"...\", \"username\": \"...\", \"text\": \"...\", \"created_at\": <ms> }` — broadcast of an accepted message.\n\nPer-user send rate limit: 10 messages / 5 seconds. On invalid/expired token the socket is closed with code 1008.",
        security: [],
        parameters: [
          { name: "id", in: "path", required: true, schema: { type: "string", format: "uuid" } },
          {
            name: "token",
            in: "query",
            required: true,
            schema: { type: "string", format: "uuid" },
            description: "Session token. Not a header because browser WebSocket has no header API.",
          },
          {
            name: "Upgrade",
            in: "header",
            required: true,
            schema: { type: "string", enum: ["websocket"] },
          },
        ],
        responses: {
          "101": { description: "Switching Protocols — socket open." },
          "426": { description: "Missing `Upgrade: websocket`.", content: { "application/json": { schema: { $ref: "#/components/schemas/Error" } } } },
        },
      },
    },
  },
} as const;
