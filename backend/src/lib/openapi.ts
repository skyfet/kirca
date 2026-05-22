import { OpenAPIHono, z } from "@hono/zod-openapi";
import type { Env, Vars } from "./types";

export { z };
export { createRoute } from "@hono/zod-openapi";

// Factory: OpenAPIHono с нашим форматом ошибок валидации
// (`{error: "field: message"}` — плоский, под e2e-регексы).
export function createApp() {
  return new OpenAPIHono<{ Bindings: Env; Variables: Vars }>({
    defaultHook: (result, c) => {
      if (!result.success) {
        const first = result.error.issues[0];
        const path = first.path.join(".");
        return c.json(
          { error: path ? `${path}: ${first.message}` : first.message },
          400,
        );
      }
    },
  });
}

// Общие компоненты для ответов: один JSON-ответ с произвольной схемой.
export function jsonContent<T extends z.ZodTypeAny>(schema: T, description: string) {
  return {
    description,
    content: { "application/json": { schema } },
  };
}

// Простая Error-схема, используется почти везде.
export const ErrorSchema = z
  .object({
    error: z.string(),
    retry_after: z.number().int().optional(),
  })
  .openapi("Error");

export function errorResponse(description: string) {
  return jsonContent(ErrorSchema, description);
}

// Стандартные ответы 401/403/404 — для удобства.
export const unauthorized = errorResponse("Unauthorized.");
export const forbidden = errorResponse("Forbidden.");
export const notFound = errorResponse("Not found.");
