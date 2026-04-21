# MTProxy + FakeTLS + спонсорский тег

Поднимает MTProto Proxy для Telegram на базе [`9seconds/mtg`](https://github.com/9seconds/mtg) v2 в Docker. Поддерживает FakeTLS (маскировка под HTTPS) и спонсорский канал в шапке клиента.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/<USER>/<REPO>/main/install.sh -o install.sh
sudo bash install.sh
```

Скрипт спросит:
- FakeTLS домен (по умолчанию `www.cloudflare.com`)
- Спонсорский тег (32 hex от [@MTProxybot](https://t.me/MTProxybot), можно пропустить)

В конце выведет `tg://proxy?...` ссылку.

## Параметры

```bash
sudo bash install.sh \
  -d www.cloudflare.com \
  -t 0123456789abcdef0123456789abcdef \
  -p 443
```

| Опция | Описание |
|---|---|
| `-d, --domain` | FakeTLS домен (под который маскируется трафик) |
| `-t, --tag` | Спонсорский тег от @MTProxybot |
| `-p, --port` | Порт (по умолчанию 443) |
| `-s, --secret` | Использовать существующий hex secret |
| `--uninstall` | Снести контейнер и образ |

## Спонсорский тег (промо-канал в шапке)

1. Открой [@MTProxybot](https://t.me/MTProxybot) в Telegram.
2. `/newproxy` → введи `IP:PORT` и FakeTLS secret (выведет скрипт).
3. Бот вернёт `tag` (32 hex). Передай его в `-t`.
4. `/setpromo` у того же бота → выбери канал, который будет светиться.

## docker-compose

```bash
SECRET=ee... SPONSOR_TAG=... PORT=443 docker compose up -d
```

## Управление

```bash
docker logs -f mtproxy
docker restart mtproxy
sudo bash install.sh --uninstall
```
