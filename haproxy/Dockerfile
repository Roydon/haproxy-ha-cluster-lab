# Build context is the repo root (see docker-compose.yml: build.context: .) so this
# image can pull in scripts/render-haproxy-cfg.sh alongside its own template.
FROM haproxy:3.0-alpine
USER root
RUN apk add --no-cache bash
COPY haproxy/templates/haproxy.cfg.tmpl /usr/local/etc/haproxy-template/haproxy.cfg.tmpl
COPY scripts/render-haproxy-cfg.sh /usr/local/bin/render-haproxy-cfg.sh
COPY haproxy/entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/render-haproxy-cfg.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
