#!/usr/bin/env sh
# Promotes a MySQL replica to a standalone writable primary. Used by the failover
# test (and by an operator during a real incident) since async replication, unlike
# Patroni, does not elect a new primary on its own. Runs the mysql client via a
# container on the compose network -- the host itself has no mysql client installed,
# and this way the script works the same on any host regardless of local tooling.
set -eu
HOST="${1:?usage: mysql-promote.sh <host> <root-password> [network]}"
ROOT_PW="${2:?usage: mysql-promote.sh <host> <root-password> [network]}"
NET="${3:-haha-net}"

if command -v docker >/dev/null 2>&1 && docker version >/dev/null 2>&1; then ENGINE=docker
elif command -v podman >/dev/null 2>&1; then ENGINE=podman
else echo "neither docker nor podman found" >&2; exit 1
fi

"$ENGINE" run --rm --network "$NET" mysql:8.4 mysql --connect-timeout=3 -h "$HOST" -uroot -p"$ROOT_PW" -e "
STOP REPLICA;
RESET REPLICA ALL;
SET PERSIST read_only = OFF;
SET PERSIST super_read_only = OFF;
"
echo "$HOST promoted to primary"
