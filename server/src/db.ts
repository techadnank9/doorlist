import pg from "pg";

/** One pool for the whole server. DATABASE_URL comes from the host (Render Postgres in production). */
export const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.DB_POOL_SIZE ?? 5),
  // On Render the server reaches Postgres over the private network (internal URL), so no TLS is
  // needed there. Set DATABASE_SSL=true when connecting from outside; certificates are verified.
  ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : undefined,
});

let ready: Promise<void> | null = null;

/** Creates the tables once per process. Safe to call on every request. */
export function migrate(): Promise<void> {
  ready ??= pool.query(`
    CREATE TABLE IF NOT EXISTS profiles (
      user_id TEXT PRIMARY KEY,
      data JSONB NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
    );
    CREATE TABLE IF NOT EXISTS usage (
      id BIGSERIAL PRIMARY KEY,
      ts BIGINT NOT NULL,
      req TEXT NOT NULL,
      who TEXT NOT NULL,
      kind TEXT NOT NULL,
      provider TEXT NOT NULL,
      input_tokens INTEGER NOT NULL DEFAULT 0,
      cached_tokens INTEGER NOT NULL DEFAULT 0,
      output_tokens INTEGER NOT NULL DEFAULT 0,
      web_searches INTEGER NOT NULL DEFAULT 0,
      audio_seconds DOUBLE PRECISION NOT NULL DEFAULT 0,
      cost_usd DOUBLE PRECISION NOT NULL
    );
    CREATE INDEX IF NOT EXISTS usage_ts ON usage (ts);
    CREATE INDEX IF NOT EXISTS usage_who_ts ON usage (who, ts);
  `).then(() => undefined).catch((error) => {
    ready = null;
    throw error;
  });
  return ready;
}
