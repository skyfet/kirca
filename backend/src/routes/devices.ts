import { Hono } from "hono";
import { validator } from "../lib/validator";

import { getUser, requireAuth } from "../lib/middleware";
import { deviceBody } from "../lib/schemas";
import type { Env, Vars } from "../lib/types";

export const deviceRoutes = new Hono<{ Bindings: Env; Variables: Vars }>();

deviceRoutes.post("/devices", requireAuth, validator("json", deviceBody), async (c) => {
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
  return c.json({ ok: true });
});

deviceRoutes.delete("/devices/:token", requireAuth, async (c) => {
  const u = getUser(c);
  const token = c.req.param("token");
  await c.env.DB
    .prepare("DELETE FROM devices WHERE token = ? AND user_id = ?")
    .bind(token, u.id)
    .run();
  return new Response(null, { status: 204 });
});
