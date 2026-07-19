# node-example

Пример конфигов для ноды Remnawave: Docker Compose (remnanode + nginx), шаблоны Xray и модульный Nginx.

**Nginx:** см. [nginx/README.md](nginx/README.md) — фрагменты, `assemble-nginx.sh`, переменные `NGINX_PARTS` / `NGINX_FALLBACK`.

## Первичная настройка хоста (Debian/Ubuntu) и TLS

1. Скопируйте `.env.example` в `.env`, задайте **`SSL_EMAIL`**, **`NGINX_DOMAIN`**, **`NGINX_PARTS`**, **`NGINX_FALLBACK`**, **`REMNANODE_*`**. При использовании Hysteria2 — **`HY2_UDP_PORT`** (по умолчанию `443`). **`NGINX_SSL_DIR`** и **`NGINX_ACME_WEBROOT`** — относительно корня репозитория (по умолчанию **`./nginx`** и **`./nginx/acme-webroot`**).

2. На **HTTP (порт 80)** nginx отдаёт **`/.well-known/acme-challenge/`** из **`NGINX_ACME_WEBROOT`**, остальное редиректится на HTTPS — проверка Let's Encrypt проходит.

3. Режим **`ACME_ISSUE_METHOD=webroot`** (по умолчанию): скрипт **`scripts/bootstrap-host.sh`** при отсутствии LE-сертификатов создаёт **временный self-signed PEM**, собирает nginx из фрагментов, настраивает **UFW**, выполняет **`docker compose up -d`**, после появления порта **80** выпускает сертификат **Let's Encrypt** через webroot и подставляет **`fullchain.pem` / `privkey.key`**, перезапускает **nginx-proxy** и **remnanode**.

4. Альтернатива — **`ACME_ISSUE_METHOD=standalone`**: acme.sh сам слушает **80**; перед выпуском остановите **`nginx-proxy`**, если он уже занимает порт.

5. Запуск bootstrap **от root**:

```bash
sudo bash scripts/bootstrap-host.sh
# или
./remnanode init
```

Скрипт ставит пакеты (**cron**, **socat**, **ufw**, **openssl**, …), **Docker**, **acme.sh**, настраивает firewall, выпускает сертификаты в **`NGINX_SSL_DIR`**.

## Firewall (UFW)

Настройка вынесена в **`scripts/configure-ufw.sh`** (вызывается из bootstrap, можно запустить отдельно).

| Правило | Назначение |
|---------|------------|
| `80/tcp` | HTTP, ACME HTTP-01 |
| `443/tcp` | nginx, VLESS XHTTP/gRPC/WS |
| `HY2_UDP_PORT/udp` | Hysteria2 в Xray (по умолчанию **443/udp**) |
| `REMNANODE_NODE_PORT/tcp` | API панель ↔ нода |
| `HY2_UDP_HOP_PORTS/udp` | опционально, диапазон udpHop (напр. `20000:50000`) |

Переменные в `.env`:

```bash
HY2_UDP_PORT=443
# HY2_UDP_HOP_PORTS=20000:50000   # если включён udpHop в Config Profile
```

Применить без полного bootstrap:

```bash
./remnanode configure-ufw
```

Проверка:

```bash
sudo ufw status numbered
```

## Управление стеком (`remnanode`)

Из любого каталога:

```bash
./remnanode help
./remnanode init            # bootstrap хоста + проверка compose (sudo)
./remnanode configure-ufw   # UFW: nginx + HY2 udp + remnanode API (sudo)
./remnanode assemble-nginx # собрать nginx.conf.template из fragments/
./remnanode start           # assemble-nginx + compose up (идемпотентно)
./remnanode restart
./remnanode update          # git pull + assemble + compose up
./remnanode logs
```

## VLESS WebSocket + TLS

TLS терминирует **nginx**; Xray слушает plain WS на unix-сокете `/dev/shm/xrws.socket`. Включите фрагмент: `NGINX_PARTS=...,ws` и пересоберите nginx.

Reference-конфиги:

- `xray/configs/xray-vless-ws.json` — только WS
- `xray/configs/xray-vless-xhttp-grpc-ws.json` — XHTTP + gRPC + WS
- HY2-профили salamander/gecko уже содержат inbound `WS`

### Настройка в Panel

