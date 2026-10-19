import { createHash, randomUUID } from "node:crypto";
import { PostHog } from "posthog-node";

/**
 * PostHog from the server: LLM analytics for every OpenAI call (PostHog's `$ai_generation`
 * events), so search quality, latency and cost can be read per request and per person.
 * Off until POSTHOG_API_KEY is set, and always off in tests.
 */
const key = process.env.POSTHOG_API_KEY ?? "";
const client = key && process.env.NODE_ENV !== "test"
  ? new PostHog(key, { host: process.env.POSTHOG_HOST || "https://us.i.posthog.com", flushAt: 20, flushInterval: 10_000 })
  : null;

/** The id PostHog knows a person by: a one-way hash of the account, never the Apple id itself. */
export function analyticsId(sub: string): string {
  return `acct_${createHash("sha256").update(`doorlist:${sub}`).digest("hex").slice(0, 24)}`;
}

/** `user:<sub>` becomes that account's analytics id; an install stays anonymous. */
function distinctId(who: string): string {
  if (who.startsWith("user:")) return analyticsId(who.slice(5));
  return who.startsWith("install:") ? who : `anon:${randomUUID()}`;
}

export interface Generation {
  who: string;
  traceId: string;
  model: string;
  input: unknown;
  output: string;
  inputTokens: number;
  outputTokens: number;
  costUsd: number;
  latencySeconds: number;
  status: number;
  error?: string;
}

export function captureGeneration(g: Generation) {
  if (!client) return;
  client.capture({
    distinctId: distinctId(g.who),
    event: "$ai_generation",
    properties: {
      $ai_trace_id: g.traceId,
      $ai_provider: "openai",
      $ai_model: g.model,
      $ai_input: g.input,
      $ai_output_choices: [{ role: "assistant", content: g.output }],
      $ai_input_tokens: g.inputTokens,
      $ai_output_tokens: g.outputTokens,
      $ai_total_cost_usd: g.costUsd,
      $ai_latency: g.latencySeconds,
      $ai_http_status: g.status,
      $ai_is_error: Boolean(g.error),
      ...(g.error ? { $ai_error: g.error } : {}),
      $process_person_profile: g.who.startsWith("user:"),
    },
  });
}

export async function shutdownAnalytics() {
  await client?.shutdown();
}
