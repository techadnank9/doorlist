import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";
import { serve, type ServerType } from "@hono/node-server";

// Everything points at the local mock; set before the server modules load.
const mockPort = 8791;
const base = `http://localhost:${mockPort}`;
Object.assign(process.env, {
  NODE_ENV: "test",
  MOCK_PUBLIC_BASE: base,
  OPENAI_API_KEY: "test", EXA_API_KEY: "test", ELEVENLABS_API_KEY: "test",
  OPENAI_BASE_URL: `${base}/openai`, EXA_BASE_URL: `${base}/exa`, ELEVENLABS_BASE_URL: `${base}/elevenlabs`,
  APP_TOKEN: "app-token", SESSION_SECRET: "test-secret", ADMIN_TOKEN: "admin-token",
  // A throwaway Postgres: docker run -d -p 55432:5432 -e POSTGRES_PASSWORD=test -e POSTGRES_DB=doorlist postgres:17-alpine
  DATABASE_URL: process.env.TEST_DATABASE_URL ?? "postgres://postgres:test@localhost:55432/doorlist",
  SEARCH_LIMIT_PER_DAY: "3",
});

const { mock } = await import("./mock.js");
const { app, parseSearch } = await import("../src/index.js");
const { isEventPage, lumaReference, normalize } = await import("../src/links.js");
const { parseEventHTML } = await import("../src/verify.js");
const { Meter, summary, flushUsage } = await import("../src/meter.js");
const { pool } = await import("../src/db.js");
const { merge } = await import("../src/sync.js");
const { issueSession, readSession } = await import("../src/auth.js");

let mockServer: ServerType;
before(async () => {
  mockServer = serve({ fetch: mock.fetch, port: mockPort });
  await pool.query("DROP TABLE IF EXISTS profiles, usage");
});
after(async () => {
  mockServer.close();
  await flushUsage();
  await pool.end();
});

const headers = (install = "install-0001") => ({
  "content-type": "application/json", "x-doorlist-token": "app-token", "x-doorlist-install": install,
});

async function searchLines(request: string, install: string, extra: Record<string, unknown> = {}) {
  const res = await app.request("/v1/search", {
    method: "POST", headers: headers(install),
    body: JSON.stringify({ request, place: { city: "San Francisco", region: "CA", country: "US", timezone: "America/Los_Angeles" }, ...extra }),
  });
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("content-type"), "application/x-ndjson");
  return (await res.text()).trim().split("\n").map((l) => JSON.parse(l));
}

describe("links", () => {
  test("tells event pages from listing pages", () => {
    assert.ok(isEventPage("https://luma.com/abc123"));
    assert.ok(!isEventPage("https://luma.com/discover"));
    assert.ok(isEventPage("https://partiful.com/e/0vfKni2xUyBThQFRrvJD"));
    assert.ok(!isEventPage("https://partiful.com/explore/sf"));
    assert.ok(isEventPage("https://www.eventbrite.com/e/astronomy-night-tickets-2002837309307"));
    assert.ok(!isEventPage("https://www.eventbrite.com/d/ca--san-francisco/free--events/"));
    assert.ok(isEventPage("https://www.meetup.com/sf-go/events/312345678/"));
    assert.ok(!isEventPage("https://www.meetup.com/sf-go/"));
    assert.ok(isEventPage("https://cerebralvalley.ai/e/meta-ai-developer-hackathon?utm_source=cv-events"));
    assert.ok(!isEventPage("https://cerebralvalley.ai/events"));
    assert.ok(!isEventPage("https://cerebralvalley.ai/e/events"));
    assert.ok(!isEventPage("https://cerebralvalley.ai/events/remote"));
  });

  test("normalizes the same event to one key", () => {
    assert.equal(normalize("https://www.Eventbrite.com/e/x-tickets-1/?aff=abc#top"), "https://eventbrite.com/e/x-tickets-1");
    assert.equal(normalize("https://lu.ma/abc"), "https://luma.com/abc");
    assert.equal(lumaReference("https://luma.com/e/abc"), "abc");
  });
});

