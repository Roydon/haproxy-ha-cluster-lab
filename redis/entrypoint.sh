#!/usr/bin/env sh
set -eu
: "${NODE_NAME:?NODE_NAME must be set}"
# shellcheck disable=SC2016  # single quotes intentional: envsubst does its own substitution
envsubst '${NODE_NAME}' < /etc/redis-template/redis.conf.tmpl > /etc/redis/redis.conf
exec redis-server /etc/redis/redis.conf
