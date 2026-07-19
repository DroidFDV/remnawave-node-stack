#!/usr/bin/env bash
# UFW: порты для remnawave-node-stack (nginx TCP, Hysteria2 UDP, remnanode API).
#
# Читает .env из корня репозитория:
#   REMNANODE_NODE_PORT  — TCP, панель ↔ нода
#   HY2_UDP_PORT         — UDP, Hysteria2 (по умолчанию 443)
#   HY2_UDP_HOP_PORTS    — опционально, диапазон udpHop, напр. 20000:50000
#
# Запуск от root:
#   sudo bash scripts/configure-ufw.sh

set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Запустите скрипт от root: sudo $0" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$PROJECT_ROOT/.env"

if [[ -f "$ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

REMNANODE_NODE_PORT="${REMNANODE_NODE_PORT:-}"
HY2_UDP_PORT="${HY2_UDP_PORT:-443}"
HY2_UDP_HOP_PORTS="${HY2_UDP_HOP_PORTS:-}"

if [[ -z "$REMNANODE_NODE_PORT" ]]; then
    echo "Задайте REMNANODE_NODE_PORT в $ENV_FILE" >&2
    exit 1
fi

if ! command -v ufw >/dev/null 2>&1; then
    echo "ufw не установлен — пропуск настройки firewall" >&2
    exit 0
fi

echo "UFW: SSH, 80/tcp, 443/tcp, ${HY2_UDP_PORT}/udp (hysteria2), ${REMNANODE_NODE_PORT}/tcp (remnanode)"
if [[ -n "$HY2_UDP_HOP_PORTS" ]]; then
    echo "UFW: ${HY2_UDP_HOP_PORTS}/udp (hysteria2 udpHop)"
fi

ufw allow OpenSSH comment 'ssh' 2>/dev/null || ufw allow 22/tcp comment 'ssh'
ufw allow 80/tcp comment 'http'
ufw allow 443/tcp comment 'https'
ufw allow "${HY2_UDP_PORT}"/udp comment 'hysteria2'
ufw allow "${REMNANODE_NODE_PORT}"/tcp comment 'remnanode'

if [[ -n "$HY2_UDP_HOP_PORTS" ]]; then
    ufw allow "${HY2_UDP_HOP_PORTS}"/udp comment 'hysteria2-udphop'
fi

ufw --force enable
ufw reload

echo "UFW готово. Проверка:"
ufw status numbered | grep -E "443|${REMNANODE_NODE_PORT}|hysteria|80/tcp" || ufw status numbered
