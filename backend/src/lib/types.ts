import type { ApnsEnv } from "./apns";

export type Env = ApnsEnv & {
  DB: D1Database;
  ROOM: DurableObjectNamespace;
};

export type UserRow = { id: string; username: string };

export type Vars = { rid: string; user?: UserRow };
