import { Hono } from "hono";
import { cors } from "hono/cors";

import { logError, logInfo, newRid } from "./lib/log";
import type { Env, Vars } from "./lib/types";
import { runDailySweep } from "./lib/cron";

import { homeHtml } from "./home";
import { docsHtml } from "./docs";
import { openapiSpec } from "./openapi";

import { authRoutes } from "./routes/auth";
import { deviceRoutes } from "./routes/devices";
import { roomRoutes } from "./routes/rooms";
import { messageRoutes } from "./routes/messages";
import { profileRoutes } from "./routes/profile";
import { uploadRoutes } from "./routes/uploads";
import { wsRoutes } from "./routes/ws";

export { Room } from "./room";

const app = new Hono<{ Bindings: Env; Variables: Vars }>();

app.use("*", cors());

app.use("*", async (c, next) => {
  const rid = newRid();
  c.set("rid", rid);
  const t = Date.now();
  c.res.headers.set("X-Request-Id", rid);
  await next();
  try { c.res.headers.set("X-Request-Id", rid); } catch { /* */ }
  logInfo({
    rid,
    m: c.req.method,
    p: new URL(c.req.url).pathname,
    s: c.res.status,
    ms: Date.now() - t,
  });
});

app.onError((err, c) => {
  const rid = (c.get("rid") as string | undefined) ?? "-";
  logError({ rid, err: err.message, stack: err.stack?.slice(0, 1000) });
  return c.json({ error: "internal", rid }, 500);
});

app.get("/", (c) => c.html(homeHtml, 200, { "Cache-Control": "public, max-age=300" }));
app.get("/docs", (c) => c.html(docsHtml, 200, { "Cache-Control": "public, max-age=300" }));
app.get("/openapi.json", (c) => c.json(openapiSpec));
app.get("/healthz", async (c) => {
  try {
    await c.env.DB.prepare("SELECT 1 AS x").first();
    return c.json({ ok: true, t: Date.now() });
  } catch (e) {
    return c.json({ ok: false, t: Date.now(), err: (e as Error).message }, 503);
  }
});

app.route("/", authRoutes);
app.route("/", deviceRoutes);
app.route("/", roomRoutes);
app.route("/", messageRoutes);
app.route("/", profileRoutes);
app.route("/", uploadRoutes);
app.route("/", wsRoutes);

export default {
  fetch: app.fetch,
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runDailySweep(env));
  },
} satisfies ExportedHandler<Env>;
