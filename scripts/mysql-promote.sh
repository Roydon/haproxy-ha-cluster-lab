#!/usr/bin/env sh
# Promotes a MySQL replica to a standalone writable primary. Used by the failover
# test (and by an operator during a real incident) since async replication, unlike
# Patroni, does not elect a new primary on its own.
set -eu
HOST="${1:?usage: mysql-promote.sh <host> <root-password>}"
ROOT_PW="${2:?usage: mysql-promote.sh <host> <root-password>}"

mysql -h "$HOST" -uroot -p"$ROOT_PW" -e "
STOP REPLICA;
RESET REPLICA ALL;
SET PERSIST read_only = OFF;
SET PERSIST super_read_only = OFF;
"
echo "$HOST promoted to primary"
