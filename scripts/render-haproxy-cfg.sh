#!/usr/bin/env sh
# Renders haproxy/haproxy.cfg from templates/haproxy.cfg.tmpl using whichever backend
# containers are actually resolvable on the compose network right now. This lets one
# template serve both the "lite" and "full" profiles without hardcoding node counts:
# a service that compose didn't start for the active profile simply never gets a DNS
# entry, so it's left out of the rendered config instead of failing health checks.
set -eu

# HAPROXY_TMPL / HAPROXY_OUT let the HAProxy container point this at its own paths;
# outside a container (e.g. regenerating the committed lint copy) the repo-relative
# defaults apply.
cd "$(dirname "$0")/.." || exit 1
TMPL="${HAPROXY_TMPL:-haproxy/templates/haproxy.cfg.tmpl}"
OUT="${HAPROXY_OUT:-haproxy/haproxy.cfg}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

resolvable() {
  getent hosts "$1" >/dev/null 2>&1
}

build_block() {
  # $1=output file  $2=port  $3=check-port  $4...=candidate hostnames
  out="$1"; port="$2"; checkport="$3"; shift 3
  : > "$out"
  for h in "$@"; do
    if resolvable "$h"; then
      echo "    server $h $h:$port check port $checkport" >> "$out"
    fi
  done
}

build_block "$WORK/pg_write"     5432 8008 pg1 pg2 pg3
build_block "$WORK/pg_read"      5432 8008 pg1 pg2 pg3
build_block "$WORK/mysql_write"  3306 8081 mysql1 mysql2 mysql3
build_block "$WORK/mysql_read"   3306 8081 mysql1 mysql2 mysql3
build_block "$WORK/app"          8080 8080 app-php-1 app-php-2 app-node-1

# Docker's embedded DNS is a fixed 127.0.0.11; Podman's aardvark-dns instead listens
# on the network's own gateway IP. Read whichever one this container actually has
# rather than hardcoding either, so the dynamic re-resolution in the resolvers
# section above points somewhere that actually answers.
DNS_NAMESERVER=$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf 2>/dev/null || true)
DNS_NAMESERVER="${DNS_NAMESERVER:-127.0.0.11}"

# sed's `r` command inserts a file's contents after the matched line; follow with `d`
# to drop the placeholder line itself.
sed \
  -e "/{{PG_WRITE_SERVERS}}/r $WORK/pg_write" -e "/{{PG_WRITE_SERVERS}}/d" \
  -e "/{{PG_READ_SERVERS}}/r $WORK/pg_read" -e "/{{PG_READ_SERVERS}}/d" \
  -e "/{{MYSQL_WRITE_SERVERS}}/r $WORK/mysql_write" -e "/{{MYSQL_WRITE_SERVERS}}/d" \
  -e "/{{MYSQL_READ_SERVERS}}/r $WORK/mysql_read" -e "/{{MYSQL_READ_SERVERS}}/d" \
  -e "/{{APP_SERVERS}}/r $WORK/app" -e "/{{APP_SERVERS}}/d" \
  -e "s/{{DNS_NAMESERVER}}/$DNS_NAMESERVER/" \
  "$TMPL" > "$OUT"

echo "rendered $OUT"
