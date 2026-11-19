#!/bin/bash
# Renders the app's screens to PNG files with a demo database and real agent activity.
#
#   scripts/snapshot.sh [output-dir] [scene ...]
#
# DEMO_URL picks the database (a SQLite path by default, or a postgres:// URL).
# APPEARANCES defaults to "light dark". Nothing outside the output directory is touched:
# the app and CLI run with AGENTABLE_HOME set to a folder inside it.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${1:-$ROOT/.build/snapshots}
shift || true
SCENES=${*:-"connections new-connection agents welcome welcome-agents workspace filter advanced where structure pages columns sql sql-ask export new-row row-detail review edit-review apply-edit structure-edit sql-suggest"}
APPEARANCES=${APPEARANCES:-"light dark"}
# LANGUAGE=tr renders in Turkish; file names get a "-tr" suffix. SHOW_MISSING=1 draws text that
# has no translation in capitals.
LANGUAGE=${LANGUAGE:-en}
SHOW_MISSING=${SHOW_MISSING:-0}
DEMO_URL=${DEMO_URL:-$OUT/acme.sqlite}

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
HOME_DIR="$OUT/home"

cd "$ROOT"
swift build --product agentable >/dev/null
swift build --product AgentableApp >/dev/null
APP="$ROOT/.build/debug/AgentableApp"
# A bare executable finds *.lproj next to itself, as the app finds them in its bundle.
cp -R "$ROOT/Sources/AgentableApp/Localization/"*.lproj "$ROOT/.build/debug/"
SUFFIX=$([ "$LANGUAGE" = en ] && echo "" || echo "-$LANGUAGE")
CLI="$ROOT/.build/debug/agentable"

rm -rf "$HOME_DIR"
mkdir -p "$HOME_DIR"
export AGENTABLE_HOME="$HOME_DIR"

"$APP" --seed-demo "$DEMO_URL"
"$CLI" connections add acme-prod "$DEMO_URL" --env production --access propose >/dev/null
"$CLI" connections rules acme-prod --mask customers.email --mask customers.phone --hide api_keys >/dev/null
"$CLI" connections add metrics "~/data/metrics.sqlite" --env local >/dev/null
"$CLI" connections add acme-staging "postgres://app@db-stg.internal:5432/acme" --env staging >/dev/null

# Agent activity, through the same gateway agents use.
q() { AGENTABLE_CLIENT="$1" "$CLI" query acme-prod "$2" >/dev/null; }
q codex "SELECT id, number, total FROM invoices ORDER BY issued_at DESC LIMIT 200"
q claude-code "SELECT order_id, count(*) AS n FROM payments WHERE status = 'succeeded' GROUP BY order_id HAVING count(*) > 1"
AGENTABLE_CLIENT=claude-code "$CLI" propose acme-prod \
  "UPDATE orders SET status = 'refund_pending' WHERE id IN (84209, 84205, 84202)" \
  --reason "Each order has two successful payments on the same card within two minutes. Finance can refund the second one from this status." >/dev/null
q claude-code "SELECT id, total, created_at, status FROM orders WHERE id IN (84209, 84205, 84202) ORDER BY status"

for scene in $SCENES; do
  if [ "$scene" = "structure-edit" ] && [ -z "${INDEX_PROPOSED:-}" ]; then
    # An agent's index proposal for the structure board; later scenes would show it too.
    INDEX_PROPOSED=1
    AGENTABLE_CLIENT=claude-code "$CLI" propose acme-prod \
      "CREATE INDEX orders_status_created_idx ON orders (status, created_at)" \
      --reason "3 of my queries filter by status and date. On a copy of the plan this goes from a 41 ms scan to about 3 ms." >/dev/null
  fi
  if [ "$scene" = "sql-suggest" ] && [ -z "${SQL_SUGGESTED:-}" ]; then
    # A saved query, and an agent's suggestion for it through the CLI, as on board 7.
    SQL_SUGGESTED=1
    mkdir -p "$HOME_DIR/queries/acme-prod"
    cat > "$HOME_DIR/queries/acme-prod/charged-twice.sql" <<'SQL'
-- from your view: orders charged twice
SELECT o.id, o.status, o.total, o.created_at,
       count(p.id) AS payments
FROM orders o
JOIN payments p ON p.order_id = o.id
GROUP BY o.id, o.status, o.total, o.created_at
HAVING count(p.id) > 1
ORDER BY o.created_at DESC;
SQL
    sed 's/^JOIN payments p ON p.order_id = o.id$/&\
  AND p.status = '"'"'succeeded'"'"'/' "$HOME_DIR/queries/acme-prod/charged-twice.sql" |
      AGENTABLE_CLIENT=claude-code "$CLI" suggest acme-prod charged-twice.sql - \
        --note "Failed retries also create payment rows. Count only successful ones, or retries look like double charges." >/dev/null
  fi
  for appearance in $APPEARANCES; do
    file="$OUT/$scene-$appearance$SUFFIX.png"
    rm -f "$file"
    AGENTABLE_SNAPSHOT="$file" AGENTABLE_SNAPSHOT_SCENE="$scene" AGENTABLE_APPEARANCE="$appearance" \
      "$APP" -AppleLanguages "($LANGUAGE)" $([ "$SHOW_MISSING" = 1 ] && echo "-NSShowNonLocalizedStrings YES") \
      >/dev/null 2>&1 &
    pid=$!
    for _ in $(seq 1 100); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    kill "$pid" 2>/dev/null || true
    if [ -f "$file" ]; then echo "$file"; else echo "missing: $file" >&2; fi
  done
done
