"""The collector's only way onto the network: polite, honest and quick to back off.

Each site gets its own minimum gap between requests (Luma's is 3 seconds, which held for 40 requests
in a row in testing, where bursts of 50 got blocked). The collector names itself in the user agent
and switches off Scrapling's browser disguises (stealth headers, TLS impersonation).
A site that answers 403 or 429 is left alone for the rest of the run: being blocked means stop,
never try harder.
"""

from __future__ import annotations

import json
import logging
import time
from urllib.parse import urlsplit

from scrapling.fetchers import Fetcher

log = logging.getLogger("collector")

USER_AGENT = "DoorlistBot/1.0 (+https://doorlist-site.onrender.com; events for the Doorlist app)"

# Seconds between requests to one host.
GAPS = {"api.luma.com": 3.0, "nominatim.openstreetmap.org": 1.1}
DEFAULT_GAP = 2.0


class Blocked(Exception):
    """The site said no. Stop asking it for the rest of this run."""


class Polite:
    def __init__(self) -> None:
        self.last: dict[str, float] = {}
        self.blocked: set[str] = set()
        self.requests = 0

    def get(self, url: str, *, accept: str = "text/html") -> str:
        host = urlsplit(url).netloc
        if host in self.blocked:
            raise Blocked(host)
        wait = GAPS.get(host, DEFAULT_GAP) - (time.monotonic() - self.last.get(host, 0))
        if wait > 0:
            time.sleep(wait)
        self.last[host] = time.monotonic()
        self.requests += 1
        page = Fetcher.get(url, timeout=30, retries=2, stealthy_headers=False, impersonate=None,
                           headers={"User-Agent": USER_AGENT, "Accept": accept})
        if page.status in (401, 403, 429):
            self.blocked.add(host)
            log.warning("blocked by %s (%s); leaving it alone this run", host, page.status)
            raise Blocked(host)
        if page.status >= 400:
            raise RuntimeError(f"{url} answered {page.status}")
        return page.body.decode(page.encoding or "utf-8", errors="replace")

    def json(self, url: str):
        return json.loads(self.get(url, accept="application/json"))
