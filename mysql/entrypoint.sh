#!/usr/bin/env bash
# Renders my.cnf (server-id, read_only) and, for a brand-new data directory, the init
# SQL for this node's role, then hands off to the official MySQL entrypoint. Rendering
# happens every start (cheap, idempotent for my.cnf); the SQL only takes effect the
# first time MySQL initializes an empty data directory, matching upstream's own
# docker-entrypoint-initdb.d behavior.
set -euo pipefail

: "${MYSQL_ROLE:?MYSQL_ROLE must be set to primary or replica}"
: "${MYSQL_SERVER_ID:?MYSQL_SERVER_ID must be set}"
: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD must be set}"

mkdir -p /etc/mysql/conf.d
sed -e "s/SERVER_ID_PLACEHOLDER/${MYSQL_SERVER_ID}/" \
    /etc/mysql-template/my.cnf.tmpl > /etc/mysql/conf.d/haha.cnf

mkdir -p /docker-entrypoint-initdb.d
if [ "$MYSQL_ROLE" = "primary" ]; then
  envsubst '${MYSQL_REPLICATION_USER} ${MYSQL_REPLICATION_PASSWORD} ${MYSQL_APP_DB} ${MYSQL_APP_USER} ${MYSQL_APP_PASSWORD}' \
    < /etc/mysql-template/init-primary.sql.tmpl > /docker-entrypoint-initdb.d/01-init.sql
else
  : "${MYSQL_PRIMARY_HOST:?MYSQL_PRIMARY_HOST must be set for a replica}"
  envsubst '${MYSQL_PRIMARY_HOST} ${MYSQL_REPLICATION_USER} ${MYSQL_REPLICATION_PASSWORD}' \
    < /etc/mysql-template/init-replica.sql.tmpl > /docker-entrypoint-initdb.d/01-replicate.sql
fi

MYSQL_HOST=127.0.0.1 MYSQL_HEALTH_PASSWORD="$MYSQL_ROOT_PASSWORD" PORT=8081 \
  python3 /usr/local/bin/health-server.py &

exec /usr/local/bin/docker-entrypoint.sh "$@"
