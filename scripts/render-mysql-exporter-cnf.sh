#!/usr/bin/env sh
# mysqld_exporter >=0.15 dropped DATA_SOURCE_NAME env var support in favor of a
# my.cnf file (security hardening upstream). We still keep credentials in .env as
# the single source of truth, so this renders that file's MYSQL_ROOT_PASSWORD into
# a real my.cnf per node before `docker compose up` starts the exporters. Run by
# `make up` / `make up-lite`; safe to re-run.
set -eu
cd "$(dirname "$0")/.." || exit 1

[ -f .env ] || { echo ".env not found -- copy .env.example first" >&2; exit 1; }
set -a
# shellcheck disable=SC1091
. ./.env
set +a

mkdir -p monitoring/mysqld-exporter/generated
for n in 1 2 3; do
  # shellcheck disable=SC2016  # single quotes intentional: envsubst does its own substitution
  envsubst '${MYSQL_ROOT_PASSWORD}' \
    < "monitoring/mysqld-exporter/mysql${n}.my.cnf.tmpl" \
    > "monitoring/mysqld-exporter/generated/mysql${n}.my.cnf"
done
echo "rendered monitoring/mysqld-exporter/generated/mysql{1,2,3}.my.cnf"