describe("page checks", () => {
  test("reads a Partiful page: a free tier among paid ones counts as free", () => {
    const v = parseEventHTML(readFileSync(new URL("./fixtures/partiful-event.html", import.meta.url), "utf8"));
    assert.ok(v && v !== "cancelled");
    assert.equal(v.lowestPrice, 0);
    assert.equal(v.start, "2099-12-13T19:00:00.000Z");
    assert.equal(v.place, "724 Example Ave, San Francisco");
  });

  test("reads an Eventbrite page through its other JSON-LD blocks", () => {
    const v = parseEventHTML(readFileSync(new URL("./fixtures/eventbrite-event.html", import.meta.url), "utf8"));
    assert.ok(v && v !== "cancelled");
    assert.equal(v.title, "Astronomy Night");
    assert.equal(v.lowestPrice, 0);
    assert.equal(v.soldOut, false);
  });

  test("reads a Cerebral Valley hackathon, typed as both Event and Hackathon", () => {
    const page = `<script type="application/ld+json">${JSON.stringify({ "@context": "https://schema.org", "@type": "WebSite", name: "Cerebral Valley" })}</script>
      <script type="application/ld+json">${JSON.stringify({ "@type": ["Event", "Hackathon"], name: "Agents Hackathon",
        startDate: "2099-10-23T15:00:00.000Z", isAccessibleForFree: true, location: { "@type": "Place", name: "Shack15", address: { addressLocality: "San Francisco" } } })}</script>`;
    const v = parseEventHTML(page);
    assert.ok(v && v !== "cancelled");
    assert.equal(v.title, "Agents Hackathon");
    assert.equal(v.lowestPrice, 0);
    assert.equal(v.place, "Shack15, San Francisco");
  });

  test("cancelled and sold out events are recognised", () => {
    const page = (extra: object) => `<script type="application/ld+json">${JSON.stringify({ "@type": "Event", name: "x", startDate: "2099-01-01", ...extra })}</script>`;
    assert.equal(parseEventHTML(page({ eventStatus: "https://schema.org/EventCancelled" })), "cancelled");
    const sold = parseEventHTML(page({ offers: { price: 0, availability: "https://schema.org/SoldOut" } }));
    assert.ok(sold && sold !== "cancelled" && sold.soldOut);
  });
});

describe("input limits", () => {
  test("keeps only what search needs, bounded", () => {
    const parsed = parseSearch({ request: "  x".padEnd(900, "y"), taste: Array(50).fill("t"), place: { country: "USA" }, junk: 1 });
    assert.ok(parsed);
    assert.equal(parsed.request.length, 500);
    assert.equal(parsed.taste?.length, 20);
    assert.equal(parsed.place?.country, "US");
    assert.equal(parseSearch({ request: "   " }), null);
  });
});

describe("sessions", () => {
  test("round trip, and tampering fails", () => {
    const token = issueSession("001234.apple.sub");
    assert.equal(readSession(token), "001234.apple.sub");
    assert.equal(readSession(token.slice(0, -2) + "xx"), null);
    assert.equal(readSession("nonsense"), null);
  });
});

describe("cost meter", () => {
  test("prices an OpenAI call from its own usage numbers", () => {
    const m = new Meter("install:meter-test", "search");
    m.openAI({
      usage: { input_tokens: 4200, input_tokens_details: { cached_tokens: 1200 }, output_tokens: 650 },
      output: [{ type: "web_search_call" }, { type: "web_search_call" }, { type: "message" }],
    });
    // (3000 × $10 + 1200 × $1 + 650 × $50) / 1M + 2 searches × $10/1k
    assert.ok(Math.abs(m.total - 0.0837) < 1e-9, `got ${m.total}`);
  });

  test("prices voice by the hour of audio", () => {
    const m = new Meter("install:meter-test", "transcribe");
    m.voice(3600, true);
    assert.ok(Math.abs(m.total - 0.27) < 1e-9);
  });
});

