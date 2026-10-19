"""Coordinates for events that only name a town ("Stony Brook, New York").

OpenStreetMap's Nominatim, at most one lookup a second as its usage policy asks, each answer kept
forever in explore_geocache so a town is only ever looked up once.
"""

from __future__ import annotations

import re
from urllib.parse import quote

from .http import Blocked, Polite

NOMINATIM = "https://nominatim.openstreetmap.org/search?format=json&limit=1&q={q}"


def query_for(city: str) -> str:
    return re.sub(r"\s+", " ", city.strip().lower())[:200]


class Geocoder:
    def __init__(self, http: Polite, db, limit: int = 150) -> None:
        self.http, self.db, self.left = http, db, limit
        self.cache: dict[str, tuple[float | None, float | None]] = {
            q: (lat, lng) for q, lat, lng in db.execute("SELECT query, lat, lng FROM explore_geocache").fetchall()
        }
        self.looked_up = 0

    def locate(self, city: str | None) -> tuple[float | None, float | None]:
        if not city:
            return None, None
        q = query_for(city)
        if q in self.cache:
            return self.cache[q]
        if self.left <= 0:
            return None, None
        self.left -= 1
        try:
            hits = self.http.json(NOMINATIM.format(q=quote(q)))
        except Blocked:
            self.left = 0
            return None, None
        except Exception:
            return None, None  # try again next run
        lat, lng = (float(hits[0]["lat"]), float(hits[0]["lon"])) if hits else (None, None)
        self.cache[q] = (lat, lng)
        self.looked_up += 1
        self.db.execute(
            "INSERT INTO explore_geocache (query, lat, lng) VALUES (%s, %s, %s) ON CONFLICT (query) DO NOTHING",
            (q, lat, lng),
        )
        return lat, lng
