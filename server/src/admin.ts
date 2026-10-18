import type { Context, Hono } from "hono";
import { getCookie, setCookie } from "hono/cookie";
import { streamSSE } from "hono/streaming";
import { listeners, summary, type UsageRow } from "./meter.js";

/**
 * /admin: what Doorlist costs, live. The page loads one summary, then the
 * server pushes each new usage row over SSE as it's written, so watching it
 * costs one idle connection, not a poll loop.
 */
export function mountAdmin(app: Hono) {
  const token = () => process.env.ADMIN_TOKEN || "";
  const allowed = (c: Context) => Boolean(token()) && getCookie(c, "doorlist_admin") === token();

  app.get("/admin", (c) => {
    const given = c.req.query("token");
    if (given && token() && given === token()) {
      setCookie(c, "doorlist_admin", given, {
        httpOnly: true, sameSite: "Strict", secure: c.req.url.startsWith("https"), path: "/admin", maxAge: 30 * 86_400,
      });
      return c.redirect("/admin");
    }
    if (!allowed(c)) return c.text("Not found", 404);
    return c.html(page);
  });

  app.get("/admin/summary.json", async (c) => (allowed(c) ? c.json(await summary()) : c.text("Not found", 404)));

  app.get("/admin/stream", (c) => {
    if (!allowed(c)) return c.text("Not found", 404);
    return streamSSE(c, async (s) => {
      const push = (row: UsageRow) => void s.writeSSE({ event: "usage", data: JSON.stringify(row) });
      listeners.add(push);
      s.onAbort(() => {
        listeners.delete(push);
      });
      while (!s.aborted) {
        await s.sleep(25_000);
        if (!s.aborted) await s.writeSSE({ event: "ping", data: "" });
      }
      listeners.delete(push);
    });
  });
}

