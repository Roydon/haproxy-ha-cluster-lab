#!/usr/bin/env sh
set -eu
: "${NODE_NAME:?NODE_NAME must be set}"
envsubst '${NODE_NAME}' < /etc/redis-template/redis.conf.tmpl > /etc/redis/redis.conf
exec redis-server /etc/redis/redis.conf
