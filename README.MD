# node-example

Пример конфигов для ноды Remnawave: Docker Compose (remnanode + nginx), шаблоны Xray и Nginx.

## Первичная настройка хоста (Debian/Ubuntu) и TLS

1. Скопируйте `.env.example` в `.env`, задайте **`SSL_EMAIL`**, **`NGINX_DOMAIN`**. **`NGINX_SSL_DIR`** и **`NGINX_ACME_WEBROOT`** — относительно корня репозитория (по умолчанию **`./nginx`** и **`./nginx/acme-webroot`**).

2. На **HTTP (порт 80)** nginx отдаёт **`/.well-known/acme-challenge/`** из **`NGINX_ACME_WEBROOT`**, остальное редиректится на HTTPS — проверка Let’s Encrypt проходит.

3. Режим **`ACME_ISSUE_METHOD=webroot`** (по умолчанию): скрипт **`scripts/bootstrap-host.sh`** при отсутствии LE-сертификатов создаёт **временный self-signed PEM**, чтобы **nginx** мог слушать **443**, затем выполняет **`docker compose up -d`**, после появления порта **80** выпускает сертификат **Let’s Encrypt** через webroot и подставляет **`fullchain.pem` / `privkey.key`**, перезапускает **nginx-proxy**. Отдельный первый запуск только в **standalone** не требуется.

4. Альтернатива — **`ACME_ISSUE_METHOD=standalone`**: acme.sh сам слушает **80**; перед выпуском остановите **`nginx-proxy`**, если он уже занимает порт.

5. Запуск скрипта **от root**:

```bash
sudo bash scripts/bootstrap-host.sh
```

Скрипт ставит пакеты (**cron**, **socat**, **ufw**, **openssl**, …), **Docker**, **acme.sh**, выпускает сертификаты в **`NGINX_SSL_DIR`**.

## Управление стеком (`remnanode`)

Из любого каталога:

```bash
./remnanode help
./remnanode init    # bootstrap хоста + проверка compose (bootstrap — от sudo)
./remnanode start   # при webroot bootstrap уже делал compose up — команда идемпотентна
./remnanode logs
```

## Запуск сервисов вручную

Из корня репозитория:

```bash
docker compose up -d
```

## Автопродление TLS

После **`install-cert`** acme.sh ставит задачу **cron** (обычно ежедневный **`acme.sh --cron`**). За ~30 дней до истечения сертификат обновляется на диске; **`--reloadcmd`** в bootstrap перезапускает **nginx-proxy**, чтобы подхватить новые PEM. Полностью без ручных действий это работает, если не меняли путь к репозиторию и cron может выполнить **`docker compose`** (при ошибках продления смотрите **`crontab -l`** и логи **`~/.acme.sh/acme.sh.log`**).

---

**Не полностью «само из коробки» после только `git clone`:** нужны заполненный **`.env`** (он не в репозитории), **DNS** записи на сервер для **`NGINX_DOMAIN`**, открытые **80/443**, доступ в интернет (Docker Hub, Let’s Encrypt). **`./remnanode init`** и затем **`start`** при **`ACME_ISSUE_METHOD=webroot`** после bootstrap уже поднимают стек; **`start`** повторно делает **`compose up`** — это безопасно и идемпотентно.
