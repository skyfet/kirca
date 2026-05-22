import { getUser, requireAuth } from "../lib/middleware";
import {
  createApp,
  createRoute,
  errorResponse,
  jsonContent,
  unauthorized,
  z,
} from "../lib/openapi";
import { deviceBody } from "../lib/schemas";

export const deviceRoutes = createApp();

const registerDeviceRoute = createRoute({
  method: "post",
  path: "/devices",
  tags: ["devices"],
  summary: "Register a device token for push",
  description:
    "Upserts by token — re-registering moves the token to the current user (handles device hand-off).",
  middleware: [requireAuth] as const,
  request: {
    body: { required: true, content: { "application/json": { schema: deviceBody } } },
  },
  responses: {
    200: jsonContent(z.object({ ok: z.boolean() }), "Stored."),
    400: errorResponse("Bad input."),
    401: unauthorized,
  },
});

deviceRoutes.openapi(registerDeviceRoute, async (c) => {
  const u = getUser(c);
  const { token, platform } = c.req.valid("json");
  const now = Date.now();
  await c.env.DB
    .prepare(
      "INSERT INTO devices (token, user_id, platform, created_at) VALUES (?, ?, ?, ?) " +
        "ON CONFLICT(token) DO UPDATE SET user_id = excluded.user_id, platform = excluded.platform",
    )
    .bind(token, u.id, platform, now)
    .run();
  return c.json({ ok: true }, 200);
});

const deleteDeviceRoute = createRoute({
  method: "delete",
  path: "/devices/{token}",
  tags: ["devices"],
  summary: "Unregister a device token",
  middleware: [requireAuth] as const,
  request: {
    params: z.object({ token: z.string() }),
  },
  responses: {
    204: { description: "Removed (idempotent — only deletes if the token belongs to the current user)." },
    401: unauthorized,
  },
});

deviceRoutes.openapi(deleteDeviceRoute, async (c) => {
  const u = getUser(c);
  const { token } = c.req.valid("param");
  await c.env.DB
    .prepare("DELETE FROM devices WHERE token = ? AND user_id = ?")
    .bind(token, u.id)
    .run();
  return c.body(null, 204);
});
