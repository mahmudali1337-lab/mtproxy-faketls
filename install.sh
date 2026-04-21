#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Запусти от root: sudo bash install.sh"
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-mtproxy}"
IMAGE="${IMAGE:-nineseconds/mtg:2}"
PORT="${PORT:-443}"
FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN:-}"
SPONSOR_TAG="${SPONSOR_TAG:-}"
SECRET="${SECRET:-}"

usage() {
  cat <<EOF
Usage: sudo bash install.sh [options]

Options:
  -d, --domain <domain>     FakeTLS домен (по умолчанию www.cloudflare.com)
  -t, --tag <hex>           Спонсорский тег от @MTProxybot (32 hex символа)
  -p, --port <port>         Порт (по умолчанию 443)
  -s, --secret <hex>        Использовать готовый hex secret вместо генерации
      --uninstall           Удалить контейнер и образ
  -h, --help                Показать помощь
EOF
}

UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)   FAKE_TLS_DOMAIN="$2"; shift 2;;
    -t|--tag)      SPONSOR_TAG="$2"; shift 2;;
    -p|--port)     PORT="$2"; shift 2;;
    -s|--secret)   SECRET="$2"; shift 2;;
    --uninstall)   UNINSTALL=1; shift;;
    -h|--help)     usage; exit 0;;
    *) err "Неизвестная опция: $1"; usage; exit 1;;
  esac
done

if [[ $UNINSTALL -eq 1 ]]; then
  info "Удаление контейнера ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  docker image rm "${IMAGE}" 2>/dev/null || true
  ok "Удалено."
  exit 0
fi

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    ok "Docker уже установлен: $(docker --version)"
    return
  fi
  info "Устанавливаю Docker..."
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  ok "Docker установлен."
}

ask_domain() {
  if [[ -z "${FAKE_TLS_DOMAIN}" ]]; then
    read -r -p "FakeTLS домен [www.cloudflare.com]: " FAKE_TLS_DOMAIN || true
    FAKE_TLS_DOMAIN="${FAKE_TLS_DOMAIN:-www.cloudflare.com}"
  fi
}

ask_tag() {
  if [[ -z "${SPONSOR_TAG}" ]]; then
    echo
    warn "Спонсорский тег получи у @MTProxybot в Telegram (команда /newproxy)."
    read -r -p "Спонсорский тег (32 hex, Enter — пропустить): " SPONSOR_TAG || true
  fi
  if [[ -n "${SPONSOR_TAG}" && ! "${SPONSOR_TAG}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    err "Тег должен быть 32 hex символа."
    exit 1
  fi
}

generate_secret() {
  if [[ -n "${SECRET}" ]]; then
    ok "Использую переданный secret."
    return
  fi
  info "Генерирую FakeTLS secret для домена ${FAKE_TLS_DOMAIN}..."
  SECRET="$(docker run --rm "${IMAGE}" generate-secret "${FAKE_TLS_DOMAIN}")"
  if [[ -z "${SECRET}" ]]; then
    err "Не удалось сгенерировать secret."
    exit 1
  fi
  ok "Secret: ${SECRET}"
}

detect_ip() {
  local ip
  ip="$(curl -fsSL https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsSL https://ifconfig.me || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
  echo "$ip"
}

open_firewall() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${PORT}"/tcp || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}"/tcp || true
    firewall-cmd --reload || true
  fi
}

run_container() {
  info "Поднимаю контейнер ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true

  local args=(
    run -d
    --name "${CONTAINER_NAME}"
    --restart unless-stopped
    -p "${PORT}:3128"
  )

  args+=( -e MTG_DEBUG=false )
  args+=( -e MTG_NETWORK_BIND="0.0.0.0:3128" )
  if [[ -n "${SPONSOR_TAG}" ]]; then
    args+=( -e MTG_PROBE_PROXIED=true )
  fi

  args+=( "${IMAGE}" )
  args+=( run )
  if [[ -n "${SPONSOR_TAG}" ]]; then
    args+=( -t "${SPONSOR_TAG}" )
  fi
  args+=( "${SECRET}" )

  docker "${args[@]}" >/dev/null
  sleep 2
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    err "Контейнер не запустился. Логи:"
    docker logs "${CONTAINER_NAME}" || true
    exit 1
  fi
  ok "Контейнер работает."
}

print_links() {
  local ip
  ip="$(detect_ip)"
  echo
  echo "============================================================"
  ok "MTProxy + FakeTLS поднят!"
  echo "============================================================"
  echo "  Server : ${ip}"
  echo "  Port   : ${PORT}"
  echo "  Secret : ${SECRET}"
  echo "  Domain : ${FAKE_TLS_DOMAIN}"
  [[ -n "${SPONSOR_TAG}" ]] && echo "  Tag    : ${SPONSOR_TAG}"
  echo "------------------------------------------------------------"
  echo "  tg://proxy?server=${ip}&port=${PORT}&secret=${SECRET}"
  echo "  https://t.me/proxy?server=${ip}&port=${PORT}&secret=${SECRET}"
  echo "============================================================"
  echo
  warn "Если указан спонсорский тег — подтверди прокси у @MTProxybot (/setpromo по той же ссылке)."
}

main() {
  install_docker
  ask_domain
  docker pull "${IMAGE}" >/dev/null
  generate_secret
  ask_tag
  open_firewall
  run_container
  print_links
}

main "$@"
