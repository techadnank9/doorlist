/** Event link rules, kept in step with the app's EventLink.swift. */

export type Platform = "luma" | "partiful" | "eventbrite" | "web";

export function platformOf(host: string): Platform {
  const h = host.toLowerCase();
  if (h === "lu.ma" || h.endsWith("luma.com")) return "luma";
  if (h.endsWith("partiful.com")) return "partiful";
  if (/(^|\.)eventbrite\.[a-z.]+$/.test(h)) return "eventbrite";
  return "web";
}

const lumaReserved = new Set(["discover", "home", "signin", "calendar", "user", "settings", "create", "explore"]);

/** The slug or evt- id in a Luma link, or null. */
export function lumaReference(raw: string): string | null {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (platformOf(url.hostname) !== "luma") return null;
  const parts = url.pathname.split("/").filter(Boolean);
  if (parts[0] && ["e", "event"].includes(parts[0].toLowerCase())) parts.shift();
  const slug = parts[0];
  if (!slug || lumaReserved.has(slug.toLowerCase())) return null;
  return slug;
}

/** An event's own page, not a listing, search or profile page. */
export function isEventPage(raw: string): boolean {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (!/^https?:$/.test(url.protocol)) return false;
  const path = url.pathname.toLowerCase();
  switch (platformOf(url.hostname)) {
    case "luma":
      return lumaReference(raw) !== null;
    case "partiful":
      return path.startsWith("/e/") && path.length > 3;
    case "eventbrite":
      return path.includes("/e/");
    case "web":
      if (url.hostname.includes("meetup.com")) return /\/events\/\d+/.test(path);
      return path.length > 1;
  }
}

/** Same event, different link dressing: no query, no fragment, no www, no trailing slash. */
export function normalize(raw: string): string {
  try {
    const url = new URL(raw);
    url.hostname = url.hostname.toLowerCase().replace(/^www\./, "");
    if (url.hostname === "lu.ma") url.hostname = "luma.com";
    url.search = "";
    url.hash = "";
    url.protocol = "https:";
    return url.toString().replace(/\/+$/, "");
  } catch {
    return raw.toLowerCase();
  }
}
