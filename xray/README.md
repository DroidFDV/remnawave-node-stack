# Управление генератором Xray Config Profile

Генератор собирает JSON для **Remnawave Panel → Config Profiles** из модульных фрагментов (как `nginx/assemble-nginx.sh`).

На ноде Xray-конфиг **пушит Panel**. Локальный `xray-generated.json` — шаблон: собрали → скопировали в UI → назначили Nodes / Squads.

Все пути в `.env` и CLI — **относительно корня репозитория** (не абсолютные). Пути внутри JSON (`/dev/shm/...`, `/etc/xray/ssl/...`) — абсолютные пути в контейнере/ОС.

Требуется **python3**.

## Структура

```
xray/
  assemble-xray.sh     # генератор
  README.md            # это руководство
  fragments/           # модули Config Profile
  configs/             # reference + xray-generated.json (gitignore)
  extra/               # доп. куски (например xmux для клиента)
```

| Путь | Назначение |
|------|------------|
| `xray/fragments/*.json` | Исходники (редактировать при смене path/obfs) |
| `xray/configs/xray-generated.json` | Результат сборки (не коммитится) |
| `xray/configs/xray-vless-*.json` | Старые ручные reference (без генератора) |

## Быстрый старт

Из корня репозитория:

```bash
# 1. переменные в .env
XRAY_PARTS=xhttp,grpc,ws
XRAY_HY2_MODE=salamander          # off | salamander | gecko
XRAY_OUTPUT=xray/configs/xray-generated.json
HY2_UDP_PORT=443
HY2_OBFS_PASSWORD=your-strong-password

# 2. согласовать nginx (те же транспорты)
NGINX_PARTS=xhttp,grpc,ws

# 3. собрать
./remnanode assemble-xray
# или: ./xray/assemble-xray.sh

# 4. проверить
python3 -m json.tool xray/configs/xray-generated.json >/dev/null
./xray/assemble-xray.sh --dry-run | head

# 5. вставить JSON в Panel → Config Profiles
# 6. Hosts / Nodes / Squads — включить нужные inbound tags
```

`./remnanode start` и `update` сами вызывают `assemble-xray` перед `compose up`.

## Команды

### Через `remnanode`

```bash
./remnanode assemble-xray   # сборка по .env
./remnanode start           # assemble-nginx + assemble-xray + up
./remnanode update          # git pull + оба assemble + up
```

### Напрямую `assemble-xray.sh`

```bash
./xray/assemble-xray.sh
./xray/assemble-xray.sh --parts xhttp,grpc,ws --hy2-mode salamander
./xray/assemble-xray.sh --output xray/configs/xray-generated.json
./xray/assemble-xray.sh --list
./xray/assemble-xray.sh --dry-run
./xray/assemble-xray.sh -h
```

| Флаг | Описание |
|------|----------|
| `--parts LIST` | `xhttp`, `grpc`, `ws`, `hysteria2` через запятую |
| `--hy2-mode MODE` | `off` \| `salamander` \| `gecko` |
| `--output PATH` | Относительный путь результата |
| `--list` | Фрагменты и алиасы |
| `--dry-run` | Печать JSON в stdout, файл не писать |
| `-h` / `--help` | Справка |

CLI переопределяет `.env`. Абсолютный `--output` (`/tmp/...`) — ошибка.

## Переменные `.env`

```bash
# относительно корня репозитория
XRAY_PARTS=xhttp,grpc              # хотя бы один: xhttp|grpc|ws|hysteria2
XRAY_HY2_MODE=off                  # off | salamander | gecko
XRAY_OUTPUT=xray/configs/xray-generated.json

HY2_UDP_PORT=443                   # port inbound HYSTERIA2
HY2_OBFS_PASSWORD=...              # finalmask password → в JSON
```

### Когда включается HY2

| Условие | HYSTERIA2 |
|---------|-----------|
| `XRAY_HY2_MODE=off` | нет |
| `XRAY_HY2_MODE=salamander` или `gecko` | да (даже без `hysteria2` в parts) |
| `hysteria2` в `XRAY_PARTS` и mode `off` | **ошибка** |
| `hysteria2` в parts + `salamander`/`gecko` | да |

## Пресеты

| Сценарий | `XRAY_PARTS` | `XRAY_HY2_MODE` | `NGINX_PARTS` |
|----------|--------------|-----------------|---------------|
| XHTTP + gRPC | `xhttp,grpc` | `off` | `xhttp,grpc` |
| + WebSocket | `xhttp,grpc,ws` | `off` | `xhttp,grpc,ws` |
| только WS | `ws` | `off` | `ws` |
| + HY2 Salamander | `xhttp,grpc,ws` | `salamander` | `xhttp,grpc,ws` |
| + HY2 Gecko | `xhttp,grpc,ws` | `gecko` | `xhttp,grpc,ws` |

После смены пресета:

```bash
./remnanode assemble-xray
./remnanode assemble-nginx
docker compose restart nginx-proxy   # если меняли NGINX_PARTS
# JSON из xray-generated.json → обновить Config Profile в Panel
./remnanode configure-ufw            # если меняли HY2_UDP_PORT / hop
```

## Фрагменты

Порядок склейки: `00-base` → выбранные inbound → `90-tail`. Запятые между inbound вставляет скрипт (python3).

