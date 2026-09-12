# haproxy-ha-cluster-lab

Load-balanced app + database HA cluster: HAProxy read/write split in front of
Patroni/PostgreSQL and MySQL, a Redis cluster, PHP and Node app nodes, and
Prometheus + Grafana monitoring. Runs as a Docker Compose lab and ships as
Ansible roles for a real Ubuntu fleet.

<!-- CI badges and failover results table are added as the workflows land. -->

## Status

Work in progress — the full Docker Compose lab (Postgres HA, MySQL HA, HAProxy
routing, Redis Cluster, the app tier, and Prometheus + Grafana monitoring) is up
and verified end-to-end. Ansible roles, docs and CI are still being built.

## Quickstart (partial, more to come)

```bash
cp .env.example .env
docker compose up -d etcd1 pg1 pg2 haproxy
```

Write through the leader, read from a replica:

```bash
psql "host=localhost port=5000 dbname=appdb user=appuser password=appuser_lab_pw" -c "select 1;"
psql "host=localhost port=5001 dbname=appdb user=appuser password=appuser_lab_pw" -c "select 1;"
```

(Host ports default to avoid common local collisions — see `.env.example`.)
