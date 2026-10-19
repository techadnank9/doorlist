#!/usr/bin/env bash
# Brings the whole Explore stack up locally, the way it was last verified:
#   Postgres on :55432 -> collector run (optional) -> server on :8787 (mock upstreams) -> app in the booted simulator.
#
#   ./scripts/dev-explore.sh            # everything, skipping the collector if events are already stored
#   ./scripts/dev-explore.sh --collect  # also run a fresh collection (slow on purpose: ~20 min, polite to every site)
#   ./scripts/dev-explore.sh --test     # just the collector and server tests
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
export LC_ALL=${LC_ALL:-en_US.UTF-8}   # Homebrew Postgres refuses to start without a locale
DB_URL=postgres://postgres:test@localhost:55432/doorlist
export PGPASSWORD=test

say() { printf "\n\033[1m%s\033[0m\n" "$*"; }

# 1. Postgres: Docker if it's there (as the README says), else Homebrew's, in ~/.doorlist-pg.
if ! pg_isready -h localhost -p 55432 >/dev/null 2>&1; then
  if command -v docker >/dev/null; then
    say "Starting Postgres in Docker"
    docker start doorlist-pg 2>/dev/null || docker run -d --name doorlist-pg -p 55432:5432 -e POSTGRES_PASSWORD=test -e POSTGRES_DB=doorlist postgres:17-alpine
  else
    say "Starting Homebrew Postgres in ~/.doorlist-pg"
    if [ ! -d ~/.doorlist-pg ]; then
      echo test > /tmp/doorlist-pw && initdb -D ~/.doorlist-pg -U postgres --pwfile=/tmp/doorlist-pw -A md5 >/dev/null && rm /tmp/doorlist-pw
    fi
    pg_ctl -D ~/.doorlist-pg -o "-p 55432" -l ~/.doorlist-pg/log start
    sleep 2
    psql -h localhost -p 55432 -U postgres -tc "select 1 from pg_database where datname='doorlist'" | grep -q 1 \
      || createdb -h localhost -p 55432 -U postgres doorlist
  fi
fi

# 2. Collector environment.
if [ ! -x collector/.venv/bin/python ]; then
  say "Setting up the collector's Python"
  (cd collector && uv venv -q --python 3.12 .venv && uv pip install -q --python .venv/bin/python -r requirements.txt)
fi
(cd server && [ -d node_modules ] || npm install --silent)

if [ "${1:-}" = "--test" ]; then
  say "Collector tests"; (cd collector && .venv/bin/python -m pytest -q tests)
  say "Server tests"; (cd server && npm test)
  exit 0
fi

stored=$(psql -h localhost -p 55432 -U postgres -d doorlist -tAc "select count(*) from explore_events" 2>/dev/null || echo 0)
if [ "${1:-}" = "--collect" ] || [ "${stored:-0}" = "0" ]; then
  say "Collecting events (one request every 2 to 3 seconds per site; about 20 minutes)"
  (cd collector && DATABASE_URL=$DB_URL .venv/bin/python -m doorlist_collector.run 2>&1 | grep -v "INFO: Fetched")
else
  say "$stored events already stored; pass --collect for a fresh run"
fi

# 3. Server against the mock upstreams (no API keys needed; Explore needs none anyway).
say "Starting the mock upstreams (:8790) and server (:8787) in the background"
(cd server && nohup npm run mock >/tmp/doorlist-mock.log 2>&1 &)
(cd server && nohup npm run dev:mock >/tmp/doorlist-server.log 2>&1 &)
for _ in $(seq 30); do curl -sf localhost:8787/health >/dev/null && break; sleep 1; done
curl -s -H "x-doorlist-token: change-me" "localhost:8787/v1/explore?place=sf&topic=hackathons" | head -c 300; echo

# 4. The app, signed in with a local session (Sign in with Apple needs a signed device build).
if xcrun simctl list devices booted | grep -q Booted; then
  say "Building and launching Doorlist in the booted simulator"
  xcodegen generate >/dev/null
  xcodebuild -project Doorlist.xcodeproj -scheme Doorlist -configuration Debug \
    -destination "generic/platform=iOS Simulator" -derivedDataPath build/dd build 2>&1 | grep -E "error:|BUILD"
  xcrun simctl install booted build/dd/Build/Products/Debug-iphonesimulator/Doorlist.app
  session=$(cd server && SESSION_SECRET=dev npx tsx -e 'import("./src/auth.ts").then(m=>console.log(m.issueSession("sim-test-user")))' | tail -1)
  SIMCTL_CHILD_DOORLIST_SESSION="$session" xcrun simctl launch booted com.doorlist.app
else
  say "No simulator booted: run  xcrun simctl boot 'iPhone 17'  and this script again for the app"
fi
say "Done. Server log: /tmp/doorlist-server.log"
