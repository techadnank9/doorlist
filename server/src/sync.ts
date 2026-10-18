import { migrate, pool } from "./db.js";

/**
 * A person's Doorlist, kept with their account so a new phone gets it all
 * back: remembered answers, booking history and preferences. Logins to Luma,
 * Partiful and Eventbrite are not here; those stay on each device.
 */
export interface SavedAnswer {
  label: string;
  value: string;
  choices?: string[] | null;
  updatedAt: string;
  askedAs?: string[] | null;
  /** Forgotten on some device; kept as a marker so other devices forget it too. */
  deleted?: boolean;
}

export interface Profile {
  answers: Record<string, SavedAnswer>;
  history: Record<string, unknown>[];
  prefs: { autoAgree?: boolean; updatedAt?: string };
}

export const emptyProfile = (): Profile => ({ answers: {}, history: [], prefs: {} });

const time = (iso: unknown) => {
  const t = Date.parse(String(iso ?? ""));
  return Number.isFinite(t) ? t : 0;
};

/** Combines two copies: per answer the newer edit wins, history keeps every booking (newest copy of each). */
export function merge(a: Profile, b: Profile): Profile {
  const answers: Record<string, SavedAnswer> = { ...a.answers };
  for (const [k, v] of Object.entries(b.answers)) {
    const mine = answers[k];
    if (!mine || time(v.updatedAt) >= time(mine.updatedAt)) answers[k] = v;
  }
  const history = new Map<string, Record<string, unknown>>();
  for (const r of [...a.history, ...b.history]) {
    const id = String(r.id ?? "");
    if (!id) continue;
    const existing = history.get(id);
    if (!existing || time(r.bookedAt) >= time(existing.bookedAt)) history.set(id, r);
  }
  const prefs = time(b.prefs.updatedAt) >= time(a.prefs.updatedAt) ? b.prefs : a.prefs;
  return {
    answers,
    history: [...history.values()].sort((x, y) => time(y.bookedAt) - time(x.bookedAt)).slice(0, 1000),
    prefs,
  };
}

/** Only the shapes we expect, so a bad client can't store junk. */
export function clean(body: any): Profile | null {
  if (!body || typeof body !== "object") return null;
  const answers: Record<string, SavedAnswer> = {};
  for (const [k, v] of Object.entries(body.answers ?? {})) {
    const a = v as any;
    if (k.length > 200 || !a || typeof a !== "object") continue;
    if (typeof a.value !== "string" || typeof a.label !== "string" || typeof a.updatedAt !== "string") continue;
    answers[k] = {
      label: a.label.slice(0, 500),
      value: a.value.slice(0, 5000),
      choices: Array.isArray(a.choices) ? a.choices.filter((c: unknown) => typeof c === "string").slice(0, 50) : null,
      updatedAt: a.updatedAt,
      askedAs: Array.isArray(a.askedAs) ? a.askedAs.filter((c: unknown) => typeof c === "string").slice(0, 50) : null,
      ...(a.deleted === true ? { deleted: true } : {}),
    };
  }
  const history = (Array.isArray(body.history) ? body.history : [])
    .filter((r: any) => r && typeof r === "object" && typeof r.id === "string" && typeof r.eventName === "string")
    .slice(0, 1000);
  const prefs = body.prefs && typeof body.prefs === "object"
    ? { autoAgree: body.prefs.autoAgree === true, updatedAt: typeof body.prefs.updatedAt === "string" ? body.prefs.updatedAt : undefined }
    : {};
  return { answers, history, prefs };
}

export async function load(userId: string): Promise<Profile> {
  await migrate();
  const { rows } = await pool.query("SELECT data FROM profiles WHERE user_id = $1", [userId]);
  return (rows[0]?.data as Profile | undefined) ?? emptyProfile();
}

/** Merges the device's copy into the stored one and returns the result for the device to keep. */
export async function sync(userId: string, incoming: Profile): Promise<Profile> {
  await migrate();
  const client = await pool.connect();
  try {
    await client.query("BEGIN");
    const { rows } = await client.query("SELECT data FROM profiles WHERE user_id = $1 FOR UPDATE", [userId]);
    const stored = (rows[0]?.data as Profile | undefined) ?? emptyProfile();
    const merged = merge(stored, incoming);
    await client.query(
      `INSERT INTO profiles (user_id, data, updated_at) VALUES ($1, $2, now())
       ON CONFLICT (user_id) DO UPDATE SET data = EXCLUDED.data, updated_at = now()`,
      [userId, JSON.stringify(merged)],
    );
    await client.query("COMMIT");
    return merged;
  } catch (error) {
    await client.query("ROLLBACK").catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

/** Account deletion: the profile and its usage rows are gone for good. */
export async function remove(userId: string): Promise<void> {
  await migrate();
  await pool.query("DELETE FROM profiles WHERE user_id = $1", [userId]);
  await pool.query("DELETE FROM usage WHERE who = $1", [`user:${userId}`]);
}
