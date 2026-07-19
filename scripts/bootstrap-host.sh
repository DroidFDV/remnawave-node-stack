#!/usr/bin/env bash
# Установка пакетов, Docker и выпуск TLS через acme.sh (Let's Encrypt).
#
# Перед запуском: заполните .env в корне репозитория (SSL_EMAIL, NGINX_DOMAIN, NGINX_SSL_DIR).
# NGINX_SSL_DIR — относительно корня репозитория (например ./nginx) или абсолютный путь.
# ACME_ISSUE_METHOD:
#   webroot (рекомендуется) — если нет LE-сертификата, создаётся временный self-signed PEM,
#   поднимается docker compose, выпускается Let's Encrypt через webroot, ключи заменяются.
#   standalone — acme слушает :80 сам (остановите nginx-proxy, если занят порт).
# Редирект HTTP→HTTPS не затрагивает /.well-known/acme-challenge/.
#
# Запуск только от root:
#   sudo bash scripts/bootstrap-host.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запустите скрипт от root: sudo $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "Не найден $ENV_FILE — скопируйте из .env.example и заполните переменные." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

# Путь относительно корня репозитория (например ./nginx); абсолютный тоже допустим.
NGINX_SSL_DIR="${NGINX_SSL_DIR:-./nginx}"
if [[ "$NGINX_SSL_DIR" != /* ]]; then
    NGINX_SSL_DIR="$PROJECT_ROOT/${NGINX_SSL_DIR#./}"
fi

NGINX_ACME_WEBROOT="${NGINX_ACME_WEBROOT:-./nginx/acme-webroot}"
if [[ "$NGINX_ACME_WEBROOT" != /* ]]; then
    NGINX_ACME_WEBROOT="$PROJECT_ROOT/${NGINX_ACME_WEBROOT#./}"
fi

ACME_ISSUE_METHOD="${ACME_ISSUE_METHOD:-webroot}"

if [[ -z "${SSL_EMAIL:-}" || -z "${NGINX_DOMAIN:-}" || -z "${REMNANODE_NODE_PORT:-}" ]]; then
    echo "Задайте SSL_EMAIL, NGINX_DOMAIN и REMNANODE_NODE_PORT в $ENV_FILE" >&2
    exit 1
fi

echo "Домен: $NGINX_DOMAIN"
echo "Каталог PEM: $NGINX_SSL_DIR"
echo "Режим выпуска: $ACME_ISSUE_METHOD"

mkdir -p "$NGINX_SSL_DIR"
mkdir -p "$NGINX_ACME_WEBROOT/.well-known/acme-challenge"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y cron socat ufw curl ca-certificates openssl

bash "$SCRIPT_DIR/configure-ufw.sh"

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
fi

ensure_dummy_tls() {
    if [[ -s "$NGINX_SSL_DIR/fullchain.pem" && -s "$NGINX_SSL_DIR/privkey.key" ]]; then
        echo "TLS: найдены существующие fullchain.pem и privkey.key"
        return 0
    fi
    echo "TLS: создаю временный self-signed сертификат (7 дней), чтобы nginx поднялся на 443 до выпуска LE"
    openssl req -x509 -nodes -newkey rsa:2048 -days 7 \
        -keyout "$NGINX_SSL_DIR/privkey.key" \
        -out "$NGINX_SSL_DIR/fullchain.pem" \
        -subj "/CN=$NGINX_DOMAIN" \
        -addext "subjectAltName=DNS:$NGINX_DOMAIN" 2>/dev/null \
        || openssl req -x509 -nodes -newkey rsa:2048 -days 7 \
            -keyout "$NGINX_SSL_DIR/privkey.key" \
            -out "$NGINX_SSL_DIR/fullchain.pem" \
            -subj "/CN=$NGINX_DOMAIN"
    chmod 0644 "$NGINX_SSL_DIR/fullchain.pem" 2>/dev/null || true
    chmod 0640 "$NGINX_SSL_DIR/privkey.key" 2>/dev/null || true
}

wait_for_port_80() {
    local i
    for i in $(seq 1 90); do
        if ss -ltn 2>/dev/null | grep -qE ':80\s'; then
            echo "Порт 80 слушается"
            return 0
        fi
        sleep 1
    done
    echo "Ошибка: за 90 с порт 80 не открылся (nginx-proxy не поднялся?)" >&2
    return 1
}

assemble_nginx() {
    bash "$PROJECT_ROOT/nginx/assemble-nginx.sh"
}

compose_up_and_issue_webroot() {
    ensure_dummy_tls
    assemble_nginx
    echo "Запуск стека: docker compose up -d"
    (cd "$PROJECT_ROOT" && docker compose up -d)
    wait_for_port_80
    "$ACME" --issue -w "$NGINX_ACME_WEBROOT" -d "$NGINX_DOMAIN" --force
}

if [[ "$ACME_ISSUE_METHOD" == "webroot" ]]; then
    echo "Webroot: $NGINX_ACME_WEBROOT"
else
    echo "Standalone: перед выпуском освободите порт 80 (например: docker compose -f \"$PROJECT_ROOT/docker-compose.yml\" stop nginx-proxy)"
fi

if [[ ! -x "${HOME:-/root}/.acme.sh/acme.sh" ]]; then
    curl https://get.acme.sh | sh -s email="$SSL_EMAIL"
fi

ACME="${HOME:-/root}/.acme.sh/acme.sh"

"$ACME" --set-default-ca --server letsencrypt

if [[ "$ACME_ISSUE_METHOD" == "webroot" ]]; then
    compose_up_and_issue_webroot
else
    "$ACME" --issue --standalone -d "$NGINX_DOMAIN" --force
fi

# --reloadcmd сохраняется acme.sh и вызывается при продлении (встроенный cron root).
# cd в каталог репозитория: compose и .env на месте; при сбое проверьте PATH для cron.
"$ACME" --install-cert -d "$NGINX_DOMAIN" \
    --key-file "$NGINX_SSL_DIR/privkey.key" \
    --fullchain-file "$NGINX_SSL_DIR/fullchain.pem" \
    --reloadcmd "cd \"$PROJECT_ROOT\" && docker compose restart nginx-proxy remnanode"

echo "Готово: $NGINX_SSL_DIR/fullchain.pem и privkey.key"