describe("POST /v1/search", () => {
  test("rejects calls that aren't from the app", async () => {
    const res = await app.request("/v1/search", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" });
    assert.equal(res.status, 401);
    const missing = await app.request("/v1/search", {
      method: "POST", headers: { "content-type": "application/json", "x-doorlist-token": "app-token" }, body: '{"request":"x"}',
    });
    assert.equal(missing.status, 400);
  });

  test("streams stages, drops dead links, merges Exa duplicates, ranks", async () => {
    const lines = await searchLines("rooftop party saturday", "install-search-1");
    assert.deepEqual(lines.slice(0, 3).map((l) => l.stage), ["searching", "checking", "ranking"]);
    const { events } = lines.at(-1).result;
    const titles = events.map((e: any) => e.title);
    assert.equal(titles[0], "Rooftop Social on Valencia");
    assert.ok(!titles.includes("Old Event That Moved"), "404 page was dropped");
    assert.equal(titles.filter((t: string) => t === "AI Builders Night").length, 1, "Exa duplicate merged");
    assert.ok(!titles.some((t: string) => t.includes("blog")), "non-event page dropped");

    const top = events[0];
    assert.equal(top.verified, true);
    assert.equal(top.isFree, true);
    assert.ok(top.match >= 0.9);
    const gala = events.find((e: any) => e.title === "Winter Gala");
    assert.equal(gala.isFree, false);
    assert.equal(gala.priceText, "From $45");
    const ai = events.find((e: any) => e.title === "AI Builders Night");
    assert.deepEqual([...ai.sources].sort(), ["exa", "openai"]);
  });

  test("asks one question when the request is too vague, then searches with the answer", async () => {
    const first = await searchLines("something", "install-search-2");
    assert.equal(first.at(-1).result.question, "What kind of thing are you in the mood for?");
    assert.equal(first.at(-1).result.options.length, 4);
    const second = await searchLines("something", "install-search-2", {
      clarifications: [{ question: "What kind of thing are you in the mood for?", answer: "A party" }],
    });
    assert.ok(second.at(-1).result.events.length > 0);
  });

  test("a reconnect with the same request id joins that search instead of running another", async () => {
    // The daily cap in tests is 3; four calls with one id must count as one search.
    for (let i = 0; i < 4; i++) {
      const lines = await searchLines("rooftop party saturday", "install-resume", { requestId: "resume-0000-0001" });
      assert.ok(lines.at(-1).result.events.length > 0, `call ${i + 1} got the result`);
    }
    const other = await app.request("/v1/search", {
      method: "POST", headers: headers("install-other"), body: JSON.stringify({ request: "x", requestId: "resume-0000-0001" }),
    });
    assert.equal(other.status, 200, "another install with the same id starts its own search");
  });

  test("caps searches per install per day", async () => {
    for (let i = 0; i < 3; i++) await searchLines("rooftop party", "install-limit");
    const res = await app.request("/v1/search", { method: "POST", headers: headers("install-limit"), body: '{"request":"one more"}' });
    assert.equal(res.status, 429);
  });
});

describe("POST /v1/transcribe", () => {
  test("turns a recording into text through ElevenLabs", async () => {
    const audio = new Uint8Array(8000).fill(7);
    const res = await app.request("/v1/transcribe?keyterms=bringing,dumplings", {
      method: "POST", headers: { ...headers("install-voice"), "content-type": "audio/mp4", "x-audio-seconds": "12" }, body: audio,
    });
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { text: "I'm bringing homemade dumplings." });
  });
});

