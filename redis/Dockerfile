# Build context is the repo root (see docker-compose.yml).
FROM redis:7-alpine
RUN apk add --no-cache gettext
COPY redis/templates/redis.conf.tmpl /etc/redis-template/redis.conf.tmpl
COPY redis/entrypoint.sh /entrypoint.sh
RUN mkdir -p /etc/redis && chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
