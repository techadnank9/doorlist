"""Luma, the main source.

Three reads, all gentle (one request per 3 seconds, see http.py):
- each city's public iCal feed, the one behind Luma's own "Subscribe" button;
- the discover feed, per city and for the Tech, AI and Food & Drink categories, which adds covers,
  prices, guest counts and Luma's own categories;
- once per event and never again, the event itself, for anything the feeds left out.
"""

from __future__ import annotations

import re
from datetime import datetime, timezone
from urllib.parse import quote

from ..http import Blocked, Polite
from ..model import LUMA_CATEGORY_TOPICS, Event
from ..places import Place

API = "https://api.luma.com"

# Discover categories worth a request per city. Everything else is tagged from wording and, for each
# new event, from Luma's own categories when it's read once.
DISCOVER_CATEGORIES = {"tech": "cat-tech", "ai": "cat-ai", "food": "cat-fooddrink"}

# Pages of 50 read per category in each featured city.
CATEGORY_PAGES = 3

# Cities other than the featured ones are read every this many runs (hourly runs: every 6 hours).
ROTATION = 6


# MARK: Parsing (pure, tested against saved pages)

def _unfold(ics: str) -> list[str]:
    lines: list[str] = []
    for raw in ics.replace("\r\n", "\n").split("\n"):
        if raw.startswith((" ", "\t")) and lines:
            lines[-1] += raw[1:]
        else:
            lines.append(raw)
    return lines


def _ics_text(value: str) -> str:
    return value.replace("\\n", "\n").replace("\\,", ",").replace("\\;", ";").replace("\\\\", "\\")


