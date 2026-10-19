import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { after, before, describe, test } from "node:test";

// Its own Postgres schema, so these tests never touch the events a local collector run wrote.
const base = process.env.TEST_DATABASE_URL ?? "postgres://postgres:test@localhost:55432/doorlist";
Object.assign(process.env, {
  NODE_ENV: "test", APP_TOKEN: "app-token", SESSION_SECRET: "test-secret", ADMIN_TOKEN: "admin-token",
  DATABASE_URL: `${base}${base.includes("?") ? "&" : "?"}options=-c%20search_path%3Dexplore_test`,
});

const { app } = await import("../src/index.js");
const { thumbnail } = await import("../src/explore.js");
const { pool } = await import("../src/db.js");

const hour = 3600_000;
const at = (hours: number) => new Date(Date.now() + hours * hour).toISOString();

// San Francisco, San Jose (in the Bay Area, not in SF), Las Vegas, and one online.
const events = [
  { id: "luma:evt-food", title: "Sake Tasting", starts: at(5), lat: 37.78, lng: -122.41, topics: ["food"], sources: ["luma"], guests: 40,
    cover: "https://images.lumacdn.com/uploads/ab/cover.png" },
  { id: "luma:evt-hack", title: "Agents Hackathon", starts: at(24), lat: 37.77, lng: -122.42, topics: ["hackathons", "tech"], sources: ["luma", "cerebralvalley"] },
  { id: "url:https://devpost.com/sj", title: "San Jose Hacks", starts: at(48), lat: 37.33, lng: -121.89, topics: ["hackathons", "tech"], sources: ["devpost"] },
  { id: "luma:evt-vegas", title: "Fintech Breakfast", starts: at(10), lat: 36.17, lng: -115.14, topics: ["food", "tech"], sources: ["luma"] },
  { id: "url:https://lablab.ai/x", title: "Online Agents Sprint", starts: at(-240), ends: at(240), online: true, topics: ["hackathons", "tech"], sources: ["lablab"] },
  { id: "luma:evt-past", title: "Yesterday's Meetup", starts: at(-30), lat: 37.78, lng: -122.41, topics: ["tech"], sources: ["luma"] },
];

before(async () => {
  await pool.query("DROP SCHEMA IF EXISTS explore_test CASCADE; CREATE SCHEMA explore_test");
  await pool.query(readFileSync(new URL("../../collector/schema.sql", import.meta.url), "utf8"));
  await pool.query(`INSERT INTO explore_places (id, name, lat, lng, radius_km, luma_id, featured) VALUES
    ('sf', 'San Francisco', 37.7749, -122.4194, 20, 'discplace-sf', 1),
    ('bay-area', 'Bay Area', 37.60, -122.20, 80, NULL, 2),
    ('las-vegas', 'Las Vegas', 36.1699, -115.1398, 30, 'discplace-lv', 3),
    ('online', 'Online', 0, 0, 0, NULL, 11),
    ('tokyo', 'Tokyo', 35.68, 139.69, 40, 'discplace-tk', NULL)`);
  for (const e of events) {
    await pool.query(
      `INSERT INTO explore_events (id, title, title_key, starts_at, ends_at, lat, lng, online, url, sources, topics, guest_count, cover_url)
       VALUES ($1, $2, $1, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`,
      [e.id, e.title, e.starts, e.ends ?? null, e.lat ?? null, e.lng ?? null, e.online ?? false, `https://example.com/${e.id}`,
        e.sources, e.topics, e.guests ?? null, e.cover ?? null],
    );
  }
  await pool.query("INSERT INTO explore_runs (finished_at, events) VALUES (now(), 6)");
});
after(() => pool.end());

const headers = { "x-doorlist-token": "app-token", "x-doorlist-install": "install-0001" };
async function explore(query: string) {
  const res = await app.request(`/v1/explore${query}`, { headers });
  assert.equal(res.status, 200, await res.clone().text());
  return (await res.json()) as any;
}
const titles = (body: any) => body.events.map((e: any) => e.title);

describe("explore", () => {
  test("needs the app token like every other call", async () => {
    assert.equal((await app.request("/v1/explore?place=sf")).status, 401);
  });

  test("a city shows what's near it, soonest first, nothing finished", async () => {
    assert.deepEqual(titles(await explore("?place=sf")), ["Sake Tasting", "Agents Hackathon"]);
  });

  test("the Bay Area reaches San Jose; Las Vegas is its own place", async () => {
    assert.deepEqual(titles(await explore("?place=bay-area")), ["Sake Tasting", "Agents Hackathon", "San Jose Hacks"]);
    assert.deepEqual(titles(await explore("?place=las-vegas")), ["Fintech Breakfast"]);
  });

  test("topics and sources filter", async () => {
    assert.deepEqual(titles(await explore("?place=bay-area&topic=hackathons")), ["Agents Hackathon", "San Jose Hacks"]);
    assert.deepEqual(titles(await explore("?place=sf&topic=food")), ["Sake Tasting"]);
    assert.deepEqual(titles(await explore("?place=sf&source=cerebralvalley")), ["Agents Hackathon"]);
    // An unknown topic is ignored rather than returning nothing.
    assert.equal((await explore("?place=sf&topic=nonsense")).events.length, 2);
  });

  test("online is its own place, and a running hackathon still shows", async () => {
    assert.deepEqual(titles(await explore("?place=online")), ["Online Agents Sprint"]);
  });

  test("near me uses the phone's coordinates", async () => {
    assert.deepEqual(titles(await explore("?lat=37.34&lng=-121.9")), ["San Jose Hacks"]);
  });

  test("cards get a small cover where the host can make one", async () => {
    const [sake] = (await explore("?place=sf&topic=food")).events;
    assert.match(sake.image, /^https:\/\/images\.lumacdn\.com\/cdn-cgi\/image\/.*width=400.*\/uploads\/ab\/cover\.png$/);
    assert.equal(thumbnail("https://img.evbuc.com/x.jpg"), "https://img.evbuc.com/x.jpg");
    assert.deepEqual(sake.sources, ["luma"]);
  });

  test("an unknown place is a 404", async () => {
    assert.equal((await app.request("/v1/explore?place=atlantis", { headers })).status, 404);
  });

  test("meta lists featured places first, then the rest, plus topics and sources", async () => {
    const res = await app.request("/v1/explore/meta", { headers });
    const meta = (await res.json()) as any;
    assert.deepEqual(meta.places.map((p: any) => p.id), ["sf", "bay-area", "las-vegas", "online", "tokyo"]);
    assert.equal(meta.places.find((p: any) => p.id === "tokyo").featured, false);
    assert.equal(meta.topics[0].name, "Tech");
    assert.ok(meta.topics.some((t: any) => t.id === "hackathons"));
    assert.ok(meta.sources.some((s: any) => s.id === "yc"));
    assert.ok(meta.updatedAt);
  });

  test("pages of thirty", async () => {
    for (let i = 0; i < 35; i++) {
      await pool.query(
        `INSERT INTO explore_events (id, title, title_key, starts_at, lat, lng, url) VALUES ($1, $1, $1, $2, 36.17, -115.14, 'https://x.example')`,
        [`luma:evt-p${i}`, at(100 + i)],
      );
    }
    const first = await explore("?place=las-vegas");
    assert.equal(first.events.length, 30);
    const second = await explore(`?place=las-vegas&cursor=${first.next}`);
    assert.equal(second.events.length, 6);
    assert.equal(second.next, null);
  });
});
