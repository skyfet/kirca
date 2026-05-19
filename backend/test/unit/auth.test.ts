import { describe, it, expect } from "vitest";
import { hashPassword, verifyPassword } from "../../src/lib/auth";

describe("auth lib", () => {
  it("scrypt roundtrip — правильный пароль валидируется", async () => {
    const hash = hashPassword("hello-secret");
    const r = await verifyPassword("hello-secret", hash);
    expect(r.ok).toBe(true);
    expect(r.needsRehash).toBe(false);
  });

  it("неверный пароль — ok=false", async () => {
    const hash = hashPassword("right-pw");
    const r = await verifyPassword("wrong-pw", hash);
    expect(r.ok).toBe(false);
  });

  it("разные соли — разные хеши для одного пароля", () => {
    const a = hashPassword("same");
    const b = hashPassword("same");
    expect(a).not.toEqual(b);
  });

  it("легаси SHA-256 валидируется и просит rehash", async () => {
    // Пароль "legacy" → SHA-256 hex.
    const data = new TextEncoder().encode("legacy");
    const digest = await crypto.subtle.digest("SHA-256", data);
    const hex = [...new Uint8Array(digest)]
      .map((x) => x.toString(16).padStart(2, "0"))
      .join("");
    const r = await verifyPassword("legacy", hex);
    expect(r.ok).toBe(true);
    expect(r.needsRehash).toBe(true);
  });

  it("кривой формат хеша — ok=false", async () => {
    const r = await verifyPassword("anything", "not-a-hash");
    expect(r.ok).toBe(false);
  });
});
