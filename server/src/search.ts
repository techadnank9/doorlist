import { config } from "./config.js";
import { isEventPage, normalize, platformOf, type Platform } from "./links.js";
import type { Meter } from "./meter.js";
import { verify } from "./verify.js";

export interface Place {
  city?: string;
  region?: string;
  country?: string;
  timezone?: string;
}

export interface SearchInput {
  request: string;
  clarifications?: { question: string; answer: string }[];
  place?: Place;
  /** Names of events the person booked before. */
  taste?: string[];
}

export interface FoundEvent {
  url: string;
  title: string;
  start?: string;
  end?: string;
  place?: string;
  image?: string;
  priceText?: string;
  isFree?: boolean;
  why?: string;
  match: number;
  soldOut: boolean;
  /** Its page was opened and read, and it has a date. */
  verified: boolean;
  platform: Platform;
  sources: ("openai" | "exa")[];
}

export type SearchResult = { events: FoundEvent[] } | { question: string; options: string[] };
export type Stage = { stage: "searching" } | { stage: "checking"; count: number } | { stage: "ranking" };

interface Candidate extends FoundEvent {
  snippet?: string;
}

/**
 * 1. OpenAI with web search, told where the person is, finds candidates
 *    (or asks one question when the request is too vague);
 * 2. Exa adds real event pages from Luma, Partiful, Eventbrite, Meetup and the open web;
 * 3. every page is opened and checked (date, price, sold out, cancelled);
 * 4. OpenAI ranks what survived, strictly, against the request.
 */
export async function search(input: SearchInput, emit: (s: Stage) => void, meter: Meter): Promise<SearchResult> {
  emit({ stage: "searching" });
  const ctx = context(input);
  const [model, exa] = await Promise.all([modelCandidates(input, ctx, meter), exaCandidates(input, ctx, meter)]);
  if ("question" in model) return model;

  const merged = new Map<string, Candidate>();
  for (const c of [...model.candidates, ...exa]) {
    const id = normalize(c.url);
    const existing = merged.get(id);
    if (existing) {
      existing.sources = [...new Set([...existing.sources, ...c.sources])];
      existing.snippet ??= c.snippet;
    } else {
      merged.set(id, c);
    }
  }
  const candidates = [...merged.values()].filter((c) => isEventPage(c.url)).slice(0, 14);

  emit({ stage: "checking", count: candidates.length });
  let checked = await verifyAll(candidates);
  if (checked.length === 0) return { events: [] };

  emit({ stage: "ranking" });
  try {
    checked = await rank(checked, ctx, meter);
  } catch {
    // Keep the model's own scores.
  }
  checked.sort((a, b) => b.match - a.match);
  return { events: checked.slice(0, 8).map(({ snippet: _snippet, ...e }) => e) };
}

// MARK: Context

interface Context {
  fullRequest: string;
  whereAndWhen: string;
  tasteLine: string;
}

export function context(input: SearchInput): Context {
  const tz = input.place?.timezone || "UTC";
  let now: string;
  try {
    now = new Date().toLocaleString("en-US", {
      timeZone: tz, weekday: "long", year: "numeric", month: "long", day: "numeric", hour: "numeric", minute: "2-digit",
    });
  } catch {
    now = new Date().toUTCString();
  }
  const place = [input.place?.city, input.place?.region].filter(Boolean).join(", ");
  let whereAndWhen = `Right now it is ${now} (${tz}).`;
  if (place) {
    whereAndWhen += ` The person is in ${place}${input.place?.country ? `, ${input.place.country}` : ""}. Search there unless the request names another place.`;
  }
  const taste = (input.taste ?? []).slice(0, 12);
  return {
    fullRequest: [input.request, ...(input.clarifications ?? []).map((c) => `${c.question} ${c.answer}`)].join(". "),
    whereAndWhen,
    tasteLine: taste.length ? `Events they booked before, as a hint to their taste: ${taste.join("; ")}.` : "",
  };
}

// MARK: Step 1, OpenAI web search

