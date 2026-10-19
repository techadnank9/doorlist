"""Every parser against a real page saved on 2026-10-19. When a site redesigns, refresh its fixture
and these say exactly which fields stopped coming through."""

import json
import re
from datetime import datetime, timezone
from pathlib import Path

from doorlist_collector.model import Event, canonical_url, keyword_topics, luma_slug
from doorlist_collector.places import luma_places
from doorlist_collector.sources import hackathons, luma, sites
from doorlist_collector.store import dedupe

F = Path(__file__).parent / "fixtures"


def read(name):
    return (F / name).read_text()


def complete(events, *, coords=True, cover=True):
    """Every event has what a card needs."""
    assert events
    for e in events:
        assert e.title and e.url.startswith("https://") and e.starts_at.tzinfo
        if coords:
            assert e.lat is not None and e.lng is not None, e.title
        if cover:
            assert e.cover_url and e.cover_url.startswith("https://"), e.title


# MARK: Luma

def test_luma_ics_has_links_coordinates_and_clean_descriptions():
    events = luma.parse_ics(read("luma.ics"))
    assert len(events) == 50
    complete(events, cover=False)
    first = events[0]
    assert first.luma_id.startswith("evt-") and first.id == f"luma:{first.luma_id}"
    assert first.url == "https://luma.com/wjmtvwvw"
    assert not first.description.startswith("Get up-to-date")


def test_luma_ics_all_day_event():
    ics = "BEGIN:VEVENT\nDTSTART;VALUE=DATE:20261020\nDTEND;VALUE=DATE:20261021\nUID:evt-abc123@events.lu.ma\nSUMMARY:Open Studios\nDESCRIPTION:Get up-to-date information at: https://luma.com/open\nEND:VEVENT"
    [event] = luma.parse_ics(ics)
    assert event.all_day and event.starts_at.day == 20 and event.url == "https://luma.com/open"


def test_luma_discover_page_and_cursor():
    events, cursor = luma.parse_discover(json.loads(read("luma_discover_city.json")))
    assert len(events) == 20 and cursor
    complete(events)
    assert all(e.is_free is not None for e in events)


def test_luma_food_category_by_coordinates_is_food():
    events, _ = luma.parse_discover(json.loads(read("luma_discover_food.json")))
    titles = " ".join(e.title.lower() for e in events)
    assert "tasting" in titles or "dinner" in titles or "brunch" in titles


def test_luma_event_brings_its_categories():
    event = luma.parse_event(json.loads(read("luma_event.json")))
    assert event.enriched and "tech" in event.topics  # Luma's "AI" category is our Tech


def test_places_cover_every_luma_city_plus_bay_area_and_online():
    places = luma_places(json.loads(read("bootstrap.json")))
    ids = {p.id for p in places}
    assert {"sf", "bay-area", "las-vegas", "new-york", "los-angeles", "online"} <= ids
    assert len(places) == 89
    sf = next(p for p in places if p.id == "sf")
    assert sf.luma_id and sf.featured == 1 and sf.eventbrite


# MARK: Hackathons

def test_devpost():
    events = hackathons.parse_devpost(json.loads(read("devpost.json")))
    complete(events, coords=False)
    assert all({"hackathons", "tech"} <= e.topics and e.all_day for e in events)
    assert hackathons.devpost_start("Jan 25 - Feb 11, 2027") == datetime(2027, 1, 25, 12, tzinfo=timezone.utc)
    assert hackathons.devpost_start("Nov 01, 2026").day == 1
    # Running hackathons must not look finished: the end comes from the same range.
    assert hackathons.devpost_end("Jan 25 - Feb 11, 2027") == datetime(2027, 2, 11, 23, 59, tzinfo=timezone.utc)
    assert hackathons.devpost_end("Oct 23 - 25, 2026").day == 25
    assert hackathons.devpost_end("Nov 01, 2026").day == 1


