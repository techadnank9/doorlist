"""The general event sites: Cerebral Valley, Y Combinator, Partiful, Eventbrite, Meetup, AllEvents and Funcheap."""

from __future__ import annotations

import html
import json
import re
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from urllib.parse import quote

from ..http import Blocked, Polite
from ..model import Event, luma_slug
from ..places import FEATURED
from .common import from_ld, image, iso, ld_events, next_data, objects_with, text

CEREBRAL_VALLEY = "https://cerebralvalley.ai/events"
YC = "https://www.ycombinator.com/events"


# MARK: Cerebral Valley (schema.org list, plus links to the Luma pages many of its events live on)

def parse_cerebralvalley(page: str) -> tuple[list[Event], set[str]]:
    """Its events, and the Luma pages it links to (read separately so they book through Luma)."""
    events = [e for node in ld_events(page) if (e := from_ld(node, "cerebralvalley"))]
    for event, node in zip(events, ld_events(page)):
        kinds = node.get("@type")
        if "Hackathon" in (kinds if isinstance(kinds, list) else [kinds]):
            event.topics |= {"hackathons", "tech"}
        # Cerebral Valley is an AI community: everything it lists is tech.
        event.topics.add("tech")
    links = {slug for href in re.findall(r'href="([^"]+)"', page) if (slug := luma_slug(html.unescape(href)))}
    return events, links


# MARK: Y Combinator (JSON in the page's data-page attribute)

def parse_yc(page: str) -> list[Event]:
    match = re.search(r'data-page="([^"]+)"', page)
    if not match:
        return []
    events = []
    for o in json.loads(html.unescape(match.group(1))).get("props", {}).get("events", []):
        if not o.get("title") or not o.get("starts_at") or not o.get("slug"):
            continue
        event = Event(source="yc", title=o["title"], starts_at=iso(o["starts_at"]), ends_at=iso(o.get("ends_at")),
                      url=f"https://events.ycombinator.com/{o['slug']}", timezone=o.get("time_zone"),
                      city=o.get("city") or o.get("public_location"), cover_url=image(o.get("cover_img_url")))
        event.topics.add("tech")
        events.append(event.tagged())
    return events


# MARK: Partiful (Next.js page data on /explore/<region>)

def parse_partiful(page: str) -> list[Event]:
    events = []
    seen = set()
    for o in objects_with(json.dumps(next_data(page)), "startDate"):
        if not o.get("id") or not o.get("title") or not o.get("startDate") or o["id"] in seen:
            continue
        if o.get("isPublic") is False or o.get("status") not in (None, "PUBLISHED"):
            continue
        seen.add(o["id"])
        maps = ((o.get("locationInfo") or {}).get("mapsInfo") or {})
        lat = lng = None
        if ll := re.search(r"sll=(-?[\d.]+),(-?[\d.]+)", maps.get("appleMapsUrl") or ""):
            lat, lng = float(ll.group(1)), float(ll.group(2))
        img = o.get("image") or {}
        events.append(Event(
            source="partiful", title=o["title"], starts_at=iso(o["startDate"]), ends_at=iso(o.get("endDate")),
            url=f"https://partiful.com/e/{o['id']}", description=text(o.get("description")), timezone=o.get("timezone"),
            city=maps.get("approximateLocation"), lat=lat, lng=lng, cover_url=image(img.get("url") or (img.get("upload") or {}).get("url")),
            guest_count=o.get("goingGuestCount"),
        ).tagged())
    return events


# MARK: Funcheap (RSS: the date leads the title, "10/31/26: ...")

