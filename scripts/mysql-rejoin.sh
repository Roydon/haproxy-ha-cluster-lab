#!/usr/bin/env sh
# Reattaches a MySQL node as a replica of a (possibly new) primary. Used after a
# failed-over node comes back, so it doesn't resume as a stale, conflicting primary.
# Runs via a container on the compose network, same reasoning as mysql-promote.sh.
set -eu
HOST="${1:?usage: mysql-rejoin.sh <host> <new-primary-host> <root-password> <repl-user> <repl-password> [network]}"
NEW_PRIMARY="${2:?}"
ROOT_PW="${3:?}"
REPL_USER="${4:?}"
REPL_PW="${5:?}"
NET="${6:-haha-net}"

if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then ENGINE=docker
elif command -v podman >/dev/null 2>&1; then ENGINE=podman
else echo "neither docker nor podman found" >&2; exit 1
fi

"$ENGINE" run --rm --network "$NET" mysql:8.4 mysql --connect-timeout=3 -h "$HOST" -uroot -p"$ROOT_PW" -e "
SET PERSIST read_only = OFF;
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST = '$NEW_PRIMARY',
  SOURCE_USER = '$REPL_USER',
  SOURCE_PASSWORD = '$REPL_PW',
  SOURCE_AUTO_POSITION = 1,
  GET_SOURCE_PUBLIC_KEY = 1;
START REPLICA;
SET PERSIST read_only = ON;
SET PERSIST super_read_only = ON;
"
echo "$HOST rejoined as a replica of $NEW_PRIMARY"