def test_mlh():
    events = hackathons.parse_mlh(read("mlh.html"))
    assert len(events) > 50
    complete(events, coords=False, cover=False)
    # A few have neither a background nor a logo yet; the app shows a placeholder for those.
    assert sum(e.cover_url is not None for e in events) > len(events) * 0.9
    cal = next(e for e in events if e.title == "Cal Hacks 13.0")
    assert cal.city == "San Francisco, California" and cal.url == "https://calhacks.io/"


def test_lablab_and_devfolio_are_online():
    lab = hackathons.parse_lablab(read("lablab.html"))
    folio = hackathons.parse_devfolio(read("devfolio.html"))
    complete(lab, coords=False)
    assert folio and all(e.online and "hackathons" in e.topics for e in lab + folio)


# MARK: Sites

def test_cerebral_valley_tags_hackathons_and_finds_luma_links():
    events, links = sites.parse_cerebralvalley(read("cerebralvalley.html"))
    assert len(events) == 20
    complete(events, coords=False, cover=False)
    assert any(e.title == "Intelligence at Work Hackathon" and "hackathons" in e.topics for e in events)
    assert "data-outpost-2026" in links


def test_yc():
    events = sites.parse_yc(read("yc.html"))
    complete(events, coords=False)
    assert all(e.url.startswith("https://events.ycombinator.com/") and "tech" in e.topics for e in events)


def test_partiful_has_coordinates():
    events = sites.parse_partiful(read("partiful.html"))
    assert len(events) > 20
    complete(events, coords=False)
    # Hosts can hide the address until you RSVP; most still give the neighbourhood.
    assert sum(e.lat is not None for e in events) > len(events) * 0.8


def test_funcheap_reads_the_date_from_the_title():
    events = sites.parse_funcheap(read("funcheap.xml"), "San Francisco")
    complete(events, coords=False, cover=False)
    assert all(e.all_day and e.is_free and not re.match(r"\d+/\d+/\d+", e.title) for e in events)


def test_schema_org_listings():
    for name, source in (("eventbrite.html", "eventbrite"), ("meetup.html", "meetup"), ("allevents.html", "allevents")):
        events = sites.parse_listing(read(name), source, None)
        assert len(events) >= 10, name
        complete(events, coords=False, cover=False)
    brite = sites.parse_listing(read("eventbrite.html"), "eventbrite", "tech")
    assert sum(e.lat is not None for e in brite) > len(brite) / 2


# MARK: Model

def test_topics_from_wording():
    assert keyword_topics("Cline, Parallel & Composio Hackathon", None) >= {"hackathons", "tech"}
    assert "food" in keyword_topics("Sake Tasting @ Sakae Sushi", None)
    assert "tech" not in keyword_topics("Halloween at Public Works", "A night of house music")
    # A dinner line deep in a long conference description doesn't make it a food event.
    assert "food" not in keyword_topics("AI Infra Summit", "x " * 400 + "Dinner provided.")


def test_links():
    assert canonical_url("https://lu.ma/abc?utm_source=cv#x") == "https://luma.com/abc"
    assert luma_slug("https://luma.com/data-outpost-2026?utm_source=cv") == "data-outpost-2026"
    assert luma_slug("https://luma.com/discover") is None


def test_same_event_on_two_sites_becomes_one_luma_event():
    start = datetime(2026, 10, 23, 15, 30, tzinfo=timezone.utc)
    cv = Event(source="cerebralvalley", title="Intelligence at Work Hackathon", starts_at=start,
               url="https://cerebralvalley.ai/e/intelligence-at-work-hackathon", topics={"hackathons"})
    on_luma = Event(source="luma", luma_id="evt-abc", title="Intelligence at Work  Hackathon", starts_at=start,
                    url="https://luma.com/iaw", cover_url="https://images.lumacdn.com/x.png")
    [merged] = dedupe([cv, on_luma])
    assert merged.id == "luma:evt-abc" and merged.url == "https://luma.com/iaw"
    assert merged.sources == {"luma", "cerebralvalley"} and "hackathons" in merged.topics
