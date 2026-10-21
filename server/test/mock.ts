/**
 * Local stand-ins for everything Doorlist talks to, for testing without keys
 * or real bookings:
 *   /openai/responses, /exa/search, /elevenlabs/speech-to-text  (fake upstreams)
 *   /events/*  practice event pages with real-looking RSVP forms
 * Run: npm run mock   (port 8790). Point the server at it with the *_BASE_URL vars.
 */
import { serve } from "@hono/node-server";
import { Hono } from "hono";

const port = Number(process.env.MOCK_PORT ?? 8790);
const publicBase = process.env.MOCK_PUBLIC_BASE ?? `http://localhost:${port}`;
export const mock = new Hono();

const day = 86_400_000;
const at = (days: number, hour: number) => {
  const d = new Date(Date.now() + days * day);
  d.setHours(hour, 0, 0, 0);
  return d.toISOString();
};

const events = {
  "rooftop-social": { title: "Rooftop Social on Valencia", start: at(3, 19), price: 0, place: "Valencia St Rooftop, San Francisco" },
  "ai-builders": { title: "AI Builders Night", start: at(5, 18), price: 0, place: "Mission Hub, San Francisco" },
  "winter-gala": { title: "Winter Gala", start: at(9, 20), price: 45, place: "The Palace, San Francisco" },
};

// MARK: Fake ElevenLabs token

mock.post("/elevenlabs/single-use-token/realtime_scribe", (c) =>
  c.req.header("xi-api-key") ? c.json({ token: "sutkn_test" }) : c.json({ detail: "no key" }, 401));

// MARK: Fake OpenAI

mock.post("/openai/responses", async (c) => {
  const body = await c.req.json();
  const input = String(body.input ?? "");
  const usage = { input_tokens: 4200, input_tokens_details: { cached_tokens: 1200 }, output_tokens: 650 };

  if (body.text?.format?.type === "json_schema") {
    // Ranking pass: score by title.
    const ranked = [...input.matchAll(/^(\d+)\. ([^|]+)/gm)].map((m) => {
      const title = m[2]!.trim();
      const score = title.includes("Rooftop") ? 0.92 : title.includes("AI Builders") ? 0.78 : 0.35;
      const why = title.includes("Rooftop") ? "Saturday evening rooftop party, free, ten minutes away"
        : title.includes("AI Builders") ? "Free AI meetup Thursday, but not a party" : "Paid formal event, not what you asked";
      return { i: Number(m[1]), match: score, why };
    });
    return c.json({ output: [{ type: "message", content: [{ type: "output_text", text: JSON.stringify({ ranked }) }] }], usage });
  }

  if (Array.isArray(body.input)) {
    // A screenshot reply: the prompt and the image arrive as content parts.
    const parts = body.input[0]?.content ?? [];
    const prompt = String(parts.find((p: any) => p.type === "input_text")?.text ?? "");
    const hasImage = parts.some((p: any) => p.type === "input_image" && String(p.image_url).startsWith("data:image/"));
    const hint = prompt.match(/follow these first\):\n([^\n]*)/)?.[1];
    const text = hasImage ? (hint ? `Sure, ${hint}` : "Sounds good, what times work for you?") : "no image";
    return c.json({ output: [{ type: "message", content: [{ type: "output_text", text }] }], usage });
  }

  if (input.startsWith("You are filling in an event registration form")) {
    // Writing help: echo enough of the prompt for tests to check what went in.
    const notes = input.match(/Their notes for this answer:\n([^\n]*)/)?.[1];
    const text = notes ? `"Polished: ${notes}"` : `I build robots. (${input.includes("Robotics Hack Day") ? "saw the event" : "no event"})`;
    return c.json({ output: [{ type: "message", content: [{ type: "output_text", text }] }], usage });
  }

  const request = input.match(/request: "([^"]*)"/)?.[1] ?? "";
  if (/^(something|anything|stuff)$/i.test(request.trim()) && !input.includes("They already answered")) {
    const text = JSON.stringify({ question: "What kind of thing are you in the mood for?", options: ["A party", "A tech meetup", "Live music", "Something outdoors"] });
    return c.json({ output: [{ type: "message", content: [{ type: "output_text", text }] }], usage });
  }
  const list = [
    ...Object.entries(events).map(([slug, e], i) => ({
      title: e.title, url: `${publicBase}/events/${slug}`, start: e.start, venue: e.place, city: "San Francisco",
      price: e.price ? `$${e.price}` : "Free", is_free: e.price === 0, why: "Matches the request", match: 0.8 - i * 0.1,
    })),
    { title: "Old Event That Moved", url: `${publicBase}/events/gone`, start: at(2, 18), venue: "", city: "", price: "Free", is_free: true, why: "", match: 0.85 },
  ];
  return c.json({
    output: [
      { type: "web_search_call", status: "completed" },
      { type: "web_search_call", status: "completed" },
      { type: "message", content: [{ type: "output_text", text: "Here you go:\n" + JSON.stringify({ events: list }) }] },
    ],
    usage,
  });
});

// MARK: Fake Exa and ElevenLabs

mock.post("/exa/search", async (c) => {
  const body = await c.req.json();
  const results = body.includeDomains
    ? [{ title: "AI Builders Night", url: `${publicBase}/events/ai-builders?utm_source=exa`, highlights: ["Demos and pizza"] }]
    : [{ title: "A blog post about parties", url: `${publicBase}/`, highlights: [] }];
  return c.json({ results, costDollars: { total: 0.007 } });
});

