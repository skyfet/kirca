import { cors } from "hono/cors";

import { logError, logInfo, newRid } from "./lib/log";
import type { Env, Vars } from "./lib/types";
import { runDailySweep } from "./lib/cron";
import { createApp, createRoute, errorResponse, jsonContent, z } from "./lib/openapi";

import { homeHtml } from "./home";
import { docsHtml } from "./docs";

import { authRoutes } from "./routes/auth";
import { deviceRoutes } from "./routes/devices";
import { roomRoutes } from "./routes/rooms";
import { messageRoutes } from "./routes/messages";
import { profileRoutes } from "./routes/profile";
import { uploadRoutes } from "./routes/uploads";
import { wsRoutes } from "./routes/ws";

export { Room } from "./room";
export { UserHub } from "./user_hub";

const app = createApp();

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

// ---- meta endpoints, declared via OpenAPI so они попадают в /openapi.json ----

const landingRoute = createRoute({
  method: "get",
  path: "/",
  tags: ["meta"],
  summary: "Landing page",
  description: "Minimal HTML with links to docs, repo, and healthz.",
  security: [],
  responses: { 200: { description: "HTML.", content: { "text/html": { schema: z.string() } } } },
});

app.openapi(landingRoute, (c) =>
  c.html(homeHtml, 200, { "Cache-Control": "public, max-age=300" }),
);

const docsRoute = createRoute({
  method: "get",
  path: "/docs",
  tags: ["meta"],
  summary: "Interactive API reference",
  description: "Scalar UI rendered from `/openapi.json`.",
  security: [],
  responses: { 200: { description: "HTML.", content: { "text/html": { schema: z.string() } } } },
});

app.openapi(docsRoute, (c) =>
  c.html(docsHtml, 200, { "Cache-Control": "public, max-age=300" }),
);

const healthzRoute = createRoute({
  method: "get",
  path: "/healthz",
  tags: ["meta"],
  summary: "Health check",
  description: "Public. Suitable for UptimeRobot / external monitoring.",
  security: [],
  responses: {
    200: jsonContent(
      z.object({
        ok: z.literal(true),
        t: z.number().int().describe("Server time, epoch ms."),
      }),
      "Service is up.",
    ),
    503: errorResponse("Service degraded."),
  },
});

app.openapi(healthzRoute, async (c) => {
  try {
    await c.env.DB.prepare("SELECT 1 AS x").first();
    return c.json({ ok: true as const, t: Date.now() }, 200);
  } catch (e) {
    return c.json({ ok: false, t: Date.now(), err: (e as Error).message } as never, 503);
  }
});

app.route("/", authRoutes);
app.route("/", deviceRoutes);
app.route("/", roomRoutes);
app.route("/", messageRoutes);
app.route("/", profileRoutes);
app.route("/", uploadRoutes);
app.route("/", wsRoutes);

// Регистрируем сам /openapi.json как ручку в спеке (чтобы он попал в paths),
// фактический ответ ниже подключается через `.doc()`.
const openapiJsonRoute = createRoute({
  method: "get",
  path: "/openapi.json",
  tags: ["meta"],
  summary: "This spec",
  security: [],
  responses: {
    200: {
      description: "OpenAPI 3.1 document.",
      content: { "application/json": { schema: z.record(z.any()) } },
    },
  },
});

// Регистрируем только в спеке: реальный handler подменит .doc(...).
app.openAPIRegistry.registerPath({
  ...openapiJsonRoute,
  responses: openapiJsonRoute.responses,
});

// /openapi.json — генерируется автоматически из createRoute-определений.
app.doc("/openapi.json", {
  openapi: "3.1.0",
  info: {
    title: "kirca API",
    version: "0.1.0",
    description:
      "Chat backend running on Cloudflare Workers. HTTP for auth and history, WebSocket (`/rooms/{id}/ws`) for live messaging through a Durable Object per room.",
    license: { name: "MIT" },
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
  security: [{ bearerAuth: [] }],
});

app.openAPIRegistry.registerComponent("securitySchemes", "bearerAuth", {
  type: "http",
  scheme: "bearer",
  description:
    "Session token issued by `/register` or `/login`. TTL is 30 days. Sent as `Authorization: Bearer <token>`.",
});

export default {
  fetch: app.fetch,
  async scheduled(_controller: ScheduledController, env: Env, ctx: ExecutionContext) {
    ctx.waitUntil(runDailySweep(env));
  },
} satisfies ExportedHandler<Env>;