1. **Config Profiles** — inbound `WS`: `network=ws`, `path=/wspath/`, без TLS на Xray
2. **Hosts** — transport `ws`, path `/wspath/`, security `tls`, SNI = `NGINX_DOMAIN`, port `443`
3. **Nodes / Squads** — включить inbound `WS`

Клиентский URI (пример): `vless://UUID@domain:443?encryption=none&security=tls&sni=domain&type=ws&path=%2Fwspath%2F#ws`

## Hysteria2 (Remnawave Panel v2.7.0+)

HY2 работает через **Xray inbound** в Config Profile, **не через nginx**. Слушает **UDP** на порту из профиля (обычно **443**) — тот же порт должен быть открыт в UFW как **`HY2_UDP_PORT`**.

Reference-конфиги в `xray/configs/`:

- `xray-vless-xhttp-grpc-hysteria2-salamander.json`
- `xray-vless-xhttp-grpc-hysteria2-gecko.json`

### Настройка в Panel

1. **Config Profiles** — вставить JSON из reference (Salamander или Gecko), заменить `CHANGE_ME_*_PASSWORD`
2. **Nodes** — назначить профиль, включить inbound `HYSTERIA2`
3. **Hosts** — protocol `hysteria`, transport `hysteria`, port = `HY2_UDP_PORT`, SNI = `NGINX_DOMAIN`
4. **Internal Squads** — включить inbound `HYSTERIA2`

Сертификаты для HY2: те же PEM, смонтированы в remnanode как `/etc/xray/ssl/fullchain.pem` и `privkey.key`.

Если в профиле включён **udpHop** (`finalmask.quicParams.udpHop.ports`), раскомментируйте **`HY2_UDP_HOP_PORTS`** в `.env` и выполните **`./remnanode configure-ufw`**.

### Известные ограничения

- **Онлайн-статус HY2** в Panel может не отображаться ([issue #399](https://github.com/remnawave/panel/issues/399)) — трафик и счётчики работают
- **Salamander/Gecko** ломают валидный HTTP/3 endpoint; `masquerade` в hysteriaSettings компенсирует зондирование UDP
- Пароль обфускации должен совпадать на сервере и клиенте (Xray-JSON подписка)
- При блокировке UDP 443 — `udpHop` в `finalmask.quicParams` + `HY2_UDP_HOP_PORTS` в `.env`

### Проверка после деплоя

```bash
sudo ufw status | grep -E '443|hysteria|remnanode'
ss -tlnp | grep ':443'              # nginx TCP
ss -ulnp | grep ":${HY2_UDP_PORT:-443}"   # xray UDP (HY2)
curl -sI https://$NGINX_DOMAIN/
./remnanode logs
```

## Запуск сервисов вручную

Из корня репозитория:

```bash
./nginx/assemble-nginx.sh
docker compose up -d
```

## Миграция со старых шаблонов nginx

Раньше выбирался один файл через **`NGINX_CONF_TEMPLATE`**. Теперь — фрагменты и **`NGINX_PARTS`**:

| Было | Стало |
|------|-------|
| `nginx.conf.template.xhttp-grpc` | `NGINX_PARTS=xhttp,grpc`, `NGINX_FALLBACK=decoy` |
| `nginx.conf.template.xhttp` | `NGINX_PARTS=xhttp`, `NGINX_FALLBACK=drop444` |
| `nginx.conf.template.grpc` | `NGINX_PARTS=grpc`, `NGINX_FALLBACK=drop444` |
| (новый) WS | `NGINX_PARTS=ws` или `xhttp,grpc,ws` |

После правки `.env`: `./remnanode assemble-nginx && docker compose restart nginx-proxy`.

## Автопродление TLS

После **`install-cert`** acme.sh ставит задачу **cron** (обычно ежедневный **`acme.sh --cron`**). За ~30 дней до истечения сертификат обновляется на диске; **`--reloadcmd`** перезапускает **nginx-proxy** и **remnanode**. При ошибках продления смотрите **`crontab -l`** и логи **`~/.acme.sh/acme.sh.log`**.

---

**Не полностью «само из коробки» после только `git clone`:** нужны заполненный **`.env`**, **DNS** на **`NGINX_DOMAIN`**, открытые порты (**80/tcp**, **443/tcp**, **HY2_UDP_PORT/udp**), доступ в интернет (Docker Hub, Let's Encrypt). **`./remnanode init`** и **`start`** поднимают стек; **`start`** идемпотентен.