mock.post("/elevenlabs/speech-to-text", async (c) => {
  const form = await c.req.formData();
  if (!form.get("file") || form.get("model_id") !== "scribe_v2") return c.json({ detail: "bad request" }, 400);
  return c.json({ text: "I'm bringing homemade dumplings." });
});

// MARK: Practice event pages

const shell = (title: string, start: string, price: number, place: string, body: string) => `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${title}</title>
<meta property="og:title" content="${title}">
<script type="application/ld+json">${JSON.stringify({
  "@context": "https://schema.org", "@type": "SocialEvent", name: title, startDate: start,
  endDate: new Date(Date.parse(start) + 3 * 3600_000).toISOString(), eventStatus: "https://schema.org/EventScheduled",
  location: { "@type": "Place", name: place.split(",")[0], address: { "@type": "PostalAddress", addressLocality: "San Francisco" } },
  offers: [{ "@type": "Offer", price, priceCurrency: "USD", availability: "https://schema.org/InStock" }],
})}</script>
<style>
 body{font:17px -apple-system,system-ui,sans-serif;margin:0;padding:24px;background:#fbfaf7;color:#1b1a17}
 h1{font-size:26px;margin:0 0 6px} .meta{color:#6b675f;margin-bottom:20px}
 button{font:inherit;font-weight:600;padding:12px 18px;border-radius:12px;border:0;background:#1b1a17;color:#fff;margin:4px 6px 4px 0}
 button.ghost{background:#ebe7df;color:#1b1a17}
 label{display:block;font-weight:600;margin:14px 0 6px} input,textarea,select{font:inherit;width:100%;box-sizing:border-box;padding:10px;border:1px solid #d8d3c9;border-radius:10px;background:#fff}
 .hidden{display:none} .done{font-size:22px;font-weight:700;color:#15803d;margin-top:20px}
 .check{display:flex;gap:10px;align-items:center;font-weight:500} .check input{width:auto}
</style></head><body>
<h1>${title}</h1><div class="meta">${new Date(start).toLocaleString("en-US", { weekday: "long", month: "long", day: "numeric", hour: "numeric", minute: "2-digit" })} · ${place}</div>
${body}
</body></html>`;

mock.get("/events/rooftop-social", (c) => {
  const e = events["rooftop-social"];
  return c.html(shell(e.title, e.start, e.price, e.place, `
<p>Sunset, a DJ, and too many snacks. Bring something to share.</p>
<div id="rsvp"><button class="ghost">Can't go</button><button class="ghost">Maybe</button><button id="going">Going</button></div>
<form id="form" class="hidden" onsubmit="event.preventDefault(); if (!this.reportValidity()) return; this.classList.add('hidden'); document.getElementById('done').classList.remove('hidden');">
  <label for="name">Your name</label><input id="name" autocomplete="name" required>
  <label for="phone">Phone number</label><input id="phone" type="tel" autocomplete="tel" required>
  <label for="bring">What are you bringing? *</label><textarea id="bring" required></textarea>
  <label class="check"><input type="checkbox" id="rules" required> I agree to the house rules *</label>
  <button type="submit">Submit RSVP</button>
</form>
<div id="done" class="done hidden">You're going! See the address in your texts.</div>
<script>document.getElementById('going').onclick = () => { document.getElementById('rsvp').classList.add('hidden'); document.getElementById('form').classList.remove('hidden'); };</script>`));
});

mock.get("/events/ai-builders", (c) => {
  const e = events["ai-builders"];
  return c.html(shell(e.title, e.start, e.price, e.place, `
<p>Lightning demos from people building with AI. Free, with pizza.</p>
<button id="open">Reserve a spot</button>
<form id="form" class="hidden" onsubmit="event.preventDefault(); if (!this.reportValidity()) return; this.classList.add('hidden'); document.getElementById('done').classList.remove('hidden');">
  <label for="qty">General admission · Free</label><select id="qty">${[0, 1, 2, 3, 4].map((n) => `<option>${n}</option>`).join("")}</select>
  <label for="fn">First name</label><input id="fn" autocomplete="given-name" required>
  <label for="ln">Last name</label><input id="ln" autocomplete="family-name" required>
  <label for="em">Email address</label><input id="em" type="email" autocomplete="email" required>
  <label for="em2">Confirm email</label><input id="em2" type="email" required>
  <label for="heard">How did you hear about this event?</label>
  <select id="heard" required><option value="">Select an option</option><option>Friend</option><option>Social media</option><option>Newsletter</option><option>Other</option></select>
  <button type="submit">Register</button>
</form>
<div id="done" class="done hidden">Thanks for registering! Check your email for your ticket.</div>
<script>document.getElementById('open').onclick = () => { document.getElementById('open').classList.add('hidden'); document.getElementById('form').classList.remove('hidden'); };</script>`));
});

mock.get("/events/winter-gala", (c) => {
  const e = events["winter-gala"];
  return c.html(shell(e.title, e.start, e.price, e.place, `
<p>Black tie. Dinner and dancing.</p>
<button id="open">Get tickets</button>
<div id="checkout" class="hidden">
  <label for="qty">General admission · $45.00</label><select id="qty"><option>0</option><option>1</option><option>2</option></select>
  <p><b>Order total: $45.00</b></p>
  <button>Continue</button>
</div>
<script>document.getElementById('open').onclick = () => { document.getElementById('open').classList.add('hidden'); document.getElementById('checkout').classList.remove('hidden'); };</script>`));
});

mock.get("/events/gone", (c) => c.text("Not found", 404));
mock.get("/", (c) => c.html("<p>A blog post about parties.</p>"));

if (process.env.NODE_ENV !== "test") {
  serve({ fetch: mock.fetch, port }, () => console.log(`Doorlist mock on ${publicBase}`));
}
