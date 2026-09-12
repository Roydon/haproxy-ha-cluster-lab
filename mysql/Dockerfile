# One image for primary and replicas alike; MYSQL_ROLE at runtime picks the config and
# init SQL to render. The health-check HTTP server runs as a second process in the
# same container (not a sidecar) so HAProxy's "check port 8081" reaches it at the same
# hostname:IP as the mysql server itself. Build context is the repo root.
FROM mysql:8.4

RUN microdnf install -y gettext python3 && microdnf clean all

COPY mysql/conf/my.cnf /etc/mysql-template/my.cnf.tmpl
COPY mysql/init-primary/01-init.sql.tmpl /etc/mysql-template/init-primary.sql.tmpl
COPY mysql/init-replica/01-replicate.sql.tmpl /etc/mysql-template/init-replica.sql.tmpl
COPY mysql/health/server.py /usr/local/bin/health-server.py
COPY mysql/entrypoint.sh /usr/local/bin/haha-entrypoint.sh
RUN chmod +x /usr/local/bin/haha-entrypoint.sh

EXPOSE 3306 8081
ENTRYPOINT ["/usr/local/bin/haha-entrypoint.sh"]
CMD ["mysqld"]
