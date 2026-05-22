import { logError } from "./log";

type DbEnv = { DB: D1Database; USER_HUB: DurableObjectNamespace };

/**
 * Отправить событие в персональный WS-канал пользователя (UserHub DO).
 * Best-effort: ошибки сети/отсутствие DO не прерывают вызывающий поток.
 *
 * Используется и из Room DO (новое сообщение → fan-out по членам комнаты),
 * и из REST-роутов (создание/принятие/отзыв инвайта, join/leave, edit/delete).
 */
export async function notifyUser(
  env: { USER_HUB: DurableObjectNamespace },
  userId: string,
  event: Record<string, unknown>,
): Promise<void> {
  if (!userId) return;
  try {
    const stub = env.USER_HUB.get(env.USER_HUB.idFromName(userId));
    await stub.fetch("https://userhub.internal/notify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(event),
    });
  } catch (e) {
    logError({ at: "notifyUser", uid: userId, err: (e as Error).message });
  }
}

/** Разослать событие всем членам комнаты. */
export async function notifyRoomMembers(
  env: DbEnv,
  roomId: string,
  event: Record<string, unknown>,
): Promise<void> {
  try {
    const { results } = await env.DB
      .prepare("SELECT user_id FROM memberships WHERE room_id = ?")
      .bind(roomId)
      .all<{ user_id: string }>();
    if (!results || results.length === 0) return;
    await notifyUsers(env, results.map((r) => r.user_id), event);
  } catch (e) {
    logError({ at: "notifyRoomMembers", roomId, err: (e as Error).message });
  }
}

/** То же самое, но веером по списку. Не прерывается на первом фейле. */
export async function notifyUsers(
  env: { USER_HUB: DurableObjectNamespace },
  userIds: Iterable<string>,
  event: Record<string, unknown>,
): Promise<void> {
  const body = JSON.stringify(event);
  const calls: Promise<unknown>[] = [];
  for (const uid of userIds) {
    if (!uid) continue;
    try {
      const stub = env.USER_HUB.get(env.USER_HUB.idFromName(uid));
      calls.push(
        stub
          .fetch("https://userhub.internal/notify", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body,
          })
          .catch((e) => {
            logError({ at: "notifyUsers", uid, err: (e as Error).message });
          }),
      );
    } catch (e) {
      logError({ at: "notifyUsers", uid, err: (e as Error).message });
    }
  }
  await Promise.all(calls);
}
