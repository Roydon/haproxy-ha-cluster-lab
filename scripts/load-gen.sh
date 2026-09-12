#!/usr/bin/env sh
# `make load`: a small continuous write load against both databases through HAProxy,
# for watching Grafana/HAProxy stats react in real time. Ctrl+C to stop. Uses one
# long-lived client container per engine (see failover-test.sh for why, not a fresh
# container per query).
set -u
cd "$(dirname "$0")/.."

[ -f .env ] || { echo ".env not found -- copy .env.example first" >&2; exit 1; }
set -a
. ./.env
set +a

if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then ENGINE=docker
elif command -v podman >/dev/null 2>&1; then ENGINE=podman
else echo "neither docker nor podman found" >&2; exit 1
fi

NET=haha-net
PG_NAME="loadgen-pg-$$"
MYSQL_NAME="loadgen-mysql-$$"
cleanup() { "$ENGINE" rm -f "$PG_NAME" "$MYSQL_NAME" >/dev/null 2>&1; }
trap cleanup EXIT INT TERM

"$ENGINE" run -d --rm --name "$PG_NAME" --network "$NET" \
  -e PGPASSWORD="$POSTGRES_APP_PASSWORD" -e PGCONNECT_TIMEOUT=2 \
  postgres:16-alpine sleep infinity >/dev/null
"$ENGINE" run -d --rm --name "$MYSQL_NAME" --network "$NET" mysql:8.4 sleep infinity >/dev/null

"$ENGINE" exec "$PG_NAME" psql -h haproxy -p 5000 -U "$POSTGRES_APP_USER" -d "$POSTGRES_APP_DB" \
  -c "CREATE TABLE IF NOT EXISTS load_probe (id serial primary key, ts timestamptz default now());" >/dev/null 2>&1
"$ENGINE" exec "$MYSQL_NAME" mysql --connect-timeout=2 -h haproxy -P 3307 -u "$MYSQL_APP_USER" "-p$MYSQL_APP_PASSWORD" "$MYSQL_APP_DB" \
  -e "CREATE TABLE IF NOT EXISTS load_probe (id INT PRIMARY KEY AUTO_INCREMENT, ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP);" >/dev/null 2>&1

echo "writing to postgres (:5000) and mysql (:3307) every 0.5s -- Ctrl+C to stop"
n=0
while true; do
  n=$((n + 1))
  "$ENGINE" exec "$PG_NAME" psql -h haproxy -p 5000 -U "$POSTGRES_APP_USER" -d "$POSTGRES_APP_DB" \
    -c "INSERT INTO load_probe DEFAULT VALUES;" >/dev/null 2>&1 && PG_OK="ok" || PG_OK="FAIL"
  "$ENGINE" exec "$MYSQL_NAME" mysql --connect-timeout=2 -h haproxy -P 3307 -u "$MYSQL_APP_USER" "-p$MYSQL_APP_PASSWORD" "$MYSQL_APP_DB" \
    -e "INSERT INTO load_probe () VALUES ();" >/dev/null 2>&1 && MYSQL_OK="ok" || MYSQL_OK="FAIL"
  printf '\r[%5d] postgres=%-4s mysql=%-4s' "$n" "$PG_OK" "$MYSQL_OK"
  sleep 0.5
done
