import { config } from "./config.js";
import { lumaReference } from "./links.js";

/** What an event page itself says. */
export interface Verified {
  title?: string;
  start?: string;
  end?: string;
  place?: string;
  image?: string;
  /** Cheapest ticket; 0 means a free option exists. */
  lowestPrice?: number;
  currency?: string;
  soldOut: boolean;
}

export type VerifyResult = { kind: "ok"; event: Verified } | { kind: "dead" } | { kind: "unknown" };

const SAFARI =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

/**
 * Opens the page and reads its real details: Luma through its public event
 * endpoint, everything else from the schema.org Event data event sites
 * publish for search engines (Partiful and Eventbrite both do).
 */
export async function verify(url: string): Promise<VerifyResult> {
  const ref = lumaReference(url);
  if (ref) return verifyLuma(ref);
  return verifyPage(url);
}

async function verifyLuma(ref: string): Promise<VerifyResult> {
  const endpoint = ref.startsWith("evt-")
    ? `${config.lumaBase}/event/get?event_api_id=${encodeURIComponent(ref)}`
    : `${config.lumaBase}/url?url=${encodeURIComponent(ref)}`;
  let res: Response;
  try {
    res = await fetch(endpoint, {
      headers: { Accept: "application/json", "x-luma-client-type": "luma-web", "User-Agent": SAFARI },
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    return { kind: "unknown" };
  }
  if (res.status === 404) return { kind: "dead" };
  if (!res.ok) return { kind: "unknown" };
  const root = (await res.json().catch(() => null)) as Record<string, any> | null;
  if (!root) return { kind: "unknown" };
  // Calendars and profiles come back as other kinds; only events count.
  if (root.kind && root.kind !== "event") return { kind: "dead" };
  const data = root.data ?? root;
  const event = data.event;
  if (!event) return { kind: "dead" };
  const types = ((data.ticket_types ?? []) as any[]).filter((t) => !t.is_hidden && !t.is_disabled);
  let lowest: number;
  if (types.length === 0) lowest = 0;
  else if (types.some((t) => (t.cents ?? 0) === 0 && !t.is_flexible)) lowest = 0;
  else lowest = Math.min(...types.map((t) => (t.cents ?? 0) / 100));
  const geo = event.geo_address_info ?? {};
  return {
    kind: "ok",
    event: {
      title: event.name,
      start: event.start_at ?? undefined,
      end: event.end_at ?? undefined,
      place: geo.city_state ?? geo.city ?? undefined,
      image: event.cover_url ?? undefined,
      lowestPrice: lowest,
      currency: types.find((t) => t.currency)?.currency?.toUpperCase(),
      soldOut: data.sold_out === true && data.waitlist_active !== true,
    },
  };
}

async function verifyPage(url: string): Promise<VerifyResult> {
  let res: Response;
  try {
    res = await fetch(url, {
      headers: { "User-Agent": SAFARI, Accept: "text/html" },
      redirect: "follow",
      signal: AbortSignal.timeout(8000),
    });
  } catch {
    return { kind: "unknown" };
  }
  if (res.status === 404 || res.status === 410) return { kind: "dead" };
  if (!res.ok) return { kind: "unknown" };
  const html = (await res.text()).slice(0, 2_000_000);
  const event = parseEventHTML(html);
  if (event === "cancelled") return { kind: "dead" };
  if (!event) return { kind: "unknown" };
  event.title ??= meta("og:title", html)?.replace(/\s*\|\s*(Partiful|Eventbrite)\s*$/, "");
  event.image ??= meta("og:image", html);
  return { kind: "ok", event };
}

/** The first schema.org Event in the page's JSON-LD, "cancelled", or null. */
export function parseEventHTML(html: string): Verified | "cancelled" | null {
  const blocks = html.matchAll(/<script[^>]*application\/ld\+json[^>]*>([\s\S]*?)<\/script>/gi);
  for (const block of blocks) {
    let json: unknown;
    try {
      json = JSON.parse(block[1] ?? "");
    } catch {
      continue;
    }
    const e = findEvent(json);
    if (e) return readEvent(e);
  }
  return null;
}

function findEvent(value: unknown): Record<string, any> | null {
  if (Array.isArray(value)) {
    for (const item of value) {
      const e = findEvent(item);
      if (e) return e;
    }
  } else if (value && typeof value === "object") {
    const dict = value as Record<string, any>;
    const types = ([] as unknown[]).concat(dict["@type"] ?? []);
    if (types.some((t) => typeof t === "string" && t.endsWith("Event"))) return dict;
    if (dict["@graph"]) return findEvent(dict["@graph"]);
  }
  return null;
}

function readEvent(e: Record<string, any>): Verified | "cancelled" {
  const status = String(e.eventStatus ?? "").toLowerCase();
  if (status.includes("cancelled") || status.includes("canceled")) return "cancelled";
  const v: Verified = { soldOut: false };
  if (typeof e.name === "string") v.title = decode(e.name);
  if (typeof e.startDate === "string") v.start = e.startDate;
  if (typeof e.endDate === "string") v.end = e.endDate;
  const image = Array.isArray(e.image) ? e.image[0] : e.image;
  v.image = typeof image === "string" ? image : image?.url;

  const loc = Array.isArray(e.location) ? e.location[0] : e.location;
  if (loc && typeof loc === "object") {
    if (loc["@type"] === "VirtualLocation") v.place = "Online";
    else {
      const city = loc.address?.addressLocality;
      const name = loc.name;
      v.place = name && city && !String(name).includes(city) ? `${name}, ${city}` : (name ?? city);
    }
  }

  const offers: any[] = Array.isArray(e.offers) ? e.offers : e.offers ? [e.offers] : [];
  const prices: number[] = [];
  let available = 0;
  for (const offer of offers) {
    for (const key of ["price", "lowPrice"]) {
      const raw = offer?.[key];
      if (raw === undefined || raw === null || raw === "") continue;
      const n = Number(String(raw).replace(/,/g, ""));
      if (Number.isFinite(n)) prices.push(n);
    }
    v.currency ??= offer?.priceCurrency;
    if (!String(offer?.availability ?? "").toLowerCase().includes("soldout")) available++;
  }
  if (e.isAccessibleForFree === true) prices.push(0);
  if (prices.length) v.lowestPrice = Math.min(...prices);
  v.soldOut = offers.length > 0 && available === 0;
  return v;
}

function meta(property: string, html: string): string | undefined {
  const escaped = property.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const m = html.match(new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]*content=["']([^"']*)["']`, "i"));
  return m?.[1] ? decode(m[1]) : undefined;
}

function decode(s: string): string {
  return s
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}
