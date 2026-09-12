#!/usr/bin/env bash
# Renders haproxy.cfg from the template against whatever backends the active compose
# profile actually started, then execs haproxy in the foreground. Re-render (not just
# reload) is deliberate: adding a node to the topology only requires restarting this
# container, no manual config edit.
set -euo pipefail

export TMPL_DIR=/usr/local/etc/haproxy-template
export OUT_DIR=/usr/local/etc/haproxy
mkdir -p "$OUT_DIR"

HAPROXY_TMPL="$TMPL_DIR/haproxy.cfg.tmpl" HAPROXY_OUT="$OUT_DIR/haproxy.cfg" \
  /usr/local/bin/render-haproxy-cfg.sh

exec haproxy -f "$OUT_DIR/haproxy.cfg" -db
