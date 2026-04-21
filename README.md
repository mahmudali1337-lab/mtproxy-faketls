# MTProxy + FakeTLS + спонсорский тег (Teleproxy)

Поднимает [`teleproxy`](https://github.com/teleproxy/teleproxy) — высокопроизводительный MTProto-прокси для Telegram c FakeTLS-маскировкой (TLS 1.3, Chrome ClientHello + GREASE + Dynamic Record Sizing) и поддержкой спонсорского тега `PROXY_TAG` от [@MTProxybot](https://t.me/MTProxybot). Образ: `ghcr.io/teleproxy/teleproxy:latest`.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/mahmudali1337-lab/mtproxy-faketls/main/install.sh -o install.sh
sudo bash install.sh
```

Скрипт спросит:
- **FakeTLS домен** (`www.cloudflare.com` по умолчанию) — под него маскируется трафик.
- **PROXY_TAG** — 32 hex от @MTProxybot (можно пропустить и добавить позже).

В конце выводит готовую `tg://proxy?...` ссылку с правильным `ee`-секретом.

## Опции

```bash
sudo bash install.sh \
  -d www.cloudflare.com \
  -t 0123456789abcdef0123456789abcdef \
  -p 443
```

| Опция | Переменная | Описание |
|---|---|---|
| `-d, --domain` | `EE_DOMAIN` | FakeTLS-домен (TLS 1.3 backend) |
| `-t, --tag` | `PROXY_TAG` | Спонсорский тег от @MTProxybot |
| `-p, --port` | `PORT` | Клиентский порт (443) |
| `--stats-port` | `STATS_PORT` | Порт статистики (8888, только localhost) |
| `-s, --secret` | `SECRET` | Готовый 32-hex secret |
| `-w, --workers` | `WORKERS` | Воркеры (1) |
| `--uninstall` | — | Снести контейнер, образ, `/var/lib/teleproxy` |

## Спонсорский баннер «Спонсор прокси»

1. Запусти скрипт без `-t` → получишь `IP:PORT` и `ee`-secret.
2. [@MTProxybot](https://t.me/MTProxybot) → `/newproxy` → введи `IP:PORT` и `ee`-secret → бот выдаёт `tag` (32 hex).
3. У того же бота `/setpromo` → выбери канал, который будет светиться в шапке.
4. Перезапусти: `sudo bash install.sh -d <domain> -t <tag>`.

## docker-compose

```bash
export SECRET=$(head -c 16 /dev/urandom | xxd -ps)
export EE_DOMAIN=www.cloudflare.com
export PROXY_TAG=...        # опционально
docker compose up -d
docker compose logs -f
```

Готовая ссылка появится в логах — `teleproxy` сам печатает `tg://` и QR при старте.

## Управление

```bash
docker logs -f teleproxy
docker restart teleproxy
docker exec teleproxy kill -HUP 1     # перечитать конфиг без рестарта
sudo bash install.sh --uninstall
```

## Что под капотом

- Образ: `ghcr.io/teleproxy/teleproxy:latest` (~8 MB, Alpine, multi-arch amd64/arm64)
- FakeTLS: live-probe реального backend, mirror-extension order, Dynamic Record Sizing, anti-replay (HMAC-SHA256, 120s timestamp window)
- Failover: невалидный handshake форвардится на реальный `EE_DOMAIN` — DPI видит обычный HTTPS
- Persistence: `/var/lib/teleproxy` хранит `proxy-multi.conf` (обновляется крон-задачей раз в 6 ч) и сгенерированный `config.toml`
- Секрет в ссылке: `ee` + `<32 hex>` + `<hex(domain)>` — формирует FakeTLS-режим клиента
