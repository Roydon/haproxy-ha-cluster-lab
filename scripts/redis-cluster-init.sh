#!/usr/bin/env sh
# Idempotent Redis Cluster bootstrap: waits for redis1 (always present) plus whichever
# of redis2/redis3 the active compose profile also started, then runs `--cluster create`
# once. A single-node "cluster" is valid (it just owns all 16384 slots), which is what
# makes this the same script for both the lite and full profiles.
set -eu

CANDIDATES="redis1 redis2 redis3"
READY=""

for h in $CANDIDATES; do
  if getent hosts "$h" >/dev/null 2>&1; then
    echo "waiting for $h..."
    i=0
    until redis-cli -h "$h" -p 6379 ping >/dev/null 2>&1; do
      i=$((i + 1))
      if [ "$i" -ge 30 ]; then
        echo "$h did not become ready in time" >&2
        exit 1
      fi
      sleep 2
    done
    READY="$READY $h:6379"
  fi
done

if [ -z "$READY" ]; then
  echo "no redis hosts resolvable, nothing to cluster" >&2
  exit 1
fi

FIRST_HOST=$(echo "$READY" | awk '{print $1}' | cut -d: -f1)
STATE=$(redis-cli -h "$FIRST_HOST" -p 6379 cluster info | grep '^cluster_state:' | tr -d '\r')
if [ "$STATE" = "cluster_state:ok" ]; then
  echo "cluster already initialized on $FIRST_HOST ($STATE)"
  exit 0
fi

COUNT=$(echo "$READY" | wc -w | tr -d ' ')
if [ "$COUNT" -lt 3 ]; then
  # redis-cli --cluster create refuses fewer than 3 masters outright. A one-node
  # "cluster" (the lite profile) is still valid Redis Cluster mode -- it just owns
  # every hash slot itself -- so assign them directly instead of using that tool.
  echo "only $COUNT node(s) ready ($READY); assigning all slots directly (single-node cluster)"
  redis-cli -h "$FIRST_HOST" -p 6379 cluster addslotsrange 0 16383
else
  echo "creating cluster with:$READY"
  # shellcheck disable=SC2086
  redis-cli --cluster create $READY --cluster-yes
fi
