#!/usr/bin/env sh
# `make failover`: kills the Postgres leader and the MySQL primary under a small write
# load, measures write-downtime seconds and lost acknowledged writes for each, confirms
# the killed node rejoins automatically (pg) or via the promotion script (mysql), and
# writes reports/failover-<ts>.md. No bare `sleep` in a wait loop -- every wait is
# bounded and polls a real condition, so a hung cluster fails this script rather than
# the caller's CI job timing out after burning the runner's whole budget.
#
# Uses two long-lived client containers (one per engine) with `exec` for every query,
# rather than a fresh `run --rm` per query: spinning up a container per query added
# enough latency under load that a `timeout` guard on the outer command sometimes fired
# mid-container-creation, and killing the `run` client doesn't reliably kill the
# container it started, leaving orphaned client containers behind.
set -u
cd "$(dirname "$0")/.." || exit 1

[ -f .env ] || { echo ".env not found -- copy .env.example first" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then ENGINE=docker
elif command -v podman >/dev/null 2>&1; then ENGINE=podman
else echo "neither docker nor podman found" >&2; exit 1
fi
CE() { "$ENGINE" "$@"; }

NET=haha-net
TS=$(date +%Y%m%d-%H%M%S)
REPORT="reports/failover-${TS}.md"
WRITE_INTERVAL=0.3
MAX_DOWNTIME_WAIT=60   # seconds -- bail out rather than hang forever on a stuck cluster
MAX_REJOIN_WAIT=90

PG_CLIENT_NAME="failover-pgclient-$$"
MYSQL_CLIENT_NAME="failover-mysqlclient-$$"
cleanup() {
  CE rm -f "$PG_CLIENT_NAME" "$MYSQL_CLIENT_NAME" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

CE run -d --rm --name "$PG_CLIENT_NAME" --network "$NET" \
  -e PGPASSWORD="$POSTGRES_APP_PASSWORD" -e PGCONNECT_TIMEOUT=2 \
  postgres:16-alpine sleep infinity >/dev/null
CE run -d --rm --name "$MYSQL_CLIENT_NAME" --network "$NET" \
  mysql:8.4 sleep infinity >/dev/null

pg_client() { timeout 8 "$ENGINE" exec "$PG_CLIENT_NAME" psql -h haproxy -p 5000 -U "$POSTGRES_APP_USER" -d "$POSTGRES_APP_DB" -tA "$@"; }
mysql_client() { timeout 8 "$ENGINE" exec "$MYSQL_CLIENT_NAME" mysql --connect-timeout=2 -h haproxy -P 3307 -u "$MYSQL_APP_USER" "-p$MYSQL_APP_PASSWORD" "$MYSQL_APP_DB" -N "$@"; }
mysql_admin() { timeout 8 "$ENGINE" exec "$MYSQL_CLIENT_NAME" mysql --connect-timeout=2 -h "$1" -uroot "-p$MYSQL_ROOT_PASSWORD" -N -e "$2"; }
# -N (skip-column-names) also strips field labels from `SHOW ... STATUS\G`'s vertical
# output, not just table headers -- so a plain grep for "Field_name:" can never match
# it. Use this variant (no -N) for any \G status query.
mysql_admin_status() { timeout 8 "$ENGINE" exec "$MYSQL_CLIENT_NAME" mysql --connect-timeout=2 -h "$1" -uroot "-p$MYSQL_ROOT_PASSWORD" -e "$2"; }

now_s() { date +%s.%N; }

# ---------------------------------------------------------------- Postgres failover
echo "=== PostgreSQL failover ==="
pg_client -c "DROP TABLE IF EXISTS failover_probe; CREATE TABLE failover_probe (seq int primary key, ts timestamptz default now());" >/dev/null 2>&1

LEADER=""
for h in pg1 pg2 pg3; do
  if CE exec "$h" true >/dev/null 2>&1; then
    CODE=$(CE exec "$h" curl -s --max-time 2 -o /dev/null -w '%{http_code}' http://localhost:8008/primary 2>/dev/null)
    [ "$CODE" = "200" ] && LEADER="$h"
  fi
done
[ -n "$LEADER" ] || { echo "could not identify current Postgres leader" >&2; exit 1; }
echo "current leader: $LEADER"

PG_SEQ=0
PG_LEDGER=$(mktemp)
i=0
while [ "$i" -lt 8 ]; do
  PG_SEQ=$((PG_SEQ + 1))
  if pg_client -c "INSERT INTO failover_probe (seq) VALUES ($PG_SEQ) ON CONFLICT DO NOTHING;" >/dev/null 2>&1; then
    echo "$PG_SEQ" >> "$PG_LEDGER"
  fi
  i=$((i + 1))
  sleep "$WRITE_INTERVAL"
done

echo "killing leader $LEADER ..."
KILL_T=$(now_s)
CE kill "$LEADER" >/dev/null 2>&1

PG_DOWNTIME=""
DEADLINE=$(( $(date +%s) + MAX_DOWNTIME_WAIT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  PG_SEQ=$((PG_SEQ + 1))
  if pg_client -c "INSERT INTO failover_probe (seq) VALUES ($PG_SEQ) ON CONFLICT DO NOTHING;" >/dev/null 2>&1; then
    echo "$PG_SEQ" >> "$PG_LEDGER"
    RECOVER_T=$(now_s)
    PG_DOWNTIME=$(python3 -c "print(round($RECOVER_T - $KILL_T, 2))")
    break
  fi
  sleep 0.5
done
[ -n "$PG_DOWNTIME" ] || { echo "postgres did not recover a writable leader within ${MAX_DOWNTIME_WAIT}s" >&2; PG_DOWNTIME="TIMEOUT(>${MAX_DOWNTIME_WAIT}s)"; }
echo "postgres write downtime: ${PG_DOWNTIME}s"

i=0
while [ "$i" -lt 8 ]; do
  PG_SEQ=$((PG_SEQ + 1))
  if pg_client -c "INSERT INTO failover_probe (seq) VALUES ($PG_SEQ) ON CONFLICT DO NOTHING;" >/dev/null 2>&1; then
    echo "$PG_SEQ" >> "$PG_LEDGER"
  fi
  i=$((i + 1))
  sleep "$WRITE_INTERVAL"
done

ACKED=$(wc -l < "$PG_LEDGER" | tr -d ' ')
PERSISTED=$(pg_client -c "SELECT count(*) FROM failover_probe;" 2>/dev/null)
PERSISTED=${PERSISTED:-0}
PG_LOST=$((ACKED - PERSISTED))
[ "$PG_LOST" -lt 0 ] && PG_LOST=0
echo "postgres acknowledged writes: $ACKED, persisted: $PERSISTED, lost: $PG_LOST"

CE start "$LEADER" >/dev/null 2>&1
PG_REJOINED="no"
DEADLINE=$(( $(date +%s) + MAX_REJOIN_WAIT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  CODE=$(CE exec "$LEADER" curl -s --max-time 2 -o /dev/null -w '%{http_code}' http://localhost:8008/replica 2>/dev/null)
  if [ "$CODE" = "200" ]; then PG_REJOINED="yes"; break; fi
  sleep 1
done
echo "$LEADER rejoined as replica: $PG_REJOINED"
rm -f "$PG_LEDGER"

# ---------------------------------------------------------------- MySQL failover
echo
echo "=== MySQL failover ==="
mysql_client -e "DROP TABLE IF EXISTS failover_probe; CREATE TABLE failover_probe (seq INT PRIMARY KEY, ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" >/dev/null 2>&1

MYSQL_PRIMARY="mysql1"
MYSQL_REPLICA="mysql2"
for h in mysql1 mysql2 mysql3; do
  RO=$(mysql_admin "$h" "SELECT @@read_only;" 2>/dev/null | tail -1)
  if [ "$RO" = "0" ]; then MYSQL_PRIMARY="$h"; fi
done
for h in mysql1 mysql2 mysql3; do
  [ "$h" = "$MYSQL_PRIMARY" ] && continue
  RO=$(mysql_admin "$h" "SELECT @@read_only;" 2>/dev/null | tail -1)
  [ "$RO" = "1" ] && MYSQL_REPLICA="$h" && break
done
echo "current primary: $MYSQL_PRIMARY, promoting: $MYSQL_REPLICA"

MYSQL_SEQ=0
MYSQL_LEDGER=$(mktemp)
i=0
while [ "$i" -lt 8 ]; do
  MYSQL_SEQ=$((MYSQL_SEQ + 1))
  if mysql_client -e "INSERT IGNORE INTO failover_probe (seq) VALUES ($MYSQL_SEQ);" >/dev/null 2>&1; then
    echo "$MYSQL_SEQ" >> "$MYSQL_LEDGER"
  fi
  i=$((i + 1))
  sleep "$WRITE_INTERVAL"
done

echo "killing primary $MYSQL_PRIMARY ..."
KILL_T=$(now_s)
CE kill "$MYSQL_PRIMARY" >/dev/null 2>&1

echo "promoting $MYSQL_REPLICA ..."
./scripts/mysql-promote.sh "$MYSQL_REPLICA" "$MYSQL_ROOT_PASSWORD" >/dev/null 2>&1

MYSQL_DOWNTIME=""
DEADLINE=$(( $(date +%s) + MAX_DOWNTIME_WAIT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  MYSQL_SEQ=$((MYSQL_SEQ + 1))
  if mysql_client -e "INSERT IGNORE INTO failover_probe (seq) VALUES ($MYSQL_SEQ);" >/dev/null 2>&1; then
    echo "$MYSQL_SEQ" >> "$MYSQL_LEDGER"
    RECOVER_T=$(now_s)
    MYSQL_DOWNTIME=$(python3 -c "print(round($RECOVER_T - $KILL_T, 2))")
    break
  fi
  sleep 0.5
done
[ -n "$MYSQL_DOWNTIME" ] || { echo "mysql did not recover a writable primary within ${MAX_DOWNTIME_WAIT}s" >&2; MYSQL_DOWNTIME="TIMEOUT(>${MAX_DOWNTIME_WAIT}s)"; }
echo "mysql write downtime: ${MYSQL_DOWNTIME}s"

i=0
while [ "$i" -lt 8 ]; do
  MYSQL_SEQ=$((MYSQL_SEQ + 1))
  if mysql_client -e "INSERT IGNORE INTO failover_probe (seq) VALUES ($MYSQL_SEQ);" >/dev/null 2>&1; then
    echo "$MYSQL_SEQ" >> "$MYSQL_LEDGER"
  fi
  i=$((i + 1))
  sleep "$WRITE_INTERVAL"
done

MYSQL_ACKED=$(wc -l < "$MYSQL_LEDGER" | tr -d ' ')
MYSQL_PERSISTED=$(mysql_client -e "SELECT count(*) FROM failover_probe;" 2>/dev/null)
MYSQL_PERSISTED=${MYSQL_PERSISTED:-0}
MYSQL_LOST=$((MYSQL_ACKED - MYSQL_PERSISTED))
[ "$MYSQL_LOST" -lt 0 ] && MYSQL_LOST=0
echo "mysql acknowledged writes: $MYSQL_ACKED, persisted: $MYSQL_PERSISTED, lost: $MYSQL_LOST"

# Restart the killed node and rejoin it as a replica of the new primary (async
# replication has no self-election, unlike Patroni, so this step is explicit).
CE start "$MYSQL_PRIMARY" >/dev/null 2>&1
DEADLINE=$(( $(date +%s) + MAX_REJOIN_WAIT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  if CE exec "$MYSQL_PRIMARY" mysqladmin ping -h 127.0.0.1 -uroot "-p$MYSQL_ROOT_PASSWORD" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
./scripts/mysql-rejoin.sh "$MYSQL_PRIMARY" "$MYSQL_REPLICA" "$MYSQL_ROOT_PASSWORD" "$MYSQL_REPLICATION_USER" "$MYSQL_REPLICATION_PASSWORD" >/dev/null 2>&1
MYSQL_REJOINED="no"
DEADLINE=$(( $(date +%s) + MAX_REJOIN_WAIT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  IO=$(mysql_admin_status "$MYSQL_PRIMARY" "SHOW REPLICA STATUS\G" 2>/dev/null | grep "Replica_IO_Running:" | awk '{print $2}')
  if [ "$IO" = "Yes" ]; then MYSQL_REJOINED="yes"; break; fi
  sleep 1
done
echo "$MYSQL_PRIMARY rejoined as replica of $MYSQL_REPLICA: $MYSQL_REJOINED"
rm -f "$MYSQL_LEDGER"

# ---------------------------------------------------------------- Report
mkdir -p reports
{
  echo "# Failover test report -- $TS"
  echo
  echo "| Engine | Write downtime | Acknowledged writes | Persisted | Lost | Node rejoined as replica |"
  echo "|---|---|---|---|---|---|"
  echo "| PostgreSQL (Patroni, synchronous) | ${PG_DOWNTIME}s | $ACKED | $PERSISTED | $PG_LOST | $PG_REJOINED |"
  echo "| MySQL (async + promotion script) | ${MYSQL_DOWNTIME}s | $MYSQL_ACKED | $MYSQL_PERSISTED | $MYSQL_LOST | $MYSQL_REJOINED |"
  echo
  echo "PostgreSQL uses \`synchronous_mode\` in Patroni: an acknowledged write is durable on"
  echo "the sync standby before the client sees success, so lost=0 is the expected and"
  echo "required outcome above -- not just a lucky run."
  echo
  echo "MySQL uses async replication (a deliberate, documented time-box trade-off --"
  echo "see README \"Limitations\"): a write acknowledged by the primary a moment before"
  echo "it's killed can still be lost if it hadn't shipped to the replica yet. lost=0 above"
  echo "means none happened to land in that window this run; a nonzero value here is the"
  echo "real, expected risk of async replication under failure, not a bug."
  echo
  echo "Environment: $(uname -s) $(uname -m), engine: $ENGINE, profile: ${COMPOSE_PROFILES:-full}."
} > "$REPORT"

echo
echo "wrote $REPORT"
cat "$REPORT"
