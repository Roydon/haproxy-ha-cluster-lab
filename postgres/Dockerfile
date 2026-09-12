# Minimal Patroni + PostgreSQL image for the lab. Production Ansible role installs the
# same versions from distro/PGDG packages instead of this image.
FROM python:3.11-slim

ARG PG_MAJOR=16

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg lsb-release gettext-base \
    && install -d /usr/share/postgresql-common/pgdg \
    && curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
       -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    && echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
       https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
       > /etc/apt/sources.list.d/pgdg.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       postgresql-${PG_MAJOR} postgresql-client-${PG_MAJOR} \
    && apt-get purge -y gnupg lsb-release \
    && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir "patroni[etcd3]==3.3.*" psycopg2-binary

ENV PATH="/usr/lib/postgresql/${PG_MAJOR}/bin:${PATH}"
# The postgresql-<ver> package already creates the "postgres" system user; just give it
# a home directory for Patroni's data dir instead of creating a duplicate user.
RUN mkdir -p /home/postgres/data && usermod -d /home/postgres postgres \
    && chown -R postgres:postgres /home/postgres

COPY postgres/templates/patroni.yml.tmpl /etc/patroni.yml.tmpl
COPY postgres/templates/pg-post-bootstrap.sh.tmpl /etc/pg-post-bootstrap.sh.tmpl
COPY postgres/entrypoint.sh /entrypoint.sh
RUN chown postgres:postgres /etc/patroni.yml.tmpl /etc/pg-post-bootstrap.sh.tmpl \
    && chmod 755 /entrypoint.sh

VOLUME ["/home/postgres/data"]
EXPOSE 5432 8008
USER postgres
ENTRYPOINT ["/entrypoint.sh"]
