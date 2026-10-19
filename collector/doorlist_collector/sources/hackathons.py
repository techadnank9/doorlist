"""Hackathon directories: Devpost, MLH, lablab.ai and Devfolio. Everything they list is a hackathon."""

from __future__ import annotations

import re
from datetime import datetime, time, timezone

from ..http import Polite
from ..model import Event
from .common import image, iso, next_data, objects_with, text

DEVPOST = "https://devpost.com/api/hackathons?status[]=upcoming&status[]=open&page={page}"
MLH = "https://www.mlh.com/seasons/{season}/events"
LABLAB = "https://lablab.ai/event"
DEVFOLIO = "https://devfolio.co/hackathons"


def _hackathon(event: Event) -> Event:
    event.topics |= {"hackathons", "tech"}
    return event.tagged()


# MARK: Devpost (public JSON API)

_MONTHS = "Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec".split()


def devpost_start(dates: str) -> datetime | None:
    """The first day of Devpost's "Oct 23 - 25, 2026", "Jan 25 - Feb 11, 2027" or "Nov 01, 2026"."""
    match = re.match(r"([A-Z][a-z]{2}) (\d{1,2})\b.*?(\d{4})", dates or "")
    if not match or match.group(1) not in _MONTHS:
        return None
    month = _MONTHS.index(match.group(1)) + 1
    return datetime(int(match.group(3)), month, int(match.group(2)), 12, tzinfo=timezone.utc)


def devpost_end(dates: str) -> datetime | None:
    """The last day of the same ranges: "Oct 23 - 25, 2026" ends the 25th, "Jan 25 - Feb 11, 2027" Feb 11."""
    match = re.match(r"([A-Z][a-z]{2}) (\d{1,2})(?: - (?:([A-Z][a-z]{2}) )?(\d{1,2}))?, (\d{4})", dates or "")
    if not match or match.group(1) not in _MONTHS:
        return None
    month = match.group(3) or match.group(1)
    if month not in _MONTHS:
        return None
    day = int(match.group(4) or match.group(2))
    return datetime(int(match.group(5)), _MONTHS.index(month) + 1, day, 23, 59, tzinfo=timezone.utc)


def parse_devpost(data: dict) -> list[Event]:
    events = []
    for h in data.get("hackathons", []):
        start = devpost_start(h.get("submission_period_dates", ""))
        if not start or not h.get("title") or not h.get("url"):
            continue
        where = ((h.get("displayed_location") or {}).get("location") or "").strip()
        online = where.lower() in ("online", "") or where.lower().startswith("online")
        themes = ", ".join(t.get("name", "") for t in h.get("themes") or [])
        event = Event(source="devpost", title=h["title"], starts_at=start, url=h["url"],
                      ends_at=devpost_end(h.get("submission_period_dates", "")),
                      description=f"{h.get('organization_name') or ''}. Themes: {themes}".strip(". ") or None,
                      city=None if online else re.sub(r"\s*\+\s*Online$", "", where), online=online,
                      cover_url=image(h.get("thumbnail_url")), is_free=True)
        event.all_day = True
        events.append(_hackathon(event))
    return events


# MARK: MLH (events embedded in the season page)

def parse_mlh(page: str) -> list[Event]:
    events = []
    seen = set()
    for o in objects_with(page.replace('\\"', '"').replace("\\/", "/"), "startsAt"):
        if not o.get("name") or not o.get("startsAt") or not o.get("slug") or o["slug"] in seen:
            continue
        seen.add(o["slug"])
        venue = o.get("venueAddress") or {}
        online = o.get("formatType") == "digital"
        city = ", ".join(x for x in (venue.get("city"), venue.get("state")) if x) or o.get("location")
        events.append(_hackathon(Event(
            source="mlh", title=o["name"], starts_at=iso(o["startsAt"]), ends_at=iso(o.get("endsAt")),
            url=o.get("websiteUrl") or f"https://www.mlh.com/events/{o['slug']}",
            city=None if online else city, online=online, cover_url=image(o.get("backgroundUrl") or o.get("logoUrl")), is_free=True)))
    return events


# MARK: lablab.ai (online AI hackathons, embedded in the page)

def parse_lablab(page: str) -> list[Event]:
    events = []
    seen = set()
    for o in objects_with(page.replace('\\"', '"'), "startAt"):
        slug, name = o.get("slug"), o.get("name")
        if not slug or not name or not o.get("startAt") or slug in seen or o.get("toBeAnnounced"):
            continue
        seen.add(slug)
        events.append(_hackathon(Event(
            source="lablab", title=name, starts_at=iso(o["startAt"]), ends_at=iso(o.get("endAt")),
            url=f"https://lablab.ai/ai-hackathons/{slug}", description=text(o.get("description")),
            online=True, cover_url=image(o.get("imageLink") or o.get("thumbnailLink")), is_free=True)))
    return events


# MARK: Devfolio (Next.js page data)

def parse_devfolio(page: str) -> list[Event]:
    events = []
    seen = set()
    for o in objects_with(__import__("json").dumps(next_data(page)), "starts_at"):
        if o.get("type") != "HACKATHON" or not o.get("slug") or not o.get("starts_at") or o["slug"] in seen:
            continue
        seen.add(o["slug"])
        # Devfolio's list gives no city for in-person events, so only online ones can be placed.
        if not o.get("is_online"):
            continue
        settings = o.get("settings") or {}
        events.append(_hackathon(Event(
            source="devfolio", title=o.get("name") or o["slug"], starts_at=iso(o["starts_at"]), ends_at=iso(o.get("ends_at")),
            url=f"https://{o['slug']}.devfolio.co", timezone=o.get("timezone"), online=True,
            cover_url=image(settings.get("featured_cover_img_v2") or settings.get("featured_cover_img") or o.get("cover_img")),
            is_free=True)))
    return events


# MARK: Collecting

def collect(http: Polite) -> tuple[list[Event], dict]:
    events: list[Event] = []
    notes: dict = {}
    for name, read in (
        ("devpost", lambda: [e for p in (1, 2, 3) for e in parse_devpost(http.json(DEVPOST.format(page=p)))]),
        ("mlh", lambda: parse_mlh(http.get(MLH.format(season=_season())))),
        ("lablab", lambda: parse_lablab(http.get(LABLAB))),
        ("devfolio", lambda: parse_devfolio(http.get(DEVFOLIO))),
    ):
        try:
            found = read()
            events += found
            notes[name] = len(found)
        except Exception as error:
            notes[name] = f"error: {str(error)[:200]}"
    return events, notes


def _season() -> int:
    """MLH names a season after the year it ends in; it starts in late summer."""
    now = datetime.now(timezone.utc)
    return now.year + 1 if now.month >= 8 else now.year
