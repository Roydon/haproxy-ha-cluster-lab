# Failover test report -- 20260924-083546

| Engine | Write downtime | Acknowledged writes | Persisted | Lost | Node rejoined as replica |
|---|---|---|---|---|---|
| PostgreSQL (Patroni, synchronous) | 31.42s | 17 | 17 | 0 | yes |
| MySQL (async + promotion script) | 8.16s | 14 | 14 | 0 | yes |

PostgreSQL uses `synchronous_mode` in Patroni: an acknowledged write is durable on
the sync standby before the client sees success, so lost=0 is the expected and
required outcome above -- not just a lucky run.

MySQL uses async replication (a deliberate, documented time-box trade-off --
see README "Limitations"): a write acknowledged by the primary a moment before
it's killed can still be lost if it hadn't shipped to the replica yet. lost=0 above
means none happened to land in that window this run; a nonzero value here is the
real, expected risk of async replication under failure, not a bug.

Environment: Linux x86_64, engine: docker, profile: full.
