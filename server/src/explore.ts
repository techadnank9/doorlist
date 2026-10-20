import type { Hono } from "hono";
import { pool } from "./db.js";

/**
 * Explore: events near a place, by topic and source. The Python collector (../collector) fills
 * explore_events and explore_places every hour; this file only reads them, so a phone never waits
 * on, or adds load to, Luma or any other site.
 */

// Labels for the chips. Keep the ids in step with TOPICS and SOURCES in collector/doorlist_collector/model.py.
export const TOPICS = [
  ["tech", "Tech"], ["hackathons", "Hackathons"], ["food", "Food & Drink"], ["arts", "Arts"],
  ["fitness", "Fitness"], ["wellness", "Wellness"], ["climate", "Climate"], ["crypto", "Crypto"],
  ["books", "Books"], ["games", "Games"], ["family", "Family"],
] as const;
export const SOURCES = [
  ["luma", "Luma"], ["cerebralvalley", "Cerebral Valley"], ["yc", "Y Combinator"], ["devpost", "Devpost"],
  ["mlh", "MLH"], ["lablab", "lablab.ai"], ["devfolio", "Devfolio"], ["partiful", "Partiful"],
  ["eventbrite", "Eventbrite"], ["meetup", "Meetup"], ["allevents", "AllEvents"], ["funcheap", "Funcheap"],
] as const;
const topicIds = new Set<string>(TOPICS.map(([id]) => id));
const sourceIds = new Set<string>(SOURCES.map(([id]) => id));

const PAGE = 30;
// About what Luma counts as "Nearby": from San Francisco it reaches Palo Alto and Walnut Creek.
const NEAR_ME_KM = 60;

/** A smaller copy of the cover where the image host can make one. Luma's covers are often 2 MB PNGs. */
export function thumbnail(url: string | null, size = 400): string | null {
  if (!url) return null;
  const luma = url.match(/^https:\/\/images\.lumacdn\.com\/(?!cdn-cgi\/)(.+)$/);
  if (luma) return `https://images.lumacdn.com/cdn-cgi/image/format=auto,fit=cover,dpr=2,quality=75,width=${size},height=${size}/${luma[1]}`;
  return url;
}

type Where = { lat: number; lng: number; radiusKm: number } | "online";

async function resolvePlace(query: Record<string, string | undefined>): Promise<Where | null> {
  const lat = Number(query.lat), lng = Number(query.lng);
  if (query.lat && query.lng && Math.abs(lat) <= 90 && Math.abs(lng) <= 180) return { lat, lng, radiusKm: NEAR_ME_KM };
  const id = (query.place ?? "sf").slice(0, 64);
  if (id === "online") return "online";
  const { rows } = await pool.query("SELECT lat, lng, radius_km FROM explore_places WHERE id = $1", [id]);
  return rows[0] ? { lat: rows[0].lat, lng: rows[0].lng, radiusKm: rows[0].radius_km } : null;
}

export function mountExplore(app: Hono) {
  app.get("/v1/explore/meta", async (c) => {
    try {
      const places = await pool.query(
        "SELECT id, name, lat, lng, radius_km, featured FROM explore_places ORDER BY featured NULLS LAST, name",
      );
      const run = await pool.query("SELECT max(finished_at) AS at FROM explore_runs WHERE error IS NULL");
      c.header("Cache-Control", "public, max-age=600");
      return c.json({
        places: places.rows.map((p) => ({ id: p.id, name: p.name, lat: p.lat, lng: p.lng, radiusKm: p.radius_km, featured: p.featured !== null })),
        topics: TOPICS.map(([id, name]) => ({ id, name })),
        sources: SOURCES.map(([id, name]) => ({ id, name })),
        updatedAt: run.rows[0]?.at ?? null,
      });
    } catch (error) {
      if ((error as { code?: string }).code === "42P01") return c.json({ places: [], topics: [], sources: [], updatedAt: null });
      throw error;
    }
  });

  app.get("/v1/explore", async (c) => {
    const query = c.req.query();
    const topic = query.topic && topicIds.has(query.topic) ? query.topic : null;
    const source = query.source && sourceIds.has(query.source) ? query.source : null;
    const offset = Math.min(Math.max(Number(query.cursor) || 0, 0), 2000);
    let where: Where | null;
    try {
      where = await resolvePlace(query);
    } catch (error) {
      if ((error as { code?: string }).code === "42P01") return c.json({ events: [], next: null });
      throw error;
    }
    if (!where) return c.json({ error: "Doorlist doesn't know that place." }, 404);

    const params: unknown[] = [];
    const add = (value: unknown) => (params.push(value), `$${params.length}`);
    // Not over yet: still running, or starting later. Events without an end count as three hours long.
    const clauses = ["coalesce(ends_at, starts_at + interval '3 hours') > now()"];
    if (where === "online") {
      clauses.push("online");
    } else {
      const lat = add(where.lat), lng = add(where.lng), km = add(where.radiusKm);
      clauses.push("NOT online", "lat IS NOT NULL",
        // A cheap box first (uses the lat index), then the true distance.
        `lat BETWEEN ${lat} - ${km} / 111.0 AND ${lat} + ${km} / 111.0`,
        `6371 * acos(least(1, cos(radians(${lat})) * cos(radians(lat)) * cos(radians(lng) - radians(${lng}))
           + sin(radians(${lat})) * sin(radians(lat)))) <= ${km}`);
    }
    if (topic) clauses.push(`topics @> ARRAY[${add(topic)}]::text[]`);
    if (source) clauses.push(`sources @> ARRAY[${add(source)}]::text[]`);

    const { rows } = await pool.query(
      `SELECT id, title, starts_at, ends_at, all_day, timezone, city, lat, lng, online, url, sources, cover_url,
              is_free, sold_out, guest_count, topics, left(description, 1200) AS description
         FROM explore_events WHERE ${clauses.join(" AND ")}
         -- Running now sorts as now, so a month-long online hackathon doesn't sit above tonight's events forever.
         ORDER BY greatest(starts_at, now()), guest_count DESC NULLS LAST, id
         LIMIT ${PAGE + 1} OFFSET ${add(offset)}`,
      params,
    );
    c.header("Cache-Control", "public, max-age=120");
    return c.json({
      events: rows.slice(0, PAGE).map((e) => ({
        id: e.id, title: e.title, startsAt: e.starts_at, endsAt: e.ends_at, allDay: e.all_day, timezone: e.timezone,
        city: e.city, lat: e.lat, lng: e.lng, online: e.online, url: e.url, sources: e.sources,
        image: thumbnail(e.cover_url), isFree: e.is_free, soldOut: e.sold_out, guests: e.guest_count, topics: e.topics,
        description: e.description ?? null,
      })),
      next: rows.length > PAGE ? String(offset + PAGE) : null,
    });
  });
}