const page = /* html */ `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Doorlist costs</title>
<style>
  :root {
    --bg: #f6f5f2; --panel: #ffffff; --ink: #1b1a17; --muted: #6b675f; --line: #e6e2da;
    --good: #15803d; --flash: #fff4e5;
    color-scheme: light dark;
  }
  @media (prefers-color-scheme: dark) {
    :root { --bg: #141311; --panel: #1d1c19; --ink: #f2efe8; --muted: #a39e94; --line: #2e2c27; --good: #4ade80; --flash: #2a2118; }
  }
  * { box-sizing: border-box; }
  body { margin: 0; background: var(--bg); color: var(--ink); font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif; }
  main { max-width: 1080px; margin: 0 auto; padding: 32px 20px 64px; }
  header { display: flex; align-items: baseline; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 24px; }
  h1 { font-size: 22px; letter-spacing: -0.01em; margin: 0; }
  .live { color: var(--muted); font-size: 13px; display: flex; align-items: center; gap: 8px; }
  .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--muted); }
  .dot.on { background: var(--good); }
  .figures { display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 12px; margin-bottom: 28px; }
  .figure { background: var(--panel); border-radius: 14px; padding: 16px 18px; }
  .figure b { display: block; font-size: 28px; font-weight: 650; letter-spacing: -0.02em; font-variant-numeric: tabular-nums; }
  .figure span { color: var(--muted); font-size: 13px; }
  .split { display: flex; height: 8px; border-radius: 4px; overflow: hidden; background: var(--line); margin: 6px 0 8px; }
  .split i { display: block; height: 100%; }
  .legend { display: flex; gap: 16px; color: var(--muted); font-size: 13px; flex-wrap: wrap; margin-bottom: 28px; }
  .legend em { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 6px; vertical-align: -1px; }
  h2 { font-size: 15px; margin: 0 0 10px; }
  .grid { display: grid; grid-template-columns: 1.6fr 1fr; gap: 20px; align-items: start; }
  .table { background: var(--panel); border-radius: 14px; overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: 10px 14px; border-bottom: 1px solid var(--line); font-variant-numeric: tabular-nums; white-space: nowrap; }
  th { color: var(--muted); font-weight: 500; font-size: 12px; }
  td.n, th.n { text-align: right; }
  tr:last-child td { border-bottom: 0; }
  .feed { list-style: none; margin: 0; padding: 0; background: var(--panel); border-radius: 14px; }
  .feed li { display: grid; grid-template-columns: 44px 1fr auto; gap: 10px; padding: 10px 14px; border-bottom: 1px solid var(--line); font-size: 13px; }
  .feed li:last-child { border-bottom: 0; }
  .feed time, .feed .who { color: var(--muted); }
  .feed .cost { font-variant-numeric: tabular-nums; }
  .new { animation: flash 1.2s ease-out; }
  @keyframes flash { from { background: var(--flash); } to { background: transparent; } }
  .empty { color: var(--muted); padding: 18px 14px; display: block; }
  @media (max-width: 820px) { .figures { grid-template-columns: repeat(2, minmax(0, 1fr)); } .grid { grid-template-columns: 1fr; } }
  @media (prefers-reduced-motion: reduce) { .new { animation: none; } }
</style>
</head>
<body>
<main>
  <header>
    <h1>What Doorlist costs</h1>
    <div class="live"><span class="dot" id="dot"></span><span id="status">Connecting</span></div>
  </header>

  <section class="figures">
    <div class="figure"><b id="today">–</b><span>Today</span></div>
    <div class="figure"><b id="last30">–</b><span>Last 30 days</span></div>
    <div class="figure"><b id="projected">–</b><span>Projected for a month</span></div>
    <div class="figure"><b id="perSearch">–</b><span>Average per search</span></div>
  </section>

  <div class="split" id="split"></div>
  <div class="legend" id="legend"></div>

  <div class="grid">
    <section>
      <h2>By person, last 30 days</h2>
      <div class="table">
        <table>
          <thead><tr><th>Person</th><th class="n">Searches</th><th class="n">Voice</th><th class="n">Per search</th><th class="n">Today</th><th class="n">30 days</th></tr></thead>
          <tbody id="people"><tr><td class="empty" colspan="6">No usage yet.</td></tr></tbody>
        </table>
      </div>
    </section>
    <section>
      <h2>Live</h2>
      <ul class="feed" id="feed"><li class="empty">Waiting for the next call.</li></ul>
    </section>
  </div>
</main>
<script>
  const colors = { openai: "#c2410c", exa: "#2563eb", elevenlabs: "#7c3aed" };
  const names = { openai: "OpenAI", exa: "Exa", elevenlabs: "ElevenLabs" };
  const $ = (id) => document.getElementById(id);
  const money = (v) => v >= 1 ? "$" + v.toFixed(2) : v >= 0.01 ? "$" + v.toFixed(3) : v > 0 ? "$" + v.toFixed(4) : "$0";
  const esc = (s) => String(s).replace(/[&<>"']/g, (ch) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[ch]);
  const who = (w) => {
    const i = w.indexOf(":");
    const kind = w.slice(0, i), id = w.slice(i + 1);
    return (kind === "user" ? "Apple user " : "Guest ") + esc(id.replace(/[^A-Za-z0-9]/g, "").slice(-6));
  };
  const ago = (ts) => {
    const s = Math.max(0, Math.round((Date.now() - ts) / 1000));
    return s < 60 ? s + "s" : s < 3600 ? Math.round(s / 60) + "m" : s < 86400 ? Math.round(s / 3600) + "h" : Math.round(s / 86400) + "d";
  };
  let data = null;

  function render() {
    const t = data.totals;
    $("today").textContent = money(t.today);
    $("last30").textContent = money(t.last30);
    $("projected").textContent = money(t.projectedMonth);
    $("perSearch").textContent = t.searches ? money(t.perSearch) : "–";
    const sum = Object.values(t.byProvider).reduce((a, b) => a + b, 0) || 1;
    $("split").innerHTML = Object.entries(t.byProvider).map(([k, v]) => '<i style="width:' + (v / sum * 100) + '%;background:' + colors[k] + '"></i>').join("");
    $("legend").innerHTML = Object.entries(t.byProvider).map(([k, v]) => '<span><em style="background:' + colors[k] + '"></em>' + names[k] + " " + money(v) + "</span>").join("") +
      "<span>" + t.people + (t.people === 1 ? " person" : " people") + ", " + t.searches + (t.searches === 1 ? " search" : " searches") + "</span>";
    $("people").innerHTML = data.people.length ? data.people.map((p) =>
      "<tr><td>" + who(p.who) + "</td><td class=n>" + p.searches + "</td><td class=n>" + p.voiceMinutes.toFixed(1) + " min</td><td class=n>" +
      (p.searches ? money(p.perSearch) : "–") + "</td><td class=n>" + money(p.today) + "</td><td class=n>" + money(p.last30) + "</td></tr>").join("")
      : '<tr><td class="empty" colspan="6">No usage yet.</td></tr>';
    $("feed").innerHTML = data.recent.length ? data.recent.map((r) => row(r, false)).join("") : '<li class="empty">Waiting for the next call.</li>';
  }

  function row(r, fresh) {
    const what = r.provider === "openai"
      ? (r.webSearches ? r.webSearches + " web searches, " : "") + ((r.inputTokens + r.outputTokens) / 1000).toFixed(1) + "k tokens"
      : r.provider === "elevenlabs" ? Math.round(r.audioSeconds) + "s of audio" : "page search";
    return "<li" + (fresh ? ' class="new"' : "") + "><time>" + ago(r.ts) + "</time><span><b>" + names[r.provider] + "</b> " + what +
      ' <span class="who">· ' + who(r.who) + '</span></span><span class="cost">' + money(r.cost) + "</span></li>";
  }

  async function load() {
    const res = await fetch("/admin/summary.json");
    if (res.ok) { data = await res.json(); render(); }
  }

  load();
  const es = new EventSource("/admin/stream");
  es.onopen = () => { $("dot").className = "dot on"; $("status").textContent = "Live"; };
  es.onerror = () => { $("dot").className = "dot"; $("status").textContent = "Reconnecting"; };
  let pending = null;
  es.addEventListener("usage", (e) => {
    const feed = $("feed");
    if (feed.querySelector(".empty")) feed.innerHTML = "";
    feed.insertAdjacentHTML("afterbegin", row(JSON.parse(e.data), true));
    while (feed.children.length > 25) feed.lastElementChild.remove();
    // Totals refresh at most once a second however busy it gets.
    clearTimeout(pending);
    pending = setTimeout(load, 1000);
  });
  setInterval(() => data && render(), 30000);
</script>
</body>
</html>`;
