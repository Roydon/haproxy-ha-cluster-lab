# haproxy-ha-cluster-lab

Load-balanced app + database HA cluster: HAProxy with read/write-aware routing in
front of Patroni/PostgreSQL and MySQL, a Redis Cluster, PHP and Node app nodes, and
Prometheus + Grafana monitoring — runnable as a Docker Compose lab on a laptop, and
shipped as Ansible roles for a real Ubuntu fleet.

[![lint](https://github.com/Roydon/haproxy-ha-cluster-lab/actions/workflows/lint.yml/badge.svg)](https://github.com/Roydon/haproxy-ha-cluster-lab/actions/workflows/lint.yml)
[![verify](https://github.com/Roydon/haproxy-ha-cluster-lab/actions/workflows/verify.yml/badge.svg)](https://github.com/Roydon/haproxy-ha-cluster-lab/actions/workflows/verify.yml)
[![full-stack](https://github.com/Roydon/haproxy-ha-cluster-lab/actions/workflows/full-stack.yml/badge.svg)](https://github.com/Roydon/haproxy-ha-cluster-lab/actions/workflows/full-stack.yml)

There's no hosted demo — the proof is that GitHub Actions re-runs the whole cluster and
a live failover drill on every push, and again every night against the full 3-node
topology. The table below is real output from the most recent nightly run, committed
back automatically.

## Latest failover results (auto-updated nightly by `full-stack.yml`)

<!-- FAILOVER_RESULTS_START -->
# Failover test report -- 20260923-084301

| Engine | Write downtime | Acknowledged writes | Persisted | Lost | Node rejoined as replica |
|---|---|---|---|---|---|
| PostgreSQL (Patroni, synchronous) | 26.98s | 17 | 17 | 0 | yes |
| MySQL (async + promotion script) | 10.72s | 16 | 16 | 0 | yes |

PostgreSQL uses `synchronous_mode` in Patroni: an acknowledged write is durable on
the sync standby before the client sees success, so lost=0 is the expected and
required outcome above -- not just a lucky run.

MySQL uses async replication (a deliberate, documented time-box trade-off --
see README "Limitations"): a write acknowledged by the primary a moment before
it's killed can still be lost if it hadn't shipped to the replica yet. lost=0 above
means none happened to land in that window this run; a nonzero value here is the
real, expected risk of async replication under failure, not a bug.

Environment: Linux x86_64, engine: docker, profile: full.

<!-- FAILOVER_RESULTS_END -->

## Topology

```mermaid
flowchart TB
    subgraph Edge
        CF["Cloudflare\n(proxy + LB, see docs/cloudflare.md)"]
    end

    CF --> HAP["HAProxy\n:80 app · :5000/:5001 pg · :3307/:3308 mysql · :8404 stats"]

    subgraph App tier
        PHP1["PHP-FPM + Nginx"]
        PHP2["PHP-FPM + Nginx"]
        NODE1["Node + Express"]
    end
    HAP --> PHP1
    HAP --> PHP2
    HAP --> NODE1

    subgraph PostgreSQL HA — Patroni + etcd
        PG1["pg1"]
        PG2["pg2"]
        PG3["pg3"]
        ETCD["etcd (DCS)"]
        PG1 <-. sync replication .-> PG2
        PG1 <-. replication .-> PG3
        PG1 -. leader election .-> ETCD
        PG2 -. leader election .-> ETCD
        PG3 -. leader election .-> ETCD
    end
    HAP -->|":5000 write → leader\n:5001 read → replicas"| PG1

    subgraph MySQL HA — async + promotion script
        MY1["mysql1"]
        MY2["mysql2"]
        MY3["mysql3"]
        MY1 -. async replication .-> MY2
        MY1 -. async replication .-> MY3
    end
    HAP -->|":3307 write → primary\n:3308 read → replicas"| MY1

    subgraph Redis Cluster
        R1["redis1"]
        R2["redis2"]
        R3["redis3"]
        R1 <--> R2
        R2 <--> R3
        R1 <--> R3
    end
    PHP1 -.-> R1
    NODE1 -.-> R1

    subgraph Monitoring
        PROM["Prometheus"]
        GRAF["Grafana"]
        PROM --> GRAF
    end
    PG1 -.->|postgres_exporter| PROM
    MY1 -.->|mysqld_exporter| PROM
    R1 -.->|redis_exporter| PROM
    HAP -.->|prometheus-exporter| PROM
```

## Port map

| Port | Purpose |
|---|---|
| `:80` | App tier (PHP + Node), round robin |
| `:5000` | PostgreSQL write → current Patroni leader |
| `:5001` | PostgreSQL read → replicas |
| `:3307` | MySQL write → current primary |
| `:3308` | MySQL read → replicas |
| `:8404` | HAProxy stats page + `/metrics` (Prometheus format) |
| `:9090` | Prometheus |
| `:3000` | Grafana (provisioned dashboard, no manual import) |

Host-side bindings for all of the above are overridable via `.env` — see
`.env.example`. Defaults dodge two common local collisions: macOS AirPlay Receiver
squats on `5000`/`7000`, and rootless Podman can't bind ports below 1024, so the app
tier defaults to host `8080` instead of `80`.

## Quickstart

Requires Docker (or Podman) with Compose, and ~4 GB free RAM for the full topology
(~1.5 GB for `lite`). See "Resource note" below before running the full profile.

```bash
git clone https://github.com/Roydon/haproxy-ha-cluster-lab.git
cd haproxy-ha-cluster-lab
cp .env.example .env

make up          # full topology: 3 pg + 3 mysql + 3 redis + 2 app + monitoring
# make up-lite   # CI-sized subset instead: 1 pg leader + replica, 1 mysql primary
                 # + replica, 1 redis, haproxy, prometheus, one app

make verify      # PASS/FAIL table across every routing path
make failover    # kills the pg leader and mysql primary under write load,
                 # measures downtime + lost writes, confirms automatic rejoin

make load        # optional: watch Grafana/HAProxy stats react to steady write load
make down        # tear down (drops volumes)
```

Grafana: http://localhost:3000 (`admin` / see `.env`). Prometheus:
http://localhost:9090. HAProxy stats: http://localhost:8404/stats.

## Resource note

The full topology is ~20 containers. Give Docker Desktop / your Podman machine at
least **8 GB RAM**. On a smaller machine, use `make up-lite` — CI runs on this
profile for exactly that reason, so it's a first-class path, not an afterthought.

## Limitations (read before you rely on this for anything real)

- **MySQL uses async replication + a promotion script, not Group Replication.**
  This was a deliberate, time-boxed call: MySQL 8 Group Replication is fussier to
  bring up reliably (arm64 + containerized networking in particular), and async
  replication with an explicit, tested promotion/rejoin script (`scripts/mysql-
  promote.sh`, `scripts/mysql-rejoin.sh`) is a well-understood, honestly-documented
  trade-off rather than a fragile attempt at the more complex option. The real
  consequence: an acknowledged write on the primary a moment before it fails *can*
  be lost if it hadn't shipped to the replica yet — `make failover`'s report states
  this plainly every run, and shows the actual number, not an assumed zero.
  PostgreSQL, by contrast, runs Patroni with `synchronous_mode` — an acknowledged
  write is durable on the sync standby before the client ever sees success, so
  zero lost writes there is a guarantee, not luck.
- **etcd runs single-node in the Docker Compose lab**, not the 3-node quorum a real
  deployment wants. The Ansible `postgres_ha` role does bootstrap a proper 3-node
  etcd cluster on real hosts — this simplification is lab-only, to avoid the
  complexity of variable-size etcd bootstrapping across Compose profiles.
- **`node_exporter` in the lab reports the container/VM's view, not your Mac's own
  hardware.** The Ansible role points it at real host metrics on real servers.
  Meaningful in the lab as a demonstration; the numbers themselves aren't your
  laptop's.
- **No TLS between database nodes in the lab** (MySQL replication uses
  `GET_SOURCE_PUBLIC_KEY` instead of a real cert chain). See "Production checklist"
  below for what changes on real infrastructure.
- **HAProxy's health-check ports (`8008` Patroni, `8081` MySQL sidecar) are open on
  the same network as the databases themselves**, appropriate for a private VPC/
  firewalled subnet, not for direct internet exposure — `docs/cloudflare.md` and
  the production checklist cover firewalling the app tier from the internet, but
  the database tier should never be internet-facing in the first place.

## Production checklist

Before pointing this at anything with real traffic or data:

- [ ] Enable TLS between all database nodes (Postgres `sslmode=verify-full`,
      MySQL `REQUIRE SSL` + real certs, Redis `tls-*` options).
- [ ] Move `group_vars/all.yml` secrets into a vault (`ansible-vault` at minimum;
      a real secrets manager for anything beyond a small team).
- [ ] Set up automated backups: `pg_basebackup`/WAL archiving for Postgres,
      `mysqldump`/binlog archiving or Percona XtraBackup for MySQL, `BGSAVE` +
      AOF shipping for Redis. None of this lab does backups — it's HA, not DR.
- [ ] Size `mem_limit`/instance types for real workload, not lab defaults.
- [ ] Firewall the database tier so only the app tier and HAProxy can reach it
      (UFW rules in the `common` role are a starting point, not a finished policy).
- [ ] Decide a real RPO/RTO and confirm MySQL's async-replication write-loss
      window (see "Limitations") is acceptable for it — or invest the extra time
      Group Replication or semisynchronous replication would take.
- [ ] Replace the etcd single-node DCS assumption anywhere it still exists;
      confirm the Ansible role's 3-node etcd bootstrap matches your final host
      count.
- [ ] Point Grafana's admin password and Prometheus's retention window at real
      values, not lab defaults.

## Runbook, Cloudflare setup

- [`docs/runbook.md`](docs/runbook.md) — failover, rejoining a node, rotating
  credentials, adding an app node, what each alert means.
- [`docs/cloudflare.md`](docs/cloudflare.md) — origin pool + health checks, DNS/
  proxy records, real-IP restoration, firewall rules restricting the app tier to
  Cloudflare's ranges. No live Cloudflare account in this lab; these are the exact
  settings for a real one.

## Development

See [`Makefile`](Makefile) for every target (`up`, `up-lite`, `down`, `verify`,
`failover`, `load`, `lint`, `deploy`). `make deploy HOSTS=<group>` applies the
Ansible playbook to a real inventory group (`app`, `db`, or any group you define).

MIT licensed — see [`LICENSE`](LICENSE).
