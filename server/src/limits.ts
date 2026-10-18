/**
 * Daily usage caps per person (or per install before sign in). In memory, so
 * they reset on restart; fine for one instance, swap for Redis when scaling out.
 */
const counts = new Map<string, number>();
let day = today();

function today(): string {
  return new Date().toISOString().slice(0, 10);
}

/** Counts one use. False when the caller is over `limit` for today. */
export function take(who: string, kind: string, limit: number): boolean {
  const now = today();
  if (now !== day) {
    counts.clear();
    day = now;
  }
  const key = `${kind}:${who}`;
  const used = counts.get(key) ?? 0;
  if (used >= limit) return false;
  counts.set(key, used + 1);
  return true;
}
