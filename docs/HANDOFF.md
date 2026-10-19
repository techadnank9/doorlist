# Handoff: where Doorlist stands (2026-10-19, updated the same evening)

To pick this up, open Claude Code in this folder and say: **"Read docs/HANDOFF.md and continue."**
To bring everything up locally in one go: `./scripts/dev-explore.sh` (add `--test` for tests only, `--collect` for a fresh crawl).

## Done in this round

### 1. First TestFlight build (shipped)
- Bundle ids are now `com.doorlist.app` (app), `com.doorlist.app.share` (share extension), `group.com.doorlist.app` (app group). Keychain services and the server's default `APPLE_BUNDLE_ID` moved with them.
- Signed automatically on team **S2UTA2J3GD** (Nysa Chandna's team, chosen by Adnan).
- App Store Connect record created. **0.1.0 (1) uploaded** to TestFlight.
- Two upload rejections fixed in `project.yml`: the share extension's `NSExtensionAttributes` was nested in the wrong place, and the portrait-only app now sets `UIRequiresFullScreen`.

### 2. Sign in with Apple is required (built, not yet in a TestFlight build)
- The "Continue without an account" button is gone.
- `RootView` covers the app until `Account.isSignedIn`. That covers first launch, people who skipped on build 1, sign out, account deletion, and a 401 from sync. A returning signed-out person only sees the sign-in step.
- Debug builds can still start signed in with `DOORLIST_SESSION` (the dev script mints one), because the simulator can't do Sign in with Apple.

### 3. Explore (built and tested locally)
- **Collector** (`collector/`, Python with Scrapling). It runs hourly, writes Postgres, and phones never touch the event sites. It has 17 tests on saved pages in `collector/tests/fixtures`.
  - **Luma (main source):**
    - Each city's public iCal feed. That feed is Luma's own "Subscribe" interface.
    - The discover feed for 2 pages per featured city.
    - The Tech, AI and Food & Drink categories **by coordinates**. Luma ignores a category when a city id is given; this was found and fixed.
    - Each new event read once for its cover, price and Luma categories, capped at 60 per run.
    - All 87 Luma cities: the 10 featured ones every run, the rest rotating every 6 runs.
  - **Hackathons:** Devpost (API), MLH, lablab.ai, Devfolio (online only, since its list gives no city).
  - **Other sites:** Cerebral Valley (schema.org, plus its links to Luma events, which are then read through Luma), Y Combinator, Partiful (SF, LA, NYC), Eventbrite, Meetup, AllEvents, Funcheap RSS (SF).
  - **The same event on several sites becomes one row.** Matching is by Luma id or link, then by title plus day. The Luma copy leads, so it books in one tap.
  - **Topics:** Tech (Luma's AI is merged into it), Hackathons, Food & Drink, Arts, Fitness, Wellness, Climate, Crypto, Books, Games, Family. They come from Luma's categories, the listing page's topic, and narrow keyword rules.
  - **Towns without coordinates** are geocoded once through OpenStreetMap Nominatim (1 request per second) and cached in `explore_geocache`.
  - **Politeness, deliberately:**
    - 3 seconds between Luma requests, 2 seconds for other sites.
    - It identifies itself honestly as `DoorlistBot/1.0`, with Scrapling's stealth headers and TLS impersonation switched off.
    - A 403 or 429 means it stops asking that site for the rest of the run. It never routes around blocks.
    - In testing, 50+ rapid Luma requests got blocked for about 10 minutes, while 40 requests at one every 3 seconds all succeeded.
  - **First real run:** 2,102 events from 313 requests in about 22 minutes, no blocks. By source: Luma 989, Eventbrite 282, AllEvents 267, Partiful 235, lablab 144 (mostly past, pruned), Meetup 95, MLH 92, Devpost 27, Cerebral Valley 20, Funcheap 10, YC 7, Devfolio 4.
  - **Fixed after that run:** Luma all-day events (NY and London feeds) and Devpost end dates (running hackathons had looked finished and were pruned). Both have tests; the next run picks them up.
- **Schema:** `collector/schema.sql` is the single definition. The collector runs it on every start, and the server's tests load it.
- **Server:**
  - `GET /v1/explore?place=|lat=&lng=&topic=&source=&cursor=` and `GET /v1/explore/meta`, in `server/src/explore.ts`.
  - Distance filter, with Bay Area = 80 km around 37.60,-122.20. "Online" is its own place.
  - Luma covers shrink through Luma's own image server: a 2.1 MB PNG becomes about 77 KB.
  - 10 new tests in `server/test/explore.test.ts`; they use their own Postgres schema. Full server suite: **27 of 27 pass.**
- **App:**
  - A new **Explore** tab (`App/ExploreView.swift`): place picker (Near me, featured cities, search all), topic chips, source chips, cards with cover, time, place, Free/Full/Hackathon tags and source names. Tapping a card goes into the existing booking flow. Choices are remembered between launches, covers are cached on disk, and lists page 30 at a time.
  - **Settings > Event sites > "Partiful, Cerebral Valley, Y Combinator and more"** (`App/ConnectedSitesView.swift`). You sign in once on the site's own page inside the app. Bookings share that web storage, so they start signed in. Luma stays the main, separate flow.
- **Render:** `render.yaml` has a new `doorlist-collector` cron job (hourly at :07, Python, same database). **It is not deployed yet.**

## Second round, same day: secrets, PostHog, Sentry

- **GitHub secret-scanning alerts #1 to #3 ("Google API Key").** These were not Doorlist keys. They were the public Google Maps browser keys that YC, Devfolio and Eventbrite embed in their own pages, captured in the saved test pages.
  - The keys are now scrubbed from `collector/tests/fixtures` (replaced with `AIza_REDACTED_THIRD_PARTY_KEY`), and a new test fails if one ever comes back.
  - The alerts stay open on GitHub because the keys remain in the older commit's history. Dismiss them as "Used in tests" under Security > Secret scanning, or rewrite history if you prefer.
  - A scan of the rest of the repo found no OpenAI, GitHub, AWS, Stripe, Slack, PostHog or private keys.
- **PostHog (built, key set, not yet seen working from the app):**
  - The `posthog-ios` 3.90.1 and `sentry-cocoa` 9.29.2 packages are declared in `project.yml`. **Do not add packages through Xcode or a wizard:** the `.xcodeproj` is regenerated and would drop them.
  - `App/Telemetry.swift` starts each SDK only when its key is set. There's no session replay and no automatic person profiles; events carry no answers or contact details.
  - The first event is `explore_event_opened` (sources, topic, place).
  - The key for project **673944** (US region) is in `project.yml` as `POSTHOG_API_KEY`. It's a public client key, safe in the repo.
  - A direct test event to `us.i.posthog.com` returned `200 Ok`, but PostHog answers Ok even for bad keys. **The real check is still to do:** run the app, then watch https://us.posthog.com/project/673944 turn from "Waiting for events" to received.
  - The PostHog setup wizard was stopped and never edited files. The `ai-observability` wizard you asked for (LLM analytics on the server's OpenAI calls) has not been run.
- **Sentry (code ready, projects not created):**
  - The Sentry plugin is installed for Claude Code and Cursor (`npx @sentry/agent-plugin install --yes "doorlist-y2#3fc19e9a14"`).
  - Its MCP connection still needs a one-time sign-in: run `claude` in a terminal, then `/mcp`, then authenticate `sentry`. After that, ask Claude to "create and set up Sentry projects for this application" (org `doorlist-y2`, run code `3fc19e9a14`).
  - **iOS:** set `SENTRY_DSN` in `project.yml`.
  - **Server:** `@sentry/node` 11.4.0, set up in `server/src/instrument.ts` and imported first in `index.ts`. Unexpected errors go to Sentry and the caller gets a plain 500. It's off until `SENTRY_DSN` is set on Render; `render.yaml` now lists that variable.
- **Production server:** after the OpenAI key was added on Render, `/health` still said `"search": false`. Render applies new environment variables only on a deploy, so trigger **Manual Deploy > Deploy latest commit** on `doorlist-server`, then check https://doorlist-server.onrender.com/health.
- **Stopped at the time of writing:** the app build (interrupted twice by restarts), the local collector and dev servers, local Postgres, and both wizards. `./scripts/dev-explore.sh` brings them all back.

## Not verified yet
- **Explore in the simulator.** The app builds (`BUILD SUCCEEDED`), but the simulator was still booting when this was written, so nobody has looked at the screen yet. First thing to do: `./scripts/dev-explore.sh`, then open the Explore tab.
- **Connected sites on a real site.** Signing in and then booking through each site's own page is untested.
- **Collector on Render.** It has only run from this Mac.

## Pending, in order
1. **Look at Explore in the simulator** and fix whatever looks off. Check: SF, Bay Area, Las Vegas, Near me, Online; the Hackathons and Food & Drink chips; tapping a Luma card and a non-Luma card.
2. **Render:**
   - Set `APPLE_BUNDLE_ID=com.doorlist.app` on `doorlist-server`. Until then, Sign in with Apple fails against production.
   - Add `OPENAI_API_KEY` (required for Find), and optionally `EXA_API_KEY` and `ELEVENLABS_API_KEY`. `/health` currently reports all three missing.
   - Sync the Blueprint so the `doorlist-collector` cron job gets created. Watch its first run in Render's logs, or with `select * from explore_runs order by id desc limit 1`.
3. **Build 2 to TestFlight**, with required sign-in, Explore and connected sites:
   - Bump `CURRENT_PROJECT_VERSION` in `project.yml` to 2.
   - Then: `xcodegen generate` → archive (`-allowProvisioningUpdates`) → export with `build/ExportOptions.plist` (method `app-store-connect`, destination `upload`).
   - `build/` is gitignored. Recreate ExportOptions with `teamID S2UTA2J3GD` if it's gone.
4. **PostHog and Sentry:** see "Second round" above. In order:
   - Redeploy `doorlist-server` on Render and confirm `/health` shows `search: true`.
   - Run the app and confirm PostHog receives events.
   - Authenticate the Sentry MCP, create the projects, and put the DSNs in `project.yml` and Render.
   - Optionally run `npx -y @posthog/wizard@latest ai-observability` in `server/`. It edits the OpenAI calls, so commit first.
5. **Ask Luma** before a public launch. Their terms say "you must not access the Service by any means other than our publicly supported interfaces". The iCal feeds are a supported interface; the discover and event endpoints are not, and the booking engine already relies on those. Doorlist sends Luma registrations, so ask for partner access or permission.
6. **Later, if wanted:**
   - AI Tinkerers: its home page has no event list; each city has its own subdomain.
   - Devfolio in-person events: they need a city from each event's page.
   - More Partiful cities.
   - Ticketmaster: free key, concerts and sports.

## Gotchas worth knowing
- **Luma's discover feed:** `discover_place_api_id` plus `discover_category_api_id` silently returns the unfiltered city list. Use `latitude`/`longitude` with the category instead.
- **Homebrew Postgres** won't start without `LC_ALL` set ("postmaster became multithreaded during startup").
- **Server tests** need Postgres on :55432 (`TEST_DATABASE_URL` overrides that).
- **The simulator can't do Sign in with Apple.** Launch with `SIMCTL_CHILD_DOORLIST_SESSION=<session>`; the dev script does this.
- **TestFlight build 1 still has the old "Continue without an account" path** and doesn't have Explore.
