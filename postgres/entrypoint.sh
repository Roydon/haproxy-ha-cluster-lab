#!/usr/bin/env sh
# Renders patroni.yml (and the post_bootstrap helper script) from templates using
# envsubst, then execs patroni. patroni.yml.tmpl has no stray `$` characters outside
# our own placeholders so a full envsubst is safe there; the post-bootstrap script is
# real shell (it has its own $1, $CONNSTRING, etc.), so it's restricted to an explicit
# variable allowlist to avoid envsubst blanking those out.
set -eu
: "${NODE_NAME:?NODE_NAME must be set}"
: "${ETCD_HOST:?ETCD_HOST must be set}"
: "${PATRONI_SCOPE:?PATRONI_SCOPE must be set}"

envsubst < /etc/patroni.yml.tmpl > /home/postgres/patroni.yml

envsubst '${POSTGRES_APP_USER} ${POSTGRES_APP_PASSWORD} ${POSTGRES_APP_DB}' \
  < /etc/pg-post-bootstrap.sh.tmpl > /home/postgres/pg-post-bootstrap.sh
chmod +x /home/postgres/pg-post-bootstrap.sh

exec patroni /home/postgres/patroni.yml
