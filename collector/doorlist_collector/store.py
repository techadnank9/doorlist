"""Writing Explore's tables. One event per row, however many sites list it."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from pathlib import Path

from psycopg.rows import dict_row

from .model import Event
from .places import Place

SCHEMA = Path(__file__).resolve().parent.parent / "schema.sql"

_COLUMNS = ("id", "title", "title_key", "description", "starts_at", "ends_at", "all_day", "timezone", "city", "lat", "lng",
            "online", "url", "sources", "cover_url", "is_free", "sold_out", "guest_count", "topics", "enriched")


def ensure_schema(db) -> None:
    db.execute(SCHEMA.read_text())


def save_places(db, places: list[Place]) -> None:
    for p in places:
        db.execute(
            """INSERT INTO explore_places (id, name, lat, lng, radius_km, luma_id, featured, updated_at)
               VALUES (%s, %s, %s, %s, %s, %s, %s, now())
               ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, lat = EXCLUDED.lat, lng = EXCLUDED.lng,
                 radius_km = EXCLUDED.radius_km, luma_id = EXCLUDED.luma_id, featured = EXCLUDED.featured, updated_at = now()""",
            (p.id, p.name, p.lat, p.lng, p.radius_km, p.luma_id, p.featured),
        )


def enriched_luma_ids(db) -> set[str]:
    rows = db.execute("SELECT substr(id, 6) FROM explore_events WHERE id LIKE 'luma:%%' AND enriched").fetchall()
    return {r[0] for r in rows}


def dedupe(events: list[Event]) -> list[Event]:
    """One event per real-world event: same id, or same title on the same day."""
    by_id: dict[str, Event] = {}
    for event in events:
        by_id[event.id] = by_id[event.id].merge(event) if event.id in by_id else event
    by_title: dict[str, Event] = {}
    for event in sorted(by_id.values(), key=lambda e: e.luma_id is None):  # Luma copies first, so they lead
        key = event.title_key
        by_title[key] = by_title[key].merge(event) if key in by_title else event
    return list(by_title.values())


def _row_event(row: dict) -> Event:
    event = Event(source=(row["sources"] or ["luma"])[0], title=row["title"], starts_at=row["starts_at"], url=row["url"],
                  luma_id=row["id"][5:] if row["id"].startswith("luma:") else None)
    for name in ("ends_at", "description", "timezone", "city", "lat", "lng", "online", "all_day", "cover_url",
                 "is_free", "sold_out", "guest_count", "enriched"):
        setattr(event, name, row[name])
    event.topics, event.sources = set(row["topics"]), set(row["sources"])
    return event


def save_events(db, events: list[Event]) -> int:
    """Merges the run's events into what's stored. An event that turns out to be on Luma moves to its Luma id."""
    stored: dict[str, Event] = {}
    by_title: dict[str, str] = {}
    cursor = db.cursor(row_factory=dict_row)
    since = datetime.now(timezone.utc) - timedelta(days=3)
    for row in cursor.execute("SELECT * FROM explore_events WHERE starts_at > %s OR ends_at > %s", (since, since)):
        event = _row_event(row)
        stored[row["id"]] = event
        by_title.setdefault(row["title_key"], row["id"])

    written = 0
    for event in dedupe(events):
        old_id = event.id if event.id in stored else by_title.get(event.title_key)
        if old_id and old_id in stored:
            # Stored values first, then this run's sighting on top.
            merged = stored.pop(old_id).merge(event)  # takes the Luma id and link if this sighting has them
            if old_id != merged.id:
                db.execute("DELETE FROM explore_events WHERE id = %s", (old_id,))
        else:
            merged = event
        values = (merged.id, merged.title, merged.title_key, merged.description, merged.starts_at, merged.ends_at, merged.all_day,
                  merged.timezone, merged.city, merged.lat, merged.lng, merged.online, merged.url, sorted(merged.sources),
                  merged.cover_url, merged.is_free, merged.sold_out, merged.guest_count, sorted(merged.topics), merged.enriched)
        db.execute(
            f"""INSERT INTO explore_events ({", ".join(_COLUMNS)}, seen_at, updated_at)
                VALUES ({", ".join(["%s"] * len(_COLUMNS))}, now(), now())
                ON CONFLICT (id) DO UPDATE SET {", ".join(f"{c} = EXCLUDED.{c}" for c in _COLUMNS[1:])},
                  seen_at = now(), updated_at = now()""",
            values,
        )
        written += 1
    return written


def prune(db) -> int:
    """Forgets events that ended more than two days ago."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=2)
    return db.execute(
        "DELETE FROM explore_events WHERE coalesce(ends_at, starts_at + interval '6 hours') < %s", (cutoff,)
    ).rowcount