describe("/admin", () => {
  test("hidden without the token, live summary with it", async () => {
    assert.equal((await app.request("/admin")).status, 404);
    assert.equal((await app.request("/admin/summary.json")).status, 404);
    const login = await app.request("/admin?token=admin-token");
    assert.equal(login.status, 302);
    const setCookie = login.headers.get("set-cookie")!;
    assert.match(setCookie, /HttpOnly/);
    const cookie = setCookie.split(";")[0]!;
    const page = await app.request("/admin", { headers: { cookie } });
    assert.equal(page.status, 200);
    assert.match(await page.text(), /What Doorlist costs/);

    await flushUsage();
    const s = await summary();
    assert.ok(s.totals.searches >= 6, `searches ${s.totals.searches}`);
    assert.ok(s.totals.last30 > 0);
    assert.ok(s.totals.byProvider.exa > 0 && s.totals.byProvider.elevenlabs > 0);
    const voice = s.people.find((p) => p.who === "install:install-voice");
    assert.ok(voice && Math.abs(voice.voiceMinutes - 0.2) < 1e-9);
    const one = s.people.find((p) => p.who === "install:install-search-1");
    assert.equal(one?.searches, 1, "one search counts once though it made several upstream calls");
  });
});

describe("profile sync", () => {
  const answer = (value: string, updatedAt: string, extra = {}) => ({ label: "Company", value, updatedAt, ...extra });

  test("merge: newer edit wins per answer, bookings from both phones are kept", () => {
    const phone = { answers: { company: answer("Acme", "2026-10-01T00:00:00Z"), dietary: answer("Vegan", "2026-10-02T00:00:00Z") },
      history: [{ id: "a", eventName: "A", bookedAt: "2026-10-01T00:00:00Z" }], prefs: {} };
    const ipad = { answers: { company: answer("Example Labs", "2026-10-05T00:00:00Z") },
      history: [{ id: "b", eventName: "B", bookedAt: "2026-10-03T00:00:00Z" }], prefs: { autoAgree: true, updatedAt: "2026-10-03T00:00:00Z" } };
    const m = merge(phone, ipad);
    assert.equal(m.answers.company?.value, "Example Labs");
    assert.equal(m.answers.dietary?.value, "Vegan");
    assert.deepEqual(m.history.map((h) => h.id), ["b", "a"]);
    assert.equal(m.prefs.autoAgree, true);
  });

  const call = (method: string, path: string, token?: string, body?: unknown) =>
    app.request(path, {
      method,
      headers: { ...headers("install-sync"), ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });

  test("a new phone gets everything back, a forgotten answer stays forgotten, delete wipes it", async () => {
    assert.equal((await call("POST", "/v1/sync", undefined, { answers: {} })).status, 401, "needs an account");
    const token = issueSession("apple-user-sync");

    const first = await call("POST", "/v1/sync", token, {
      answers: { email: { label: "Email", value: "sam@example.com", updatedAt: "2026-10-01T00:00:00Z" },
        company: answer("Example Labs", "2026-10-01T00:00:00Z") },
      history: [{ id: "evt-1", eventName: "AI Builders Night", bookedAt: "2026-10-01T00:00:00Z", status: "approved" }],
      prefs: { autoAgree: true, updatedAt: "2026-10-01T00:00:00Z" },
    });
    assert.equal(first.status, 200);

    // A brand new phone sends nothing and receives the lot.
    const fresh = await (await call("POST", "/v1/sync", token, { answers: {}, history: [], prefs: {} })).json() as any;
    assert.equal(fresh.answers.email.value, "sam@example.com");
    assert.equal(fresh.history[0].eventName, "AI Builders Night");
    assert.equal(fresh.prefs.autoAgree, true);

    // Forgotten on one phone: the marker wins over the older copy.
    const after = await (await call("POST", "/v1/sync", token, {
      answers: { company: answer("", "2026-10-09T00:00:00Z", { deleted: true }) }, history: [], prefs: {},
    })).json() as any;
    assert.equal(after.answers.company.deleted, true);

    // Stored as readable JSON, as asked.
    const { rows } = await pool.query("SELECT data->'answers'->'email'->>'value' AS email FROM profiles WHERE user_id = $1", ["apple-user-sync"]);
    assert.equal(rows[0].email, "sam@example.com");

    assert.equal((await call("DELETE", "/v1/account", token)).status, 200);
    const gone = await (await call("POST", "/v1/sync", token, { answers: {}, history: [], prefs: {} })).json() as any;
    assert.deepEqual(gone.answers, {});
  });
});
