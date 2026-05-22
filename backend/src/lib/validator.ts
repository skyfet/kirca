import { zValidator } from "@hono/zod-validator";
import type { ZodSchema } from "zod";

// Wrapper над @hono/zod-validator: на ошибке возвращает наш формат
// `{error: "field: message"}` вместо встроенного `{success:false, error: ZodError}`.
// Так клиенты и e2e-регексы видят плоскую строку.
export function validator<T extends ZodSchema>(target: "json" | "query", schema: T) {
  return zValidator(target, schema, (result, c) => {
    if (!result.success) {
      const first = result.error.issues[0];
      const path = first.path.join(".");
      return c.json(
        { error: path ? `${path}: ${first.message}` : first.message },
        400,
      );
    }
  });
}