async function modelCandidates(
  input: SearchInput,
  ctx: Context,
  meter: Meter,
): Promise<{ candidates: Candidate[] } | { question: string; options: string[] }> {
  const asked = input.clarifications?.length
    ? `\nThey already answered: ${input.clarifications.map((c) => `"${c.question}" → "${c.answer}"`).join("; ")}.`
    : "";
  const prompt = `Find real, upcoming events for this request: "${input.request}"${asked}

${ctx.whereAndWhen}
${ctx.tasteLine}

Search widely: luma.com, partiful.com, eventbrite.com, meetup.com, cerebralvalley.ai (AI events and hackathons), venue and organiser sites, ticketing sites. Only events that haven't started. Give the direct page where someone RSVPs or gets tickets, never an article, list or search page. If the request doesn't mention paying, prefer free events. Rank by how well each fits.

If the request is too vague to search well even knowing where and when they are (no hint at all of what kind of event), don't search; reply with one short question and 3 or 4 likely answers:
{"question":"","options":["",""]}

Otherwise reply with only this JSON:
{"events":[{"title":"","url":"","start":"ISO 8601 with UTC offset or null","venue":"","city":"","price":"Free or the cheapest price","is_free":true,"why":"under 14 words, specific","match":0.0}]}
match is 0 to 1. Up to 10 events. If nothing fits, {"events":[]}.`;

  const tool: Record<string, unknown> = { type: "web_search" };
  if (input.place && (input.place.city || input.place.country)) {
    tool.user_location = { type: "approximate", ...input.place };
  }
  const json = await respond({ model: config.model, tools: [tool], input: prompt, reasoning: { effort: "medium" } }, meter);
  const object = firstJSONObject(outputText(json));
  if (!object) throw new SearchError("The search came back in a shape Doorlist couldn't read. Try again.");

  if (typeof object.question === "string" && object.question) {
    const options = (Array.isArray(object.options) ? object.options : []).filter(
      (o: unknown): o is string => typeof o === "string" && o.length > 0,
    );
    return { question: object.question, options: options.slice(0, 4) };
  }
  const items: any[] = Array.isArray(object.events) ? object.events : [];
  const candidates = items.flatMap((item): Candidate[] => {
    if (typeof item?.url !== "string" || typeof item?.title !== "string") return [];
    let host: string;
    try {
      host = new URL(item.url).hostname;
    } catch {
      return [];
    }
    const place = [item.venue, item.city].filter((s) => typeof s === "string" && s).join(", ");
    return [{
      url: item.url,
      title: item.title,
      start: typeof item.start === "string" ? item.start : undefined,
      place: place || undefined,
      priceText: typeof item.price === "string" ? item.price : undefined,
      isFree: typeof item.is_free === "boolean" ? item.is_free : undefined,
      why: typeof item.why === "string" ? item.why : undefined,
      match: typeof item.match === "number" ? item.match : 0.5,
      soldOut: false,
      verified: false,
      platform: platformOf(host),
      sources: ["openai"],
      snippet: typeof item.why === "string" ? item.why : undefined,
    }];
  });
  return { candidates };
}

// MARK: Step 2, Exa

const eventSites = ["luma.com", "lu.ma", "partiful.com", "eventbrite.com", "meetup.com", "cerebralvalley.ai"];

async function exaCandidates(input: SearchInput, ctx: Context, meter: Meter): Promise<Candidate[]> {
  if (!config.exaKey) return [];
  const near = input.place?.city ? ` in ${input.place.city}` : "";
  const query = `${ctx.fullRequest}${near} event page to RSVP or get tickets`;
  const [onSites, anywhere] = await Promise.all([
    exaSearch(query, eventSites, 12, input.place?.country, meter),
    exaSearch(query, undefined, 6, input.place?.country, meter),
  ]);
  return [...onSites, ...anywhere];
}

