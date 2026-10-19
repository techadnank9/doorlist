import { Sentry, sentryOn } from "./instrument.js";
import { analyticsId, shutdownAnalytics } from "./analytics.js";
import { serve } from "@hono/node-server";
import { Hono, type Context } from "hono";
import { logger } from "hono/logger";
import { stream } from "hono/streaming";
import { issueSession, readSession, verifyAppleToken } from "./auth.js";
import { config } from "./config.js";
import { mountAdmin } from "./admin.js";
import { mountExplore } from "./explore.js";
import { take } from "./limits.js";
import { Meter } from "./meter.js";
import { search, SearchError, type SearchInput } from "./search.js";
import { clean, remove, sync } from "./sync.js";
import { transcribe } from "./transcribe.js";

export const app = new Hono();
if (process.env.NODE_ENV !== "test") app.use(logger());
mountAdmin(app);

// Unexpected errors go to Sentry (when it's set up) and get a plain answer instead of a stack trace.
app.onError((error, c) => {
  if (sentryOn) Sentry.captureException(error);
  console.error(error);
  return c.json({ error: "Doorlist's server had a problem." }, 500);
});

app.get("/health", (c) =>
  c.json({ ok: true, search: Boolean(config.openAIKey), exa: Boolean(config.exaKey), voice: Boolean(config.elevenLabsKey) }),
);

/** Who is calling: a signed-in Apple user, or (before sign in) an install id. */
function caller(c: Context): string | null {
  const session = readSession(c.req.header("authorization")?.replace(/^Bearer\s+/i, ""));
  if (session) return `user:${session}`;
  const install = c.req.header("x-doorlist-install") ?? "";
  return /^[A-Za-z0-9-]{8,64}$/.test(install) ? `install:${install}` : null;
}

app.use("/v1/*", async (c, next) => {
  if (config.appToken && c.req.header("x-doorlist-token") !== config.appToken) {
    return c.json({ error: "This isn't the Doorlist app." }, 401);
  }
  await next();
});

mountExplore(app);

app.post("/v1/session", async (c) => {
  const body = await c.req.json().catch(() => null);
  if (typeof body?.identityToken !== "string") return c.json({ error: "Missing identity token." }, 400);
  try {
    const apple = await verifyAppleToken(body.identityToken);
    return c.json({ session: issueSession(apple.sub), email: apple.email ?? null, analyticsId: analyticsId(apple.sub) });
  } catch {
    return c.json({ error: "Couldn't confirm that Apple sign in." }, 401);
  }
});

app.post("/v1/search", async (c) => {
  const who = caller(c);
  if (!who) return c.json({ error: "Missing install id." }, 400);
  if (!config.openAIKey) return c.json({ error: "Search isn't set up on this server yet." }, 503);
  const input = parseSearch(await c.req.json().catch(() => null));
  if (!input) return c.json({ error: "Tell Doorlist what you want to go to." }, 400);
  if (!take(who, "search", config.searchLimit)) {
    return c.json({ error: "That's today's searches used up. More tomorrow." }, 429);
  }

  c.header("Content-Type", "application/x-ndjson");
  c.header("Cache-Control", "no-store");
  return stream(c, async (s) => {
    const send = (line: unknown) => s.write(JSON.stringify(line) + "\n");
    try {
      const result = await search(input, (stage) => void send(stage), new Meter(who, "search"));
      await send({ result });
    } catch (error) {
      const message = error instanceof SearchError ? error.message : "Search hit a snag. Try again.";
      console.error("search failed", error);
      await send({ error: message });
    }
  });
});

app.post("/v1/transcribe", async (c) => {
  const who = caller(c);
  if (!who) return c.json({ error: "Missing install id." }, 400);
  if (!config.elevenLabsKey) return c.json({ error: "Voice isn't set up on this server." }, 503);
  if (!take(who, "transcribe", config.transcribeLimit)) return c.json({ error: "Voice limit reached for today." }, 429);
  const audio = await c.req.arrayBuffer();
  if (audio.byteLength < 200 || audio.byteLength > 10_000_000) return c.json({ error: "That recording didn't come through." }, 400);
  const keyterms = (c.req.query("keyterms") ?? "").split(",").map((t) => t.trim()).filter((t) => t.length > 2);
  try {
    const text = await transcribe(audio, c.req.header("content-type") ?? "audio/mp4", keyterms);
    // The app sends the recording's length; AAC at ~32 kbps is the fallback estimate.
    const claimed = Number(c.req.header("x-audio-seconds"));
    const seconds = Number.isFinite(claimed) && claimed > 0 && claimed < 600 ? claimed : audio.byteLength / 4000;
    new Meter(who, "transcribe").voice(seconds, keyterms.length > 0);
    return c.json({ text });
  } catch (error) {
    console.error("transcribe failed", error);
    return c.json({ error: "Couldn't turn that into text." }, 502);
  }
});

/** The signed-in person's Apple id, or null. */
function userOf(c: Context): string | null {
  return readSession(c.req.header("authorization")?.replace(/^Bearer\s+/i, ""));
}

// Profile sync: the device sends its copy, gets back the merged one. Needs an account.
app.post("/v1/sync", async (c) => {
  const user = userOf(c);
  if (!user) return c.json({ error: "Sign in to keep your answers across devices." }, 401);
  const raw = await c.req.text();
  if (raw.length > 2_000_000) return c.json({ error: "That's more than Doorlist can store." }, 413);
  const profile = clean(JSON.parse(raw || "null"));
  if (!profile) return c.json({ error: "Couldn't read that profile." }, 400);
  try {
    return c.json(await sync(user, profile));
  } catch (error) {
    console.error("sync failed", error);
    return c.json({ error: "Couldn't save to your account right now." }, 503);
  }
});

// Apple requires in-app account deletion; this is what it calls.
app.delete("/v1/account", async (c) => {
  const user = userOf(c);
  if (!user) return c.json({ error: "Not signed in." }, 401);
  await remove(user);
  return c.json({ deleted: true });
});

/** Only the fields search needs, bounded so one call can't be huge. */
export function parseSearch(body: any): SearchInput | null {
  const request = typeof body?.request === "string" ? body.request.trim().slice(0, 500) : "";
  if (!request) return null;
  const str = (v: unknown, max = 120) => (typeof v === "string" && v.trim() ? v.trim().slice(0, max) : undefined);
  const clarifications = (Array.isArray(body.clarifications) ? body.clarifications : [])
    .slice(0, 5)
    .flatMap((c: any) => {
      const question = str(c?.question, 200);
      const answer = str(c?.answer, 200);
      return question && answer ? [{ question, answer }] : [];
    });
  const p = body.place ?? {};
  const place = { city: str(p.city), region: str(p.region), country: str(p.country, 2), timezone: str(p.timezone, 64) };
  const taste = (Array.isArray(body.taste) ? body.taste : []).flatMap((t: unknown) => {
    const s = str(t);
    return s ? [s] : [];
  }).slice(0, 20);
  return { request, clarifications, place, taste };
}

if (process.env.NODE_ENV !== "test") {
  serve({ fetch: app.fetch, port: config.port }, (info) => {
    console.log(`Doorlist server on http://localhost:${info.port}`);
  });
  // Render stops the old instance with SIGTERM on each deploy; send queued analytics first.
  process.once("SIGTERM", () => void shutdownAnalytics().finally(() => process.exit(0)));
}