def _ics_time(value: str) -> datetime:
    """A UTC time, or for all-day events (DTSTART;VALUE=DATE:20261020) noon that day."""
    if len(value) == 8:
        return datetime.strptime(value, "%Y%m%d").replace(hour=12, tzinfo=timezone.utc)
    return datetime.strptime(value, "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)


def parse_ics(ics: str) -> list[Event]:
    """Events from a Luma iCal feed. The page link sits at the top of the description."""
    events: list[Event] = []
    fields: dict[str, str] | None = None
    for line in _unfold(ics):
        if line == "BEGIN:VEVENT":
            fields = {}
        elif line == "END:VEVENT" and fields is not None:
            event = _ics_event(fields)
            if event:
                events.append(event)
            fields = None
        elif fields is not None and ":" in line:
            name, value = line.split(":", 1)
            fields[name.split(";", 1)[0]] = value
    return events


def _ics_event(f: dict[str, str]) -> Event | None:
    uid = f.get("UID", "")
    match = re.match(r"(evt-[A-Za-z0-9]+)@", uid)
    if not match or "DTSTART" not in f or not f.get("SUMMARY"):
        return None
    description = _ics_text(f.get("DESCRIPTION", ""))
    link = re.search(r"https://luma\.com/[A-Za-z0-9_-]+", description)
    # The feed's description starts with "Get up-to-date information at: <link>" and an address line.
    body = re.sub(r"^Get up-to-date information at: \S+\s*", "", description)
    body = re.sub(r"^Address:\n[^\n]*\n*", "", body).strip()
    lat = lng = None
    if "GEO" in f and ";" in f["GEO"]:
        lat, lng = (float(x) for x in f["GEO"].split(";", 1))
    event = Event(
        source="luma", luma_id=match.group(1), title=_ics_text(f["SUMMARY"]),
        starts_at=_ics_time(f["DTSTART"]), ends_at=_ics_time(f["DTEND"]) if "DTEND" in f else None,
        url=link.group(0) if link else f"https://luma.com/event/{match.group(1)}",
        description=body[:2000] or None, lat=lat, lng=lng,
    )
    event.all_day = len(f["DTSTART"]) == 8
    return event.tagged()


def _iso(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def _from_luma(event: dict, wrapper: dict) -> Event | None:
    """An event in the shape Luma's discover and event endpoints both use."""
    if not event.get("api_id") or not event.get("name") or not event.get("start_at"):
        return None
    geo = event.get("geo_address_info") or {}
    coordinate = event.get("coordinate") or {}
    tickets = wrapper.get("ticket_info") or {}
    topics = {LUMA_CATEGORY_TOPICS[c["slug"]] for c in wrapper.get("categories") or [] if c.get("slug") in LUMA_CATEGORY_TOPICS}
    return Event(
        source="luma", luma_id=event["api_id"], title=event["name"],
        starts_at=_iso(event["start_at"]), ends_at=_iso(event.get("end_at")),
        url=f"https://luma.com/{event['url']}" if event.get("url") else f"https://luma.com/event/{event['api_id']}",
        timezone=event.get("timezone"), city=geo.get("city_state") or geo.get("city"),
        lat=coordinate.get("latitude") or event.get("geo_latitude"),
        lng=coordinate.get("longitude") or event.get("geo_longitude"),
        online=event.get("location_type") == "online",
        cover_url=event.get("cover_url"),
        is_free=tickets.get("is_free"), sold_out=tickets.get("is_sold_out"),
        guest_count=wrapper.get("guest_count"), topics=topics,
    ).tagged()


def parse_discover(data: dict) -> tuple[list[Event], str | None]:
    """One page of the discover feed, and the cursor for the next page (None when it's the last)."""
    events = [e for entry in data.get("entries", []) if (e := _from_luma(entry.get("event") or {}, entry))]
    return events, data.get("next_cursor") if data.get("has_more") else None


def parse_event(data: dict) -> Event | None:
    """The full event, read once. Luma's own categories come with it."""
    event = _from_luma(data.get("event") or {}, data)
    if event:
        event.enriched = True
    return event


# MARK: Collecting

def collect(http: Polite, places: list[Place], run_number: int, known: set[str], enrich_limit: int = 60):
    """Every Luma event worth showing, plus a note on what was read.

    `known` holds ids already enriched in the database; only new ones are read one by one.
    """
    found: dict[str, Event] = {}
    notes: dict[str, int | str] = {}

    def add(events: list[Event], topic: str | None = None) -> None:
        for event in events:
            if topic:
                event.topics.add(topic)
            found[event.id] = found[event.id].merge(event) if event.id in found else event

    luma_places = [p for p in places if p.luma_id]
    for index, place in enumerate(luma_places):
        # Featured cities every run; the rest take turns.
        if place.featured is None and index % ROTATION != run_number % ROTATION:
            continue
        try:
            add(parse_ics(http.get(f"{API}/ics/get?entity=discover&id={quote(place.luma_id)}", accept="text/calendar")))
            add(_discover(http, f"discover_place_api_id={place.luma_id}", pages=2 if place.featured else 1))
            if place.featured:
                # Luma ignores the category when a city id is given, so categories go by coordinates.
                for topic, category in DISCOVER_CATEGORIES.items():
                    # Busy categories (AI in San Francisco) run well past one page of 50.
                    add(_discover(http, f"discover_category_api_id={category}&latitude={place.lat}&longitude={place.lng}",
                                  pages=CATEGORY_PAGES), LUMA_CATEGORY_TOPICS[topic])
        except Blocked:
            notes["blocked"] = place.id
            break
        except Exception as error:  # one city's bad page shouldn't lose the rest
            notes[f"error:{place.id}"] = str(error)[:200]

    enriched = 0
    for event in list(found.values()):
        if enriched >= enrich_limit or "blocked" in notes:
            break
        if event.luma_id in known:
            continue
        try:
            full = parse_event(http.json(f"{API}/event/get?event_api_id={event.luma_id}"))
            enriched += 1
            if full:
                found[event.id] = event.merge(full)
        except Blocked:
            notes["blocked"] = "event/get"
        except Exception as error:
            notes[f"error:{event.luma_id}"] = str(error)[:200]

    notes.update(events=len(found), enriched=enriched)
    return list(found.values()), notes


def _discover(http: Polite, query: str, pages: int = 1) -> list[Event]:
    events: list[Event] = []
    cursor: str | None = None
    for _ in range(pages):
        url = f"{API}/discover/get-paginated-events?pagination_limit=50&{query}"
        if cursor:
            url += f"&pagination_cursor={quote(cursor)}"
        page, cursor = parse_discover(http.json(url))
        events += page
        if not cursor:
            break
    return events


def lookup(http: Polite, slug: str) -> Event | None:
    """A Luma event another site linked to, read by its page slug."""
    data = http.json(f"{API}/url?url={quote(slug)}")
    if data.get("kind") != "event":
        return None
    event = _from_luma(data.get("data", {}).get("event") or {}, data.get("data") or {})
    if event:
        event.enriched = True
    return event
