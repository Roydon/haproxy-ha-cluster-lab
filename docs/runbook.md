# Runbook

## Failover (what happens automatically, what doesn't)

**PostgreSQL** is fully automatic. Patroni elects a new leader from the surviving
nodes (via etcd), HAProxy's health checks against Patroni's REST API
(`/primary`, `/replica`) pick that up within a few seconds, and the old leader
rejoins as a replica on its own once it's back (using `pg_rewind` if its WAL
diverged). Nothing to do except confirm it happened:

```bash
docker compose exec pg1 curl -s http://localhost:8008/patroni | python3 -m json.tool
```

**MySQL** needs a human (or `make failover`'s scripted equivalent) to promote a
replica — async replication has no self-election:

```bash
# 1. Identify a healthy replica to promote (check @@read_only on each node)
docker compose exec mysql2 mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT @@read_only;"

# 2. Promote it
./scripts/mysql-promote.sh mysql2 "$MYSQL_ROOT_PASSWORD"

# 3. When the failed node comes back, rejoin it as a replica of the new primary
docker compose start mysql1
./scripts/mysql-rejoin.sh mysql1 mysql2 "$MYSQL_ROOT_PASSWORD" "$MYSQL_REPLICATION_USER" "$MYSQL_REPLICATION_PASSWORD"
```

HAProxy needs no manual reconfiguration for either engine — its health checks
against the app-level `/write` and `/read` (MySQL) or `/primary` and `/replica`
(Postgres) endpoints pick up the new roles automatically once they change.

## Rejoining a node manually (e.g. after a longer outage)

- **Postgres**: `docker compose start pgN` (or the systemd unit on a real host).
  Patroni handles the rest — check `/patroni` on that node until `"role":
  "replica"`.
- **MySQL**: run `scripts/mysql-rejoin.sh` as above, pointing at whichever node
  is currently primary. If its data has diverged too far to catch up via
  incremental replication, you'll need to re-seed it (`mysqldump` from the
  primary, or a filesystem-level clone) before starting replication.
- **Redis**: a cluster node that comes back with the same node ID typically
  rejoins its old slot ownership automatically (`cluster-config-file` persists
  it). If it doesn't, `redis-cli --cluster fix <any-node>:6379`.

## Rotating credentials

1. Update `.env` (lab) or `group_vars/all.yml` (Ansible) with the new values.
2. Postgres: `ALTER USER appuser WITH PASSWORD '...';` on the current leader —
   it replicates automatically.
3. MySQL: `ALTER USER 'appuser'@'%' IDENTIFIED BY '...';` on the current primary.
4. Redis: if `REDIS_PASSWORD` is set, update `requirepass` cluster-wide and
   restart each node (Redis Cluster doesn't hot-reload `requirepass`).
5. Restart the app tier and HAProxy's health-check callers if they cache
   credentials (this lab's apps don't; check yours).
6. Recreate the mysqld_exporter `.my.cnf` files: `./scripts/render-mysql-exporter-cnf.sh`.

## Adding an app node

Lab: add a new `app-php-N`/`app-node-N` service in `docker-compose.yml` (copy an
existing one), add it to `haproxy/templates/haproxy.cfg.tmpl`'s app-server
candidate list in `scripts/render-haproxy-cfg.sh`, rebuild HAProxy.

Production: add the host to `ansible/inventory/*.ini`'s `[app]` group, add it to
`group_vars` if it needs host-specific vars, then:

```bash
make deploy HOSTS=app
```

The `haproxy` role's template iterates `groups['app']`, so a new app host is
picked up automatically on the next `make deploy HOSTS=haproxy` (or on the same
run, if HAProxy is in the same play).

## What each alert means (see `monitoring/alerts/rules.yml`)

| Alert | Meaning | First thing to check |
|---|---|---|
| `BackendDown` | HAProxy's own health check has marked a server down for 15s+ | `docker compose logs <service>`; is the container actually up? |
| `NodeDown` | Prometheus can't scrape a target (exporter or the node itself is unreachable) for 30s+ | Is the exporter process running? Network reachable? |
| `PostgresReplicationLagHigh` | A Postgres replica is >30s behind the leader | Write load on the leader, network between nodes, or a stuck replica |
| `MysqlReplicationLagHigh` | A MySQL replica is >30s behind the primary | Same as above — remember MySQL replication here is async, so lag is also an early warning of the write-loss window described in the README |
