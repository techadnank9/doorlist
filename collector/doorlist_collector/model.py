"""One event as Explore stores it, and the topic tags people filter by."""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from datetime import datetime
from urllib.parse import urlsplit, urlunsplit

# Where events come from, in the order the source chips show them.
SOURCES = [
    ("luma", "Luma"),
    ("cerebralvalley", "Cerebral Valley"),
    ("yc", "Y Combinator"),
    ("devpost", "Devpost"),
    ("mlh", "MLH"),
    ("lablab", "lablab.ai"),
    ("devfolio", "Devfolio"),
    ("partiful", "Partiful"),
    ("eventbrite", "Eventbrite"),
    ("meetup", "Meetup"),
    ("allevents", "AllEvents"),
    ("funcheap", "Funcheap"),
]

# The chips at the top of Explore, in order. Luma's AI and Tech are one "tech" here.
TOPICS = [
    ("tech", "Tech"),
    ("hackathons", "Hackathons"),
    ("food", "Food & Drink"),
    ("arts", "Arts"),
    ("fitness", "Fitness"),
    ("wellness", "Wellness"),
    ("climate", "Climate"),
    ("crypto", "Crypto"),
    ("books", "Books"),
    ("games", "Games"),
    ("family", "Family"),
]

# Luma category slugs to ours.
LUMA_CATEGORY_TOPICS = {
    "tech": "tech", "ai": "tech",
    "food": "food",
    "arts": "arts",
    "fitness": "fitness", "running": "fitness",
    "wellness": "wellness",
    "climate": "climate",
    "crypto": "crypto",
    "books": "books",
    "games": "games",
    "family": "family",
}

# Wording that tags an event even when Luma didn't categorise it. Kept narrow on purpose:
# a wrong tag is worse than a missing one.
_KEYWORDS = {
    "hackathons": r"\bhackathons?\b|\bhack ?(day|night|week|weekend)\b|\bbuildathon\b|\b\w+hacks\b|\bhacks \d",
    "tech": r"\b(ai|a\.i\.|llms?|gpt|agents?|machine learning|ml|startups?|founders?|developers?|devs?|engineers?|engineering"
            r"|software|saas|data science|open source|python|javascript|kubernetes|cloud|robotics|vc|venture)\b",
    "food": r"\b(dinner|brunch|breakfast|lunch|supper|tasting|wine|beer|cocktails?|happy hour|coffee|food|foodies?"
            r"|pizza|tacos?|potluck|chef|cooking|bbq|barbecue|ramen|sushi|dumplings?|bakery|pastry)\b",
}


def keyword_topics(title: str, description: str | None) -> set[str]:
    """Topics the wording supports. Hackathons are always tech too."""
    text = f"{title}\n{description or ''}".lower()
    found = {topic for topic, pattern in _KEYWORDS.items() if re.search(pattern, text)}
    # The title alone decides "food" when the description is long: a sponsored dinner line at the
    # bottom of a conference page shouldn't make it a food event.
    if "food" in found and description and len(description) > 600 and not re.search(_KEYWORDS["food"], title.lower()):
        found.discard("food")
    if "hackathons" in found:
        found.add("tech")
    return found


_LUMA_LINK = re.compile(r"https?://(?:www\.)?(?:lu\.ma|luma\.com)/(?!event/|discover|signin|create|home|calendar|user/)([A-Za-z0-9_-]{3,})")


def canonical_url(url: str) -> str:
    """The link without tracking, fragments or a trailing slash, so two sites linking the same page agree."""
    parts = urlsplit(url.strip())
    host = parts.netloc.lower().removeprefix("www.")
    if host == "lu.ma":
        host = "luma.com"
    return urlunsplit(("https", host, parts.path.rstrip("/") or "/", "", ""))


def luma_slug(url: str | None) -> str | None:
    """The Luma page an outside link points at, e.g. "data-outpost-2026"."""
    match = _LUMA_LINK.match(url or "")
    return match.group(1) if match else None


def title_key(title: str, starts_at: datetime) -> str:
    """Same event, different site: lowercase letters and digits of the title, plus the start day."""
    flat = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode().lower()
    return re.sub(r"[^a-z0-9]", "", flat)[:80] + "@" + starts_at.strftime("%Y-%m-%d")


@dataclass
class Event:
    source: str                  # where this sighting came from: "luma", "devpost", ...
    title: str
    starts_at: datetime          # always timezone-aware
    url: str
    luma_id: str | None = None   # evt-..., when the event lives on Luma
    ends_at: datetime | None = None
    description: str | None = None
    timezone: str | None = None
    city: str | None = None
    lat: float | None = None
    lng: float | None = None
    online: bool = False
    all_day: bool = False        # the site gave a date but no time
    cover_url: str | None = None
    is_free: bool | None = None
    sold_out: bool | None = None
    guest_count: int | None = None
    topics: set[str] = field(default_factory=set)
    sources: set[str] = field(default_factory=set)
    enriched: bool = False

    def __post_init__(self) -> None:
        self.title = re.sub(r"\s+", " ", self.title).strip()
        # The app's in-app browser only loads https; nearly every event site serves both.
        if self.url.startswith("http://"):
            self.url = "https://" + self.url[len("http://"):]
        self.sources.add(self.source)

    @property
    def id(self) -> str:
        return f"luma:{self.luma_id}" if self.luma_id else f"url:{canonical_url(self.url)}"

    @property
    def title_key(self) -> str:
        return title_key(self.title, self.starts_at)

    def tagged(self) -> "Event":
        self.topics |= keyword_topics(self.title, self.description)
        return self

    def merge(self, other: "Event") -> "Event":
        """Combines two sightings of the same event: known values win over unknown, topics and sources add up.
        A Luma sighting's link and id win, since Luma events book in one tap."""
        for name in ("ends_at", "timezone", "city", "lat", "lng", "cover_url"):
            if getattr(self, name) is None and getattr(other, name) is not None:
                setattr(self, name, getattr(other, name))
        # These change while an event fills up, so the latest sighting that knows them wins.
        for name in ("is_free", "sold_out", "guest_count"):
            if getattr(other, name) is not None:
                setattr(self, name, getattr(other, name))
        if other.description and len(other.description) > len(self.description or ""):
            self.description = other.description
        if other.luma_id and not self.luma_id:
            self.luma_id, self.url = other.luma_id, other.url
        if self.all_day and not other.all_day:
            self.starts_at, self.all_day = other.starts_at, False
        self.online = self.online and other.online
        self.topics |= other.topics
        self.sources |= other.sources
        self.enriched = self.enriched or other.enriched
        return self
