import { createHmac, createPublicKey, timingSafeEqual, verify as verifySignature, type JsonWebKey } from "node:crypto";

const appleKeysURL = "https://appleid.apple.com/auth/keys";
let appleKeys: { keys: (JsonWebKey & { kid: string })[]; fetchedAt: number } | null = null;

const secret = () => process.env.SESSION_SECRET || "";
const bundleID = () => process.env.APPLE_BUNDLE_ID || "com.doorlist.app";

/**
 * Checks a Sign in with Apple identity token (RS256 JWT signed by Apple)
 * and returns the stable Apple user id. Email, if Apple included it, is
 * returned for the app to use; the server keeps neither.
 */
export async function verifyAppleToken(token: string): Promise<{ sub: string; email?: string }> {
  const [h, p, s] = token.split(".");
  if (!h || !p || !s) throw new Error("Malformed token");
  const header = JSON.parse(Buffer.from(h, "base64url").toString("utf8"));
  const payload = JSON.parse(Buffer.from(p, "base64url").toString("utf8"));

  if (header.alg !== "RS256") throw new Error("Unexpected algorithm");
  const key = await appleKey(header.kid);
  const ok = verifySignature("RSA-SHA256", Buffer.from(`${h}.${p}`), createPublicKey({ key, format: "jwk" }),
    Buffer.from(s, "base64url"));
  if (!ok) throw new Error("Bad signature");
  if (payload.iss !== "https://appleid.apple.com") throw new Error("Wrong issuer");
  if (payload.aud !== bundleID()) throw new Error("Wrong audience");
  if (typeof payload.exp !== "number" || payload.exp * 1000 < Date.now()) throw new Error("Expired");
  if (typeof payload.sub !== "string") throw new Error("No subject");
  return { sub: payload.sub, email: typeof payload.email === "string" ? payload.email : undefined };
}

async function appleKey(kid: string): Promise<JsonWebKey> {
  const stale = !appleKeys || Date.now() - appleKeys.fetchedAt > 6 * 3600_000;
  if (stale || !appleKeys?.keys.some((k) => k.kid === kid)) {
    const res = await fetch(appleKeysURL, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error("Couldn't reach Apple");
    appleKeys = { keys: ((await res.json()) as any).keys, fetchedAt: Date.now() };
  }
  const key = appleKeys!.keys.find((k) => k.kid === kid);
  if (!key) throw new Error("Unknown key");
  return key;
}

/** A Doorlist session: `<subject>.<expiry seconds>.<hmac>`, valid 60 days. */
export function issueSession(sub: string): string {
  if (!secret()) throw new Error("SESSION_SECRET is not set");
  const body = `${Buffer.from(sub).toString("base64url")}.${Math.floor(Date.now() / 1000) + 60 * 86_400}`;
  return `${body}.${sign(body)}`;
}

/** The subject of a valid session, or null. */
export function readSession(token: string | undefined): string | null {
  if (!token || !secret()) return null;
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  const [sub64, exp, mac] = parts as [string, string, string];
  const expected = Buffer.from(sign(`${sub64}.${exp}`));
  const given = Buffer.from(mac);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return null;
  if (Number(exp) * 1000 < Date.now()) return null;
  return Buffer.from(sub64, "base64url").toString("utf8");
}

function sign(body: string): string {
  return createHmac("sha256", secret()).update(body).digest("base64url");
}