def parse_funcheap(feed: str, city: str) -> list[Event]:
    events = []
    for item in re.findall(r"<item>(.*?)</item>", feed, re.S):
        def tag(name: str) -> str:
            m = re.search(rf"<{name}>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</{name}>", item, re.S)
            return html.unescape(m.group(1).strip()) if m else ""
        title, link = tag("title"), tag("link")
        match = re.match(r"(\d{1,2})/(\d{1,2})/(\d{2}):\s*(.+?)\s*-?\s*$", title)
        if not match or not link:
            continue
        month, day, year, name = int(match.group(1)), int(match.group(2)), 2000 + int(match.group(3)), match.group(4)
        categories = " ".join(re.findall(r"<category><!\[CDATA\[(.*?)\]\]></category>", item))
        event = Event(source="funcheap", title=name, starts_at=datetime(year, month, day, 12, tzinfo=timezone.utc),
                      url=link, description=text(tag("description")), city=city,
                      online="Online" in categories and "In Person" not in categories, is_free=True)
        event.all_day = True
        if re.search(r"Food|Drink|Beer|Wine", categories):
            event.topics.add("food")
        events.append(event.tagged())
    return events


# MARK: Eventbrite, Meetup, AllEvents (schema.org, one page per city and topic)

def city_pages(place) -> list[tuple[str, str, str | None]]:
    """(source, url, topic the page is about) for one featured city."""
    pages = []
    if place.eventbrite:
        pages += [("eventbrite", f"https://www.eventbrite.com/d/{place.eventbrite}/tech-events/", "tech"),
                  ("eventbrite", f"https://www.eventbrite.com/d/{place.eventbrite}/food-and-drink--events/", "food"),
                  ("eventbrite", f"https://www.eventbrite.com/d/{place.eventbrite}/hackathon/", None)]
    if place.meetup:
        pages += [("meetup", f"https://www.meetup.com/find/?location={quote(place.meetup)}&source=EVENTS&categoryId=546", "tech")]
    if place.allevents:
        # AllEvents' topic pages are loose (a Halloween party on "tech"), so its wording decides the topic.
        pages += [("allevents", f"https://allevents.in/{quote(place.allevents)}/tech", None),
                  ("allevents", f"https://allevents.in/{quote(place.allevents)}/food-drinks", None)]
    return pages


def parse_listing(page: str, source: str, topic: str | None) -> list[Event]:
    events = [e for node in ld_events(page) if (e := from_ld(node, source))]
    for event in events:
        if topic:
            event.topics.add(topic)
    return events


# MARK: Collecting

def collect(http: Polite, lookup_luma) -> tuple[list[Event], dict]:
    events: list[Event] = []
    notes: dict = {}

    def note(name: str, value) -> None:
        notes[name] = notes.get(name, 0) + value if isinstance(value, int) and isinstance(notes.get(name, 0), int) else value

    try:
        found, links = parse_cerebralvalley(http.get(CEREBRAL_VALLEY))
        events += found
        note("cerebralvalley", len(found))
        # Its Luma-hosted events, read once each so they book through Luma.
        for slug in sorted(links)[:30]:
            try:
                if event := lookup_luma(slug):
                    event.sources.add("cerebralvalley")
                    events.append(event)
            except Blocked:
                break
            except Exception:
                continue
    except Exception as error:
        note("cerebralvalley", f"error: {str(error)[:200]}")

    for name, read in (("yc", lambda: parse_yc(http.get(YC))),):
        try:
            found = read()
            events += found
            note(name, len(found))
        except Exception as error:
            note(name, f"error: {str(error)[:200]}")

    for place in FEATURED:
        jobs: list[tuple[str, callable]] = []
        if place.partiful:
            jobs.append(("partiful", lambda p=place: parse_partiful(http.get(f"https://partiful.com/explore/{p.partiful}"))))
        if place.funcheap:
            jobs.append(("funcheap", lambda p=place: parse_funcheap(http.get(p.funcheap, accept="application/rss+xml"), p.name)))
        for source, url, topic in city_pages(place):
            jobs.append((source, lambda s=source, u=url, t=topic: parse_listing(http.get(u), s, t)))
        for source, read in jobs:
            try:
                found = read()
                # A listing page names the city in its URL, so events without one belong to it.
                for event in found:
                    event.city = event.city or place.name
                events += found
                note(source, len(found))
            except Blocked:
                note(source, "blocked")
            except Exception as error:
                note(source, f"error: {str(error)[:120]}")
    return events, notes
