"""Reading helpers the site parsers share."""

from __future__ import annotations

import html
import json
import re
from datetime import date, datetime, time, timezone

from ..model import Event


def ld_events(page: str) -> list[dict]:
    """Every schema.org Event in a page's JSON-LD, including ones inside ItemLists."""
    found: list[dict] = []

    def walk(node) -> None:
        if isinstance(node, list):
            for item in node:
                walk(item)
        elif isinstance(node, dict):
            kind = node.get("@type")
            kinds = kind if isinstance(kind, list) else [kind]
            if any(isinstance(k, str) and k.endswith("Event") for k in kinds):
                found.append(node)
                return
            for key in ("itemListElement", "item", "@graph"):
                if key in node:
                    walk(node[key])

    for block in re.findall(r'<script[^>]*application/ld\+json[^>]*>(.*?)</script>', page, re.S):
        try:
            walk(json.loads(block))
        except ValueError:
            continue
    return found


def next_data(page: str) -> dict:
    match = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.*?)</script>', page, re.S)
    return json.loads(match.group(1)) if match else {}


def objects_with(text: str, key: str) -> list[dict]:
    """JSON objects embedded anywhere in a page (React payloads, data attributes) that contain `key`.
    Walks out from each occurrence to the enclosing braces, so it doesn't depend on the page's layout."""
    out: list[dict] = []
    seen: set[int] = set()
    needle = f'"{key}"'
    start = 0
    while (i := text.find(needle, start)) != -1:
        start = i + 1
        depth, j = 0, i
        while j > 0:
            j -= 1
            c = text[j]
            if c == "}":
                depth += 1
            elif c == "{":
                if depth == 0:
                    break
                depth -= 1
        if j in seen:
            continue
        seen.add(j)
        try:
            obj, _ = json.JSONDecoder().raw_decode(text, j)
        except ValueError:
            continue
        if isinstance(obj, dict):
            out.append(obj)
    return out


def iso(value: str | None) -> datetime | None:
    """An ISO time; a date alone becomes that day with all_day set by the caller."""
    if not value:
        return None
    value = value.strip()
    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return datetime.combine(date.fromisoformat(value), time(12), tzinfo=timezone.utc)
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def date_only(value: str | None) -> bool:
    return bool(value) and bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", value.strip()))


def text(value) -> str | None:
    """Plain text from a field that may hold HTML and entities."""
    if not isinstance(value, str) or not value.strip():
        return None
    return re.sub(r"\s+\n", "\n", html.unescape(re.sub(r"<[^>]+>", " ", value))).strip()[:2000] or None


def image(value) -> str | None:
    if isinstance(value, list):
        value = value[0] if value else None
    if isinstance(value, dict):
        value = value.get("url")
    if not isinstance(value, str) or not value.startswith(("http", "//")):
        return None
    return "https:" + value if value.startswith("//") else value


def from_ld(node: dict, source: str) -> Event | None:
    """A schema.org Event as an Explore event."""
    name, start, url = text(node.get("name")), node.get("startDate"), node.get("url")
    if not name or not start or not url:
        return None
    location = node.get("location") or {}
    if isinstance(location, list):
        location = location[0] if location else {}
    online = "Online" in str(node.get("eventAttendanceMode", "")) or location.get("@type") == "VirtualLocation"
    geo = location.get("geo") or {}
    address = location.get("address") or {}
    if isinstance(address, str):
        address = {"addressLocality": address}
    city = ", ".join(x for x in (address.get("addressLocality"), address.get("addressRegion")) if x) or None
    offers = node.get("offers") or {}
    if isinstance(offers, list):
        offers = offers[0] if offers else {}
    price = offers.get("price") if isinstance(offers, dict) else None
    try:
        lat = float(geo["latitude"]) if geo.get("latitude") not in (None, "") else None
        lng = float(geo["longitude"]) if geo.get("longitude") not in (None, "") else None
    except (TypeError, ValueError):
        lat = lng = None
    event = Event(
        source=source, title=name, starts_at=iso(start), ends_at=iso(node.get("endDate")) if node.get("endDate") else None,
        url=url, description=text(node.get("description")), city=city, lat=lat, lng=lng, online=online,
        cover_url=image(node.get("image")),
        is_free=(float(price) == 0) if isinstance(price, (int, float, str)) and str(price).replace(".", "", 1).isdigit() else None,
    )
    event.all_day = date_only(start)
    return event.tagged()
