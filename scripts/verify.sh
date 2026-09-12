#!/usr/bin/env sh
# `make verify`: exercises every routing path the brief lists and prints a PASS/FAIL
# table. Runs ad-hoc client containers on the compose network (not host tooling, not
# host ports) so this works identically on a laptop, in CI, and in the lite profile.
# Deliberately does NOT use `set -e` -- a failing check must be recorded as FAIL and
# the script must keep going to produce a complete table, not abort on the first one.
set -u
cd "$(dirname "$0")/.." || exit 1

[ -f .env ] || { echo ".env not found -- copy .env.example first" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# `docker` is often only a shell alias (e.g. `docker=podman`), which doesn't exist in
# this non-interactive script -- resolve a real binary explicitly instead.
if command -v docker >/dev/null 2>&1; then ENGINE=docker
elif command -v podman >/dev/null 2>&1; then ENGINE=podman
else echo "neither docker nor podman found" >&2; exit 1
fi
docker() { "$ENGINE" "$@"; }

NET=haha-net
PASS=0
FAIL=0

row() {
  # $1=name  $2=exit-code-of-the-check (0 = pass)
  if [ "$2" -eq 0 ]; then
    printf '%-45s %s\n' "$1" "PASS"
    PASS=$((PASS + 1))
  else
    printf '%-45s %s\n' "$1" "FAIL"
    FAIL=$((FAIL + 1))
  fi
}

pg_client() { docker run --rm --network "$NET" -e PGPASSWORD="$POSTGRES_APP_PASSWORD" postgres:16-alpine psql -h haproxy -U "$POSTGRES_APP_USER" -d "$POSTGRES_APP_DB" "$@"; }
mysql_client() { docker run --rm --network "$NET" mysql:8.4 mysql -h haproxy -u "$MYSQL_APP_USER" "-p$MYSQL_APP_PASSWORD" "$MYSQL_APP_DB" "$@"; }
redis_client() { docker run --rm --network "$NET" redis:7-alpine redis-cli -c -h redis1 "$@"; }

echo "=== HAProxy stats/metrics ==="
docker run --rm --network "$NET" curlimages/curl -sf http://haproxy:8404/stats >/dev/null 2>&1
row "haproxy stats page (:8404/stats)" $?

echo "=== App tier (:80 via haproxy) -- distinct backends across 6 requests ==="
BACKENDS=$(for _req in 1 2 3 4 5 6; do
  docker run --rm --network "$NET" curlimages/curl -sf http://haproxy:80/ 2>/dev/null | grep -o '"hostname" *: *"[^"]*"' || true
done | sort -u)
echo "$BACKENDS" | sed 's/^/  /'
BACKEND_COUNT=$(printf '%s\n' "$BACKENDS" | grep -c .)
if [ "$BACKEND_COUNT" -ge 1 ]; then row "app tier reachable through haproxy ($BACKEND_COUNT distinct backend(s) seen)" 0
else row "app tier reachable through haproxy (0 backends seen)" 1
fi

echo "=== PostgreSQL write/read split ==="
pg_client -p 5000 -c "CREATE TABLE IF NOT EXISTS verify_probe (id serial primary key, ts timestamptz default now()); INSERT INTO verify_probe DEFAULT VALUES;" >/dev/null 2>&1
row "postgres write via :5000 (leader)" $?
sleep 1
pg_client -p 5001 -c "SELECT count(*) FROM verify_probe;" >/dev/null 2>&1
row "postgres read via :5001 (replica)" $?

echo "=== MySQL write/read split ==="
mysql_client -P 3307 -e "CREATE TABLE IF NOT EXISTS verify_probe (id INT PRIMARY KEY AUTO_INCREMENT, ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP); INSERT INTO verify_probe () VALUES ();" >/dev/null 2>&1
row "mysql write via :3307 (primary)" $?
sleep 1
mysql_client -P 3308 -e "SELECT count(*) FROM verify_probe;" >/dev/null 2>&1
row "mysql read via :3308 (replica)" $?

echo "=== Redis Cluster ==="
STATE=$(redis_client cluster info 2>/dev/null | grep '^cluster_state:' | tr -d '\r')
if [ "$STATE" = "cluster_state:ok" ]; then row "redis cluster_state:ok" 0
else row "redis cluster_state:ok (got: ${STATE:-none})" 1
fi

echo
echo "===================================="
echo "PASS: $PASS   FAIL: $FAIL"
echo "===================================="
[ "$FAIL" -eq 0 ]
