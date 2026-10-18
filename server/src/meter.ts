import { randomUUID } from "node:crypto";
import { migrate, pool } from "./db.js";

/**
 * What each person costs us, from the usage numbers the providers already
 * return (OpenAI tokens and web searches, Exa's own dollar figure, seconds of
 * audio for ElevenLabs). No extra calls; one small insert per upstream call, never awaited.
 */

const num = (name: string, fallback: number) => {
  const raw = process.env[name];
  const v = Number(raw);
  return raw !== undefined && raw !== "" && Number.isFinite(v) ? v : fallback;
};

/** USD. Defaults are list prices as of Oct 2026; override in .env when they change. */
export const prices = {
  inputPerMTok: num("PRICE_OPENAI_INPUT_PER_MTOK", 10),
  cachedPerMTok: num("PRICE_OPENAI_CACHED_PER_MTOK", 1),
  outputPerMTok: num("PRICE_OPENAI_OUTPUT_PER_MTOK", 50),
  webSearchPer1k: num("PRICE_OPENAI_WEB_SEARCH_PER_1K", 10),
  scribePerHour: num("PRICE_SCRIBE_PER_HOUR", 0.22),
  keytermsPerHour: num("PRICE_SCRIBE_KEYTERMS_PER_HOUR", 0.05),
};

export interface UsageRow {
  ts: number;
  req: string;
  who: string;
  kind: "search" | "transcribe";
  provider: "openai" | "exa" | "elevenlabs";
  inputTokens: number;
  cachedTokens: number;
  outputTokens: number;
  webSearches: number;
  audioSeconds: number;
  cost: number;
}

/** Live feed for the dashboard: each row is pushed the moment it's written. */
export const listeners = new Set<(row: UsageRow) => void>();

/** Rows still being written; tests and shutdown can wait on them. */
const pending = new Set<Promise<unknown>>();