| Файл | Когда | Содержимое |
|------|-------|------------|
| `00-base.json` | всегда | `log`, `stats`, `policy` |
| `20-inbound-xhttp.json` | `xhttp` | VLESS XHTTP → `/dev/shm/xrxh.socket`, path `/xhttppath/` |
| `21-inbound-grpc.json` | `grpc` | VLESS gRPC → `/dev/shm/xrxg.socket`, `serviceName=grpcvless` |
| `22-inbound-ws.json` | `ws` | VLESS WS → `/dev/shm/xrws.socket`, path `/wspath/` |
| `23-inbound-hysteria2-salamander.json` | HY2 + salamander | HYSTERIA2 + finalmask salamander |
| `24-inbound-hysteria2-gecko.json` | HY2 + gecko | то же + `packetSize: "512-1200"` |
| `90-tail.json` | всегда | `outbounds`, `routing` |

Плейсхолдеры в HY2-фрагментах (подставляет генератор):

- `__HY2_UDP_PORT__` → число из `HY2_UDP_PORT`
- `__HY2_OBFS_PASSWORD__` → строка из `HY2_OBFS_PASSWORD` (JSON-экранирование)

### Как добавить новый inbound

1. Создайте `xray/fragments/2N-inbound-<name>.json` — один JSON-объект inbound.
2. Добавьте алиас в `assemble-xray.sh` (`has_part` / `inbound_rels`).
3. Обновите `--list`, этот README и при необходимости nginx-фрагмент.
4. Проверьте: `./xray/assemble-xray.sh --parts ...,<name> --dry-run | python3 -m json.tool`.

## Согласование с nginx

| Tag в Xray | `XRAY_PARTS` | `NGINX_PARTS` | Path / socket |
|------------|--------------|---------------|---------------|
| `XHTTP` | `xhttp` | `xhttp` | `/xhttppath/` → `xrxh.socket` |
| `GRPC` | `grpc` | `grpc` | `/grpcvless/` → `xrxg.socket` |
| `WS` | `ws` | `ws` | `/wspath/` → `xrws.socket` |
| `HYSTERIA2` | mode ≠ `off` | — | UDP `HY2_UDP_PORT` (мимо nginx) |

Несовпадение path/serviceName с nginx → 502 у клиентов.

## Workflow: от сборки до Panel

1. Правите `.env` (`XRAY_*`, при HY2 — пароль и порт).
2. `./remnanode assemble-xray` (и `assemble-nginx`, если меняли транспорты).
3. Открываете `xray/configs/xray-generated.json`.
4. Panel → **Config Profiles** → вставить / заменить JSON.
5. **Hosts** — transport/security/SNI/port под каждый inbound.
6. **Nodes** — профиль; **Squads** — включить tags (`XHTTP`, `GRPC`, `WS`, `HYSTERIA2`).
7. Клиенты получают обновлённую подписку.

Смена только локального JSON **без** обновления Profile в Panel ноду не меняет.

## Проверка целостности

```bash
# валидный JSON
./xray/assemble-xray.sh --dry-run | python3 -m json.tool >/dev/null

# tags
./xray/assemble-xray.sh --dry-run | python3 -c \
  'import json,sys; print([i["tag"] for i in json.load(sys.stdin)["inbounds"]])'

# файл, не директория (важно для bind-mount-ловушек в других сервисах)
test -f xray/configs/xray-generated.json && ! test -d xray/configs/xray-generated.json

# список фрагментов
./xray/assemble-xray.sh --list
```

Ожидаемые отказы:

```bash
./xray/assemble-xray.sh --output /tmp/x.json          # абсолютный путь
./xray/assemble-xray.sh --parts hysteria2 --hy2-mode off
./xray/assemble-xray.sh --parts nope
./xray/assemble-xray.sh --hy2-mode invalid
```

## Troubleshooting

**`python3 is required`**

- Установите `python3` на хосте (склейка JSON и экранирование пароля).

**`XRAY_OUTPUT must be relative to repo root`**

- Пишите `xray/configs/...`, не `/opt/...` и не `/tmp/...`.

**`XRAY_OUTPUT is a directory`**

- Удалите директорию с именем файла (`rm -rf xray/configs/xray-generated.json` если это dir), затем снова `assemble-xray`.

**`hysteria2 is in XRAY_PARTS but XRAY_HY2_MODE=off`**

- Задайте `XRAY_HY2_MODE=salamander` или `gecko`, либо уберите `hysteria2` из parts.

**Клиент HY2 не коннектится**

- Пароль в Profile = `HY2_OBFS_PASSWORD` на клиенте.
- Порт в JSON = `HY2_UDP_PORT`; UFW: `./remnanode configure-ufw`.
- PEM смонтированы в remnanode: `/etc/xray/ssl/fullchain.pem`, `privkey.key`.

**502 на XHTTP/gRPC/WS**

- Profile в Panel не совпадает с nginx path/socket.
- Inbound tag не включён на ноде/Squad.
- Сокеты: `ls -la /dev/shm/xrx*.socket /dev/shm/xrws.socket`.

**Собрали JSON, но нода «старая»**

- Нужно обновить Config Profile в Panel — локальный файл на ноду сам не применяется.

## Связанные документы

- [nginx/README.md](../nginx/README.md) — сборка nginx, TLS, paths
- [README.MD](../README.MD) — стек, UFW, bootstrap
- Ручные reference: `xray/configs/xray-vless-*.json`
