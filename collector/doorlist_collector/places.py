"""The places Explore can show.

Every city Luma lists is a place (read from Luma each run), plus two of our own: the Bay Area,
which Luma doesn't list, and Online. The featured ones lead the picker and are also searched on
the other sites, which need their own way of naming the city.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Place:
    id: str
    name: str
    lat: float
    lng: float
    radius_km: float = 40
    luma_id: str | None = None
    featured: int | None = None
    # How the other sites name this city. Missing means that site isn't searched here.
    eventbrite: str | None = None
    meetup: str | None = None
    allevents: str | None = None
    partiful: str | None = None
    funcheap: str | None = None


# Our ids for Luma's slugs where they differ, so the app's ids read naturally.
LUMA_SLUG_IDS = {"la": "los-angeles", "nyc": "new-york", "dc": "washington-dc", "sd": "san-diego"}

FEATURED: list[Place] = [
    Place("sf", "San Francisco", 37.7749, -122.4194, 20, featured=1,
          eventbrite="ca--san-francisco", meetup="us--ca--San Francisco", allevents="san francisco",
          partiful="sf", funcheap="https://sf.funcheap.com/feed/"),
    # Luma has no Bay Area; this circle reaches Santa Rosa, Sacramento's edge, Santa Cruz and San Jose.
    Place("bay-area", "Bay Area", 37.60, -122.20, 80, featured=2),
    Place("las-vegas", "Las Vegas", 36.1699, -115.1398, 30, featured=3,
          eventbrite="nv--las-vegas", meetup="us--nv--Las Vegas", allevents="las vegas"),
    Place("los-angeles", "Los Angeles", 34.0522, -118.2437, 45, featured=4,
          eventbrite="ca--los-angeles", meetup="us--ca--Los Angeles", allevents="los angeles", partiful="la"),
    Place("new-york", "New York", 40.7128, -74.0060, 35, featured=5,
          eventbrite="ny--new-york", meetup="us--ny--New York", allevents="new york", partiful="nyc"),
    Place("seattle", "Seattle", 47.6062, -122.3321, 35, featured=6,
          eventbrite="wa--seattle", meetup="us--wa--Seattle", allevents="seattle"),
    Place("austin", "Austin", 30.2672, -97.7431, 35, featured=7,
          eventbrite="tx--austin", meetup="us--tx--Austin", allevents="austin"),
    Place("boston", "Boston", 42.3601, -71.0589, 35, featured=8,
          eventbrite="ma--boston", meetup="us--ma--Boston", allevents="boston"),
    Place("chicago", "Chicago", 41.8781, -87.6298, 35, featured=9,
          eventbrite="il--chicago", meetup="us--il--Chicago", allevents="chicago"),
    Place("london", "London", 51.5074, -0.1278, 35, featured=10,
          eventbrite="united-kingdom--london", allevents="london"),
]

# Hackathons and talks with no venue. Picked like a city; the server shows online events here only.
ONLINE = Place("online", "Online", 0, 0, 0, featured=11)


def luma_places(bootstrap: dict) -> list[Place]:
    """Every city on Luma's discover page, with the featured cities' extra names attached."""
    featured = {p.name: p for p in FEATURED}
    out: list[Place] = []
    for entry in bootstrap.get("places", []):
        info = entry.get("place") or {}
        coordinate = info.get("coordinate") or {}
        if not info.get("api_id") or coordinate.get("latitude") is None:
            continue
        name = info.get("name") or ""
        known = featured.get(name)
        if known:
            known.luma_id = info["api_id"]
            out.append(known)
        else:
            slug = info.get("slug") or name.lower().replace(" ", "-")
            out.append(Place(LUMA_SLUG_IDS.get(slug, slug), name, coordinate["latitude"], coordinate["longitude"],
                             luma_id=info["api_id"]))
    # Featured places Luma doesn't list (the Bay Area) still belong in the picker.
    listed = {p.id for p in out}
    out += [p for p in FEATURED if p.id not in listed]
    return out + [ONLINE]
