import { scrypt } from "@noble/hashes/scrypt";
import { randomBytes } from "@noble/hashes/utils";

// scrypt-параметры. N=2^14 даёт ~50–100мс на воркере — это в пределах CPU-бюджета paid-плана.
const SCRYPT_N = 16384;
const SCRYPT_R = 8;
const SCRYPT_P = 1;
const DK_LEN = 32;
const SALT_LEN = 16;

// 30 дней. После истечения сессия отвергается; клиент должен логиниться заново.
export const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;

const enc = new TextEncoder();

function toHex(b: Uint8Array): string {
  return [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
}

function fromHex(s: string): Uint8Array {
  const n = s.length >>> 1;
  const out = new Uint8Array(n);
  for (let i = 0; i < n; i++) out[i] = parseInt(s.substr(i << 1, 2), 16);
  return out;
}

function ctEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}

export function hashPassword(password: string): string {
  const salt = randomBytes(SALT_LEN);
  const dk = scrypt(enc.encode(password), salt, {
    N: SCRYPT_N,
    r: SCRYPT_R,
    p: SCRYPT_P,
    dkLen: DK_LEN,
  });
  return `s1:${toHex(salt)}:${toHex(dk)}`;
}

export type VerifyResult = { ok: boolean; needsRehash: boolean };

export async function verifyPassword(password: string, stored: string): Promise<VerifyResult> {
  if (stored.startsWith("s1:")) {
    const parts = stored.split(":");
    if (parts.length !== 3) return { ok: false, needsRehash: false };
    const salt = fromHex(parts[1]);
    const expected = fromHex(parts[2]);
    const dk = scrypt(enc.encode(password), salt, {
      N: SCRYPT_N,
      r: SCRYPT_R,
      p: SCRYPT_P,
      dkLen: DK_LEN,
    });
    return { ok: ctEqual(dk, expected), needsRehash: false };
  }
  // Legacy SHA-256 hex (64 символа) — оставлено для существующих пользователей.
  // После успешного логина перехешируется в scrypt.
  if (/^[0-9a-f]{64}$/i.test(stored)) {
    const buf = await crypto.subtle.digest("SHA-256", enc.encode(password));
    const got = toHex(new Uint8Array(buf));
    return { ok: ctEqual(enc.encode(got), enc.encode(stored.toLowerCase())), needsRehash: true };
  }
  return { ok: false, needsRehash: false };
}