function record(row: UsageRow) {
  const write = migrate()
    .then(() => pool.query(
      `INSERT INTO usage (ts, req, who, kind, provider, input_tokens, cached_tokens, output_tokens, web_searches,
        audio_seconds, cost_usd) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
      [row.ts, row.req, row.who, row.kind, row.provider, row.inputTokens, row.cachedTokens, row.outputTokens,
        row.webSearches, row.audioSeconds, row.cost],
    ))
    .catch((error) => console.error("usage write failed", error))
    .finally(() => pending.delete(write));
  pending.add(write);
  for (const listener of listeners) listener(row);
}

export async function flushUsage() {
  await Promise.all([...pending]);
}

/** One person's one request; each upstream call it makes adds a row. */
export class Meter {
  readonly req = randomUUID();
  total = 0;
  constructor(readonly who: string, readonly kind: UsageRow["kind"]) {}

  private add(partial: Partial<UsageRow> & Pick<UsageRow, "provider" | "cost">) {
    const row: UsageRow = {
      ts: Date.now(), req: this.req, who: this.who, kind: this.kind, inputTokens: 0, cachedTokens: 0,
      outputTokens: 0, webSearches: 0, audioSeconds: 0, ...partial,
    };
    this.total += row.cost;
    record(row);
  }

  /** From a Responses API reply's `usage` and its web_search_call items. */
  openAI(json: any) {
    const usage = json?.usage ?? {};
    const input = Number(usage.input_tokens ?? 0) || 0;
    const cached = Number(usage.input_tokens_details?.cached_tokens ?? 0) || 0;
    const output = Number(usage.output_tokens ?? 0) || 0;
    const searches = (Array.isArray(json?.output) ? json.output : []).filter((o: any) => o?.type === "web_search_call").length;
    const cost = ((input - cached) * prices.inputPerMTok + cached * prices.cachedPerMTok + output * prices.outputPerMTok) / 1e6
      + (searches * prices.webSearchPer1k) / 1000;
    this.add({ provider: "openai", inputTokens: input, cachedTokens: cached, outputTokens: output, webSearches: searches, cost });
  }

  /** Exa reports its own cost on every response. */
  exa(json: any) {
    const cost = Number(json?.costDollars?.total ?? 0);
    this.add({ provider: "exa", cost: Number.isFinite(cost) ? cost : 0 });
  }

  voice(seconds: number, usedKeyterms: boolean) {
    const hours = Math.max(seconds, 0) / 3600;
    const cost = hours * (prices.scribePerHour + (usedKeyterms ? prices.keytermsPerHour : 0));
    this.add({ provider: "elevenlabs", audioSeconds: seconds, cost });
  }
}

// MARK: Reading it back

export interface PersonSummary {
  who: string;
  searches: number;
  voiceMinutes: number;
  today: number;
  last30: number;
  perSearch: number;
  lastSeen: number;
}

export async function summary() {
  await migrate();
  const now = Date.now();
  const dayStart = Date.parse(new Date().toISOString().slice(0, 10));
  const monthAgo = now - 30 * 86_400_000;

  const { rows: [totals = {}] } = await pool.query(`SELECT
      COALESCE(SUM(CASE WHEN ts >= $1 THEN cost_usd END), 0) AS today,
      COALESCE(SUM(cost_usd), 0) AS last30,
      COUNT(DISTINCT who) AS people,
      COUNT(DISTINCT CASE WHEN kind = 'search' THEN req END) AS searches,
      COALESCE(SUM(CASE WHEN kind = 'search' THEN cost_usd END), 0) AS search_cost,
      COALESCE(SUM(CASE WHEN provider = 'openai' THEN cost_usd END), 0) AS openai,
      COALESCE(SUM(CASE WHEN provider = 'exa' THEN cost_usd END), 0) AS exa,
      COALESCE(SUM(CASE WHEN provider = 'elevenlabs' THEN cost_usd END), 0) AS elevenlabs,
      MIN(ts) AS first
    FROM usage WHERE ts >= $2`, [dayStart, monthAgo]);

  const { rows: people } = await pool.query(`SELECT who,
      COUNT(DISTINCT CASE WHEN kind = 'search' THEN req END) AS searches,
      COALESCE(SUM(audio_seconds), 0) / 60.0 AS voice_minutes,
      COALESCE(SUM(CASE WHEN ts >= $1 THEN cost_usd END), 0) AS today,
      COALESCE(SUM(cost_usd), 0) AS last30,
      COALESCE(SUM(CASE WHEN kind = 'search' THEN cost_usd END), 0) AS search_cost,
      MAX(ts) AS last_seen
    FROM usage WHERE ts >= $2 GROUP BY who ORDER BY last30 DESC LIMIT 200`, [dayStart, monthAgo]);

  const { rows: recent } = await pool.query(`SELECT ts, who, kind, provider, input_tokens, output_tokens, web_searches,
      audio_seconds, cost_usd FROM usage ORDER BY ts DESC LIMIT 25`);

  const n = (v: unknown) => Number(v ?? 0) || 0;
  const last30 = n(totals.last30);
  const searches = n(totals.searches);
  const daysRunning = Math.max(1, Math.min(30, (now - (n(totals.first) || now)) / 86_400_000));

  return {
    prices,
    totals: {
      today: n(totals.today),
      last30,
      people: n(totals.people),
      searches,
      perSearch: searches ? n(totals.search_cost) / searches : 0,
      projectedMonth: (last30 / daysRunning) * 30,
      byProvider: { openai: n(totals.openai), exa: n(totals.exa), elevenlabs: n(totals.elevenlabs) },
    },
    people: people.map((p): PersonSummary => ({
      who: p.who,
      searches: n(p.searches),
      voiceMinutes: n(p.voice_minutes),
      today: n(p.today),
      last30: n(p.last30),
      perSearch: n(p.searches) ? n(p.search_cost) / n(p.searches) : 0,
      lastSeen: n(p.last_seen),
    })),
    recent: recent.map((r) => ({
      ts: n(r.ts), who: r.who, kind: r.kind, provider: r.provider, inputTokens: n(r.input_tokens),
      outputTokens: n(r.output_tokens), webSearches: n(r.web_searches), audioSeconds: n(r.audio_seconds), cost: n(r.cost_usd),
    })),
  };
}
