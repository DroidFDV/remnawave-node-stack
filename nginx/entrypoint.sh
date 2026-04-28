#!/bin/sh
set -eu

# Подстановка DOMAIN из окружения (docker-compose / .env), без изменения $host и др. директив nginx.
export DOMAIN="${DOMAIN:-example.domain}"

if ! command -v envsubst >/dev/null 2>&1; then
    apk add --no-cache gettext >/dev/null
fi

envsubst '${DOMAIN}' < /etc/nginx/nginx.conf.template > /etc/nginx/nginx.conf
exec nginx -g 'daemon off;'
