"""One collection run: `python -m doorlist_collector.run`. Render runs it hourly as a cron job.

Reads every source, merges what it found into Postgres, and logs one row in explore_runs saying
how many requests it made and what each source returned. A source that fails or blocks us
leaves its earlier events in place; the next run tries again.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
import traceback

import psycopg

from . import store
from .geocode import Geocoder
from .http import Polite
from .places import luma_places
from .sources import hackathons, luma, sites

log = logging.getLogger("collector")


def run(db, http: Polite | None = None) -> dict:
    http = http or Polite()
    started = time.monotonic()
    run_id = db.execute("INSERT INTO explore_runs DEFAULT VALUES RETURNING id").fetchone()[0]
    detail: dict = {}
    try:
        places = luma_places(http.json(f"{luma.API}/discover/bootstrap-page"))
        store.save_places(db, places)

        events, detail["luma"] = luma.collect(http, places, run_id, store.enriched_luma_ids(db))
        found, notes = hackathons.collect(http)
        events += found
        detail.update(notes)

        def lookup(slug: str):
            return luma.lookup(http, slug)

        found, notes = sites.collect(http, lookup)
        events += found
        detail.update(notes)

        # Town names to coordinates, for events that came without them.
        geocoder = Geocoder(http, db)
        for event in events:
            if event.lat is None and not event.online and event.city:
                event.lat, event.lng = geocoder.locate(event.city)
        detail["geocoded"] = geocoder.looked_up

        written = store.save_events(db, events)
        detail["pruned"] = store.prune(db)
        db.execute(
            "UPDATE explore_runs SET finished_at = now(), requests = %s, events = %s, blocked = %s, detail = %s WHERE id = %s",
            (http.requests, written, bool(http.blocked), json.dumps({**detail, "blocked": sorted(http.blocked),
                                                                      "seconds": round(time.monotonic() - started)}), run_id),
        )
        log.info("run %s: %s events from %s requests %s", run_id, written, http.requests, detail)
        return detail
    except Exception as error:
        db.execute("UPDATE explore_runs SET finished_at = now(), requests = %s, error = %s, detail = %s WHERE id = %s",
                   (http.requests, traceback.format_exc()[-2000:], json.dumps(detail), run_id))
        raise error


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    url = os.environ.get("DATABASE_URL")
    if not url:
        print("DATABASE_URL is not set", file=sys.stderr)
        return 2
    with psycopg.connect(url, autocommit=True) as db:
        store.ensure_schema(db)
        run(db)
    return 0


if __name__ == "__main__":
    sys.exit(main())