async function exaSearch(query: string, domains: string[] | undefined, count: number, country: string | undefined,
  meter: Meter): Promise<Candidate[]> {
  const body: Record<string, unknown> = {
    query, type: "auto", numResults: count, contents: { highlights: { maxCharacters: 400 } },
  };
  if (domains) body.includeDomains = domains;
  if (country) body.userLocation = country;
  try {
    const res = await fetch(`${config.exaBase}/search`, {
      method: "POST",
      headers: { "x-api-key": config.exaKey, "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) return [];
    const json = (await res.json()) as { results?: any[] };
    meter.exa(json);
    return (json.results ?? []).flatMap((r): Candidate[] => {
      if (typeof r?.url !== "string" || !isEventPage(r.url)) return [];
      return [{
        url: r.url,
        title: typeof r.title === "string" && r.title ? r.title : r.url,
        match: 0.5,
        soldOut: false,
        verified: false,
        platform: platformOf(new URL(r.url).hostname),
        sources: ["exa"],
        snippet: Array.isArray(r.highlights) ? r.highlights.join(" … ") : undefined,
      }];
    });
  } catch {
    return [];
  }
}

// MARK: Step 3, check every page

async function verifyAll(candidates: Candidate[]): Promise<Candidate[]> {
  const now = Date.now();
  const out: (Candidate | null)[] = new Array(candidates.length).fill(null);
  let next = 0;
  async function worker() {
    while (next < candidates.length) {
      const index = next++;
      const c: Candidate = { ...candidates[index]! };
      const result = await verify(c.url);
      if (result.kind === "dead") continue;
      if (result.kind === "ok") {
        const v = result.event;
        c.verified = Boolean(v.start);
        c.title = v.title || c.title;
        c.start = v.start ?? c.start;
        c.end = v.end ?? c.end;
        c.place = v.place ?? c.place;
        c.image = v.image ?? c.image;
        if (v.lowestPrice !== undefined) {
          c.isFree = v.lowestPrice === 0;
          c.priceText = priceText(v.lowestPrice, v.currency);
        }
        c.soldOut = v.soldOut;
      }
      const ends = Date.parse(c.end ?? c.start ?? "");
      if (Number.isFinite(ends) && ends < now) continue;
      out[index] = c;
    }
  }
  await Promise.all(Array.from({ length: 8 }, worker));
  return out.filter((c): c is Candidate => c !== null);
}

export function priceText(price: number, currency = "USD"): string {
  if (price === 0) return "Free";
  try {
    return `From ${new Intl.NumberFormat("en-US", {
      style: "currency", currency, minimumFractionDigits: Number.isInteger(price) ? 0 : 2, maximumFractionDigits: 2,
    }).format(price)}`;
  } catch {
    return `From ${price}`;
  }
}

// MARK: Step 4, rank

async function rank(events: Candidate[], ctx: Context, meter: Meter): Promise<Candidate[]> {
  const lines = events
    .map((e, i) => {
      const parts = [`${i}. ${e.title}`];
      if (e.start) parts.push(`starts ${e.start}`);
      if (e.place) parts.push(`at ${e.place}`);
      parts.push(e.priceText ?? (e.isFree ? "free" : "price unknown"));
      if (e.soldOut) parts.push("SOLD OUT");
      parts.push(`site ${new URL(e.url).hostname}`);
      if (e.snippet) parts.push(`about: ${e.snippet.slice(0, 300)}`);
      return parts.join(" | ");
    })
    .join("\n");

  const prompt = `Request: "${ctx.fullRequest}"
${ctx.whereAndWhen}
${ctx.tasteLine}

Score how well each event fits the request, 0 to 1. Be strict: wrong city, wrong day or time of day, wrong kind of event, or paid when they asked for free should score under 0.4. Sold out events score under 0.3. Only a clear, specific fit scores 0.8 or more. For each, write why in under 14 words, naming the concrete reason (the day, the topic, the place), never generic praise.

Events:
${lines}`;

  const schema = {
    type: "object", additionalProperties: false, required: ["ranked"],
    properties: {
      ranked: {
        type: "array",
        items: {
          type: "object", additionalProperties: false, required: ["i", "match", "why"],
          properties: { i: { type: "integer" }, match: { type: "number" }, why: { type: "string" } },
        },
      },
    },
  };
  const json = await respond({
    model: config.model, input: prompt, reasoning: { effort: "low" },
    text: { format: { type: "json_schema", name: "ranking", schema, strict: true } },
  }, meter);
  const object = firstJSONObject(outputText(json));
  const ranked: any[] = Array.isArray(object?.ranked) ? object.ranked : [];
  const out = events.map((e) => ({ ...e }));
  for (const item of ranked) {
    const target = Number.isInteger(item?.i) ? out[item.i] : undefined;
    if (!target) continue;
    if (typeof item.match === "number") target.match = Math.min(Math.max(item.match, 0), 1);
    if (typeof item.why === "string" && item.why) target.why = item.why;
  }
  return out;
}

// MARK: OpenAI transport

export class SearchError extends Error {}

/** POST /responses. Retries once without `reasoning` for models that don't take it. */
async function respond(body: Record<string, unknown>, meter: Meter): Promise<any> {
  const res = await fetch(`${config.openAIBase}/responses`, {
    method: "POST",
    headers: { Authorization: `Bearer ${config.openAIKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(150_000),
  });
  const json = (await res.json().catch(() => ({}))) as any;
  if (res.ok) {
    meter.openAI(json);
    return json;
  }
  const message: string = json?.error?.message ?? "";
  if (res.status === 400 && body.reasoning && /reasoning/i.test(message)) {
    const { reasoning: _reasoning, ...rest } = body;
    return respond(rest, meter);
  }
  if (res.status === 429) throw new SearchError("Search is busy right now. Try again in a minute.");
  throw new SearchError(`Search failed upstream (${res.status}).`);
}

function outputText(json: any): string {
  if (typeof json?.output_text === "string") return json.output_text;
  const items: any[] = Array.isArray(json?.output) ? json.output : [];
  return items
    .filter((i) => i?.type === "message")
    .flatMap((i) => (Array.isArray(i.content) ? i.content : []))
    .map((c: any) => (typeof c?.text === "string" ? c.text : ""))
    .join("\n");
}

export function firstJSONObject(text: string): any | null {
  const open = text.indexOf("{");
  const close = text.lastIndexOf("}");
  if (open < 0 || close <= open) return null;
  try {
    return JSON.parse(text.slice(open, close + 1));
  } catch {
    return null;
  }
}
