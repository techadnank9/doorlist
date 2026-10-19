import type { SearchResult } from "./search.js";

/**
 * Searches keep running when the phone drops the connection (iOS suspends an app soon after it
 * leaves the screen), and their outcome is kept for a while. The app sends the same request id
 * when it reconnects and joins the search that's already under way, or gets its result, instead
 * of paying for a second one.
 */
export type Outcome = { result: SearchResult } | { error: string };

export interface SearchJob {
  /** The latest stage line, so a late joiner sees where the search is. */
  stage: unknown;
  listeners: Set<(line: unknown) => void>;
  done: Promise<Outcome>;
}

const jobs = new Map<string, SearchJob>();
const keepFor = 10 * 60_000;

/** Ids are per caller, so one person can never join another's search. */
export function jobKey(who: string, requestId: unknown): string | null {
  return typeof requestId === "string" && /^[A-Za-z0-9-]{8,64}$/.test(requestId) ? `${who}|${requestId}` : null;
}

export function findJob(key: string | null): SearchJob | undefined {
  return key ? jobs.get(key) : undefined;
}

/** Runs `work` once, whoever is connected; it finishes even if every connection drops. */
export function startJob(key: string | null, work: (emit: (line: unknown) => void) => Promise<Outcome>): SearchJob {
  const listeners = new Set<(line: unknown) => void>();
  const job: SearchJob = { stage: null, listeners, done: Promise.resolve({ error: "" }) };
  job.done = work((line) => {
    job.stage = line;
    for (const listener of listeners) listener(line);
  });
  if (key) {
    jobs.set(key, job);
    void job.done.finally(() => setTimeout(() => jobs.delete(key), keepFor).unref());
  }
  return job;
}

/** Streams a job to one connection: where it is now, each later stage, then the outcome. */
export async function follow(job: SearchJob, send: (line: unknown) => void) {
  if (job.stage) send(job.stage);
  job.listeners.add(send);
  try {
    send(await job.done);
  } finally {
    job.listeners.delete(send);
  }
}
