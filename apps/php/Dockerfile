# Build context is the repo root (see docker-compose.yml).
FROM php:8.3-fpm-alpine

RUN apk add --no-cache nginx postgresql-dev \
    && docker-php-ext-install pdo_pgsql pdo_mysql

COPY apps/php/nginx.conf /etc/nginx/nginx.conf
COPY apps/php/src/ /var/www/html/
COPY apps/php/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && chown -R www-data:www-data /var/www/html

EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
