# Nginx в remnawave-node-stack

Контейнер **nginx-proxy** терминирует TLS на **TCP 443** и проксирует трафик к Xray (remnanode) через Unix-сокеты в `/dev/shm`.

**Hysteria2 не проходит через nginx** — inbound HY2 в Xray слушает **UDP** (по умолчанию порт **443**) напрямую на хосте. Порт открывается в UFW скриптом `scripts/configure-ufw.sh` (см. корневой README).

## Структура каталога

```
nginx/
  assemble-nginx.sh       # сборка итогового конфига из фрагментов
  entrypoint.sh           # envsubst ${DOMAIN} → nginx.conf в контейнере
  fragments/              # модульные части конфигурации
  nginx.conf.template     # генерируется assemble-nginx.sh (в .gitignore)
  fullchain.pem           # TLS (Let's Encrypt или временный self-signed)
  privkey.key
  acme-webroot/           # HTTP-01 challenge
```

## Утилита `assemble-nginx.sh`

Склеивает фрагменты в `nginx/nginx.conf.template` перед деплоем.

```bash
./nginx/assemble-nginx.sh
./nginx/assemble-nginx.sh --parts xhttp,grpc --fallback decoy
./nginx/assemble-nginx.sh --list
./nginx/assemble-nginx.sh --dry-run
```

Читает переменные из `.env` в корне репозитория (если файл есть). CLI-флаги переопределяют `.env`.

**Автовызов:**

- `./remnanode start`, `update` — перед `docker compose up`
- `./remnanode assemble-nginx` — вручную
- `scripts/bootstrap-host.sh` — перед первым `compose up`

**Порядок склейки:** фрагменты сортируются по числовому префиксу (`00-`, `10-`, …).

## Фрагменты

| Файл | Когда включается | Содержимое |
|------|------------------|------------|
| `00-main.conf` | всегда | `user`, `events`, `http {` глобальные настройки, TLS 2026 defaults |
| `10-server-443-head.conf` | всегда | `server {` listen 443, ssl, `server_name ${DOMAIN}` |
| `20-location-xhttp.conf` | `xhttp` в `NGINX_PARTS` | `/xhttppath/` → `unix:/dev/shm/xrxh.socket` |
| `21-location-grpc.conf` | `grpc` в `NGINX_PARTS` | `/grpcvless/` → `unix:/dev/shm/xrxg.socket` |
| `22-location-ws.conf` | `ws` в `NGINX_PARTS` | `/wspath/` → `unix:/dev/shm/xrws.socket` (WebSocket) |
| `30-fallback-decoy.conf` | `NGINX_FALLBACK=decoy` | HTML-заглушка на `/` |
| `31-fallback-drop444.conf` | `NGINX_FALLBACK=drop444` | `return 444` на `/` |
| `40-server-443-foot.conf` | всегда | `}` — закрытие server 443 |
| `50-server-80.conf` | всегда | ACME webroot + редирект HTTP→HTTPS |
| `99-http-foot.conf` | всегда | `}` — закрытие http |

## Переменные `.env`

```bash
NGINX_PARTS=xhttp,grpc    # xhttp | grpc | ws (хотя бы один)
NGINX_FALLBACK=decoy      # decoy | drop444
NGINX_DOMAIN=example.com  # server_name, передаётся в контейнер как DOMAIN
```

### Пресеты (эквивалент старых шаблонов)

| Было / сценарий | `NGINX_PARTS` | `NGINX_FALLBACK` |
|------|---------------|------------------|
| xhttp-grpc | `xhttp,grpc` | `decoy` |
| xhttp only | `xhttp` | `drop444` |
| grpc only | `grpc` | `drop444` |
| ws only | `ws` | `drop444` |
| xhttp+grpc+ws | `xhttp,grpc,ws` | `decoy` |

## Быстрый старт

```bash
cp .env.example .env
# заполните NGINX_DOMAIN, SSL_EMAIL, REMNANODE_*

NGINX_PARTS=xhttp,grpc
NGINX_FALLBACK=decoy

./remnanode start
```

## Согласование с Xray Config Profile

Пути в nginx должны совпадать с Panel:

| Nginx | Xray Config Profile |
|-------|---------------------|
| `location /xhttppath/` | `streamSettings.xhttpSettings.path` = `/xhttppath/` |
| `location /grpcvless/` | `streamSettings.grpcSettings.serviceName` = `grpcvless` |
| `location /wspath/` | `streamSettings.wsSettings.path` = `/wspath/` |

Reference-конфиги: `xray/configs/xray-vless-ws.json`, `xray-vless-xhttp-grpc-ws.json`, `xray-vless-xhttp-and-grpc.json`, `xray-vless-xhttp-grpc-hysteria2-*.json`.

## TLS (июль 2026)

- `TLSv1.2` + `TLSv1.3`, Mozilla Intermediate cipher suite
- `ssl_prefer_server_ciphers off`
- `server_tokens off`
- OCSP stapling не используется (Let's Encrypt без OCSP с 2025)

## Troubleshooting

**502 на `/xhttppath/`, `/grpcvless/` или `/wspath/`**

- remnanode не слушает сокет — проверьте inbound в Panel и что тег включён на ноде
- `ls -la /dev/shm/xrx*.socket /dev/shm/xrws.socket` на хосте

**404 на `/wspath/`**

- клиент не отправил `Upgrade: websocket` — nginx отсекает не-WS запросы (anti-scan)
- path в клиенте/Host должен быть точно `/wspath/`

**ACME не проходит**

- DNS `NGINX_DOMAIN` → IP сервера
- порт 80 открыт, `/.well-known/acme-challenge/` не редиректится на HTTPS (см. `50-server-80.conf`)

**Проверка синтаксиса nginx**

```bash
docker exec nginx-proxy nginx -t
```

**Пересобрать конфиг после смены `.env`**

```bash
./remnanode assemble-nginx
docker compose restart nginx-proxy
```

**HY2: UDP не открыт / клиент не подключается**

- проверьте UFW: `./remnanode configure-ufw` (открывает `HY2_UDP_PORT/udp` из `.env`)
- порт в Panel (`inbounds[].port`) должен совпадать с `HY2_UDP_PORT`
- при udpHop задайте `HY2_UDP_HOP_PORTS` и снова `configure-ufw`
