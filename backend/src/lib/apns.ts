// APNs HTTP/2 push через Web Crypto subtle (ES256 JWT).
// Никаких внешних библиотек. Кэш JWT в module-scope на ~50 минут.

import { logError, logInfo } from "./log";

export type ApnsEnv = {
  APNS_TEAM_ID?: string;
  APNS_KEY_ID?: string;
  APNS_BUNDLE_ID?: string;
  APNS_KEY?: string;
  APNS_HOST?: string;
};

type Aps = {
  alert: { title: string; body: string };
  badge?: number;
  sound?: string;
  "thread-id"?: string;
  // F12: when set, iOS wakes the Notification Service Extension so it can
  // fetch + decrypt the E2E ciphertext before the banner is shown.
  "mutable-content"?: 1;
};

// The full push payload: the reserved `aps` dictionary plus arbitrary
// top-level data keys (e.g. room_id, msg_id) consumed by the NSE.
type ApsPayload = Aps & {
  [key: string]: unknown;
};

let cachedKey: CryptoKey | null = null;
let cachedToken: { jwt: string; createdAt: number; kid: string; teamId: string } | null = null;

const JWT_TTL_MS = 50 * 60 * 1000;

function b64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return btoa(s).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

function pemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

async function getKey(env: ApnsEnv): Promise<CryptoKey> {
  if (cachedKey) return cachedKey;
  if (!env.APNS_KEY) throw new Error("APNS_KEY not configured");
  const der = pemToPkcs8(env.APNS_KEY);
  cachedKey = await crypto.subtle.importKey(
    "pkcs8",
    der.buffer.slice(der.byteOffset, der.byteOffset + der.byteLength) as ArrayBuffer,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  return cachedKey;
}

async function getJwt(env: ApnsEnv): Promise<string> {
  if (!env.APNS_TEAM_ID || !env.APNS_KEY_ID) {
    throw new Error("APNS_TEAM_ID/KEY_ID not configured");
  }
  const now = Date.now();
  if (
    cachedToken &&
    cachedToken.kid === env.APNS_KEY_ID &&
    cachedToken.teamId === env.APNS_TEAM_ID &&
    now - cachedToken.createdAt < JWT_TTL_MS
  ) {
    return cachedToken.jwt;
  }

  const header = { alg: "ES256", kid: env.APNS_KEY_ID };
  const claims = { iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) };
  const enc = new TextEncoder();
  const headerB64 = b64urlEncode(enc.encode(JSON.stringify(header)));
  const claimsB64 = b64urlEncode(enc.encode(JSON.stringify(claims)));
  const signingInput = `${headerB64}.${claimsB64}`;

  const key = await getKey(env);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    enc.encode(signingInput),
  );
  // subtle ECDSA уже возвращает IEEE P1363 (raw r||s) — формат для JWT ES256.
  const jwt = `${signingInput}.${b64urlEncode(new Uint8Array(sig))}`;
  cachedToken = { jwt, createdAt: now, kid: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID };
  return jwt;
}

export type SendResult = { ok: boolean; status: number; gone: boolean };

export async function apnsSend(
  env: ApnsEnv,
  deviceToken: string,
  aps: ApsPayload,
): Promise<SendResult> {
  if (!env.APNS_BUNDLE_ID) {
    throw new Error("APNS_BUNDLE_ID not configured");
  }
  const host = env.APNS_HOST || "api.push.apple.com";
  const jwt = await getJwt(env);

  // Split reserved aps keys from arbitrary top-level data keys. Apple requires
  // alert/badge/sound/thread-id/mutable-content under `aps`; custom data (e.g.
  // room_id, msg_id for the NSE) lives at the top level alongside `aps`.
  const apsReserved = new Set([
    "alert",
    "badge",
    "sound",
    "thread-id",
    "mutable-content",
    "content-available",
    "category",
  ]);
  const apsDict: Record<string, unknown> = {};
  const topLevel: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(aps)) {
    if (v === undefined) continue;
    if (apsReserved.has(k)) apsDict[k] = v;
    else topLevel[k] = v;
  }

  const res = await fetch(`https://${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": env.APNS_BUNDLE_ID,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "content-type": "application/json",
    },
    body: JSON.stringify({ ...topLevel, aps: apsDict }),
  });

  // 410 = Apple says token is dead, нужно удалить из БД.
  // 200 = успех. Остальное — лог и игнор.
  if (res.status !== 200) {
    let body = "";
    try { body = await res.text(); } catch {}
    logError({ apns: "fail", status: res.status, body });
  } else {
    logInfo({ apns: "ok", token: deviceToken.slice(0, 8) });
  }
  return { ok: res.status === 200, status: res.status, gone: res.status === 410 };
}

export async function notifyDevices(
  db: D1Database,
  env: ApnsEnv,
  userIds: string[],
  aps: ApsPayload,
): Promise<void> {
  if (userIds.length === 0) return;
  if (!env.APNS_KEY || !env.APNS_TEAM_ID || !env.APNS_KEY_ID || !env.APNS_BUNDLE_ID) {
    // APNs ещё не сконфигурирован — тихо пропускаем.
    return;
  }
  const placeholders = userIds.map(() => "?").join(",");
  const { results } = await db
    .prepare(`SELECT token FROM devices WHERE user_id IN (${placeholders})`)
    .bind(...userIds)
    .all<{ token: string }>();
  if (!results || results.length === 0) return;

  await Promise.all(
    results.map(async (r) => {
      try {
        const res = await apnsSend(env, r.token, aps);
        if (res.gone) {
          await db.prepare("DELETE FROM devices WHERE token = ?").bind(r.token).run();
        }
      } catch (e) {
        logError({ apns: "exception", err: (e as Error).message });
      }
    }),
  );
}
