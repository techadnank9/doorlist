-- Explore's tables. The collector writes them; the server only reads.
-- This file is the one definition: the collector runs it on every start, and
-- the server's tests load it to build the same tables. Safe to run repeatedly.

CREATE TABLE IF NOT EXISTS explore_places (
  id TEXT PRIMARY KEY,              -- our slug: "sf", "bay-area", "las-vegas"
  name TEXT NOT NULL,
  lat DOUBLE PRECISION NOT NULL,
  lng DOUBLE PRECISION NOT NULL,
  radius_km DOUBLE PRECISION NOT NULL,
  luma_id TEXT,                     -- discplace-...; null for areas Luma doesn't list (Bay Area, Online)
  featured INTEGER,                 -- position in the picker's top list; null for the rest
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS explore_events (
  id TEXT PRIMARY KEY,              -- "luma:evt-..." when it's on Luma, else "url:<canonical link>"
  title TEXT NOT NULL,
  title_key TEXT NOT NULL,          -- normalised title + start day: finds the same event across sources
  description TEXT,
  starts_at TIMESTAMPTZ NOT NULL,
  ends_at TIMESTAMPTZ,
  all_day BOOLEAN NOT NULL DEFAULT false,   -- the site gave a date but no time; starts_at is noon UTC that day
  timezone TEXT,
  city TEXT,
  lat DOUBLE PRECISION,
  lng DOUBLE PRECISION,
  online BOOLEAN NOT NULL DEFAULT false,
  url TEXT NOT NULL,                -- what booking opens; the Luma page when there is one
  sources TEXT[] NOT NULL DEFAULT '{}',     -- every site that listed it: luma, devpost, mlh, ...
  cover_url TEXT,
  is_free BOOLEAN,
  sold_out BOOLEAN,
  guest_count INTEGER,
  topics TEXT[] NOT NULL DEFAULT '{}',
  enriched BOOLEAN NOT NULL DEFAULT false,  -- Luma events: read once from the event endpoint
  seen_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS explore_events_starts ON explore_events (starts_at);
CREATE INDEX IF NOT EXISTS explore_events_lat ON explore_events (lat);
CREATE INDEX IF NOT EXISTS explore_events_topics ON explore_events USING GIN (topics);
CREATE INDEX IF NOT EXISTS explore_events_sources ON explore_events USING GIN (sources);
CREATE INDEX IF NOT EXISTS explore_events_title_key ON explore_events (title_key);

CREATE TABLE IF NOT EXISTS explore_runs (
  id BIGSERIAL PRIMARY KEY,
  started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at TIMESTAMPTZ,
  requests INTEGER NOT NULL DEFAULT 0,
  events INTEGER NOT NULL DEFAULT 0,
  blocked BOOLEAN NOT NULL DEFAULT false,
  error TEXT,
  detail JSONB                      -- per source: events found, or why it was skipped
);

-- Town names some sites give instead of coordinates, looked up once (OpenStreetMap) and kept.
CREATE TABLE IF NOT EXISTS explore_geocache (
  query TEXT PRIMARY KEY,
  lat DOUBLE PRECISION,             -- null: looked up, nothing found
  lng DOUBLE PRECISION,
  looked_up_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
