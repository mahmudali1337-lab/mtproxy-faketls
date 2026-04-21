#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  err "Запусти от root: sudo bash install.sh"
  exit 1
fi

CONTAINER_NAME="${CONTAINER_NAME:-teleproxy}"
IMAGE="${IMAGE:-ghcr.io/teleproxy/teleproxy:latest}"
PORT="${PORT:-443}"
STATS_PORT="${STATS_PORT:-8888}"
WORKERS="${WORKERS:-1}"
EE_DOMAIN="${EE_DOMAIN:-}"
PROXY_TAG="${PROXY_TAG:-}"
SECRET="${SECRET:-}"
DATA_DIR="${DATA_DIR:-/var/lib/teleproxy}"

usage() {
  cat <<EOF
Usage: sudo bash install.sh [options]

Options:
  -d, --domain <domain>     FakeTLS домен (например www.cloudflare.com)
  -t, --tag <hex>           Спонсорский тег PROXY_TAG от @MTProxybot (32 hex)
  -p, --port <port>         Клиентский порт (по умолчанию 443)
      --stats-port <port>   Порт статистики (по умолчанию 8888)
  -s, --secret <hex>        Использовать готовый 32-hex secret вместо генерации
  -w, --workers <N>         Кол-во воркеров (по умолчанию 1)
      --uninstall           Удалить контейнер, образ и data
  -h, --help                Показать помощь
EOF
}

UNINSTALL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)    EE_DOMAIN="$2"; shift 2;;
    -t|--tag)       PROXY_TAG="$2"; shift 2;;
    -p|--port)      PORT="$2"; shift 2;;
    --stats-port)   STATS_PORT="$2"; shift 2;;
    -s|--secret)    SECRET="$2"; shift 2;;
    -w|--workers)   WORKERS="$2"; shift 2;;
    --uninstall)    UNINSTALL=1; shift;;
    -h|--help)      usage; exit 0;;
    *) err "Неизвестная опция: $1"; usage; exit 1;;
  esac
done

if [[ $UNINSTALL -eq 1 ]]; then
  info "Удаление контейнера ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  docker image rm "${IMAGE}" 2>/dev/null || true
  rm -rf "${DATA_DIR}"
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
  if [[ -z "${EE_DOMAIN}" ]]; then
    echo
    warn "FakeTLS-домен — под него маскируется трафик (TLS 1.3)."
    warn "Должен быть реальный сайт с TLS 1.3 (cloudflare, microsoft, итд)."
    read -r -p "FakeTLS домен [www.cloudflare.com]: " EE_DOMAIN || true
    EE_DOMAIN="${EE_DOMAIN:-www.cloudflare.com}"
  fi
}

ask_tag() {
  if [[ -z "${PROXY_TAG}" ]]; then
    echo
    warn "Спонсорский тег (PROXY_TAG) даёт @MTProxybot после /newproxy."
    warn "Без него прокси работает, но без баннера спонсорского канала."
    read -r -p "PROXY_TAG (32 hex, Enter — пропустить): " PROXY_TAG || true
  fi
  if [[ -n "${PROXY_TAG}" && ! "${PROXY_TAG}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    err "PROXY_TAG должен быть 32 hex символа."
    exit 1
  fi
}

generate_secret() {
  if [[ -n "${SECRET}" ]]; then
    if [[ ! "${SECRET}" =~ ^[0-9a-fA-F]{32}$ ]]; then
      err "SECRET должен быть 32 hex символа."
      exit 1
    fi
    ok "Использую переданный secret."
    return
  fi
  info "Генерирую 16-байтовый secret..."
  SECRET="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  ok "Secret: ${SECRET}"
}

detect_ip() {
  local ip
  ip="$(curl -fsSL --max-time 5 https://api.ipify.org || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsSL --max-time 5 https://icanhazip.com || true)"
  [[ -z "$ip" ]] && ip="$(curl -fsSL --max-time 5 https://ifconfig.me || true)"
  [[ -z "$ip" ]] && ip="$(hostname -I | awk '{print $1}')"
  echo "$ip" | tr -d '[:space:]'
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
  info "Подтягиваю образ ${IMAGE}..."
  docker pull "${IMAGE}" >/dev/null

  info "Поднимаю контейнер ${CONTAINER_NAME}..."
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  mkdir -p "${DATA_DIR}"

  local ext_ip
  ext_ip="$(detect_ip)"

  local args=(
    run -d
    --name "${CONTAINER_NAME}"
    --restart unless-stopped
    -p "${PORT}:${PORT}"
    -p "127.0.0.1:${STATS_PORT}:${STATS_PORT}"
    -v "${DATA_DIR}:/opt/teleproxy/data"
    --ulimit nofile=65536:65536
    -e "SECRET=${SECRET}"
    -e "PORT=${PORT}"
    -e "STATS_PORT=${STATS_PORT}"
    -e "WORKERS=${WORKERS}"
    -e "EE_DOMAIN=${EE_DOMAIN}"
  )
  [[ -n "${PROXY_TAG}" ]]  && args+=( -e "PROXY_TAG=${PROXY_TAG}" )
  [[ -n "${ext_ip}" ]]     && args+=( -e "EXTERNAL_IP=${ext_ip}" )

  args+=( "${IMAGE}" )

  docker "${args[@]}" >/dev/null
  sleep 3
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    err "Контейнер не запустился. Логи:"
    docker logs "${CONTAINER_NAME}" || true
    exit 1
  fi
  ok "Контейнер работает."
}

print_links() {
  local ip secret_link domain_hex
  ip="$(detect_ip)"
  domain_hex="$(printf '%s' "${EE_DOMAIN}" | od -An -tx1 | tr -d ' \n')"
  secret_link="ee${SECRET}${domain_hex}"

  echo
  echo "============================================================"
  ok "Teleproxy (MTProto + FakeTLS) поднят!"
  echo "============================================================"
  echo "  Server         : ${ip}"
  echo "  Port           : ${PORT}"
  echo "  FakeTLS домен  : ${EE_DOMAIN}"
  [[ -n "${PROXY_TAG}" ]] && echo "  PROXY_TAG      : ${PROXY_TAG}"
  echo "  Stats          : http://127.0.0.1:${STATS_PORT}/stats (только с сервера)"
  echo "------------------------------------------------------------"
  echo "  Ссылка для пользователей (FakeTLS, с префиксом ee...):"
  echo "  ${secret_link}"
  echo
  echo "  tg://proxy?server=${ip}&port=${PORT}&secret=${secret_link}"
  echo "  https://t.me/proxy?server=${ip}&port=${PORT}&secret=${secret_link}"
  echo "------------------------------------------------------------"
  echo "  Secret для @MTProxybot (БЕЗ ee и БЕЗ домена, ровно 32 hex):"
  echo "  ${SECRET}"
  echo "============================================================"
  echo
  if [[ -z "${PROXY_TAG}" ]]; then
    warn "Чтобы получить спонсорский баннер:"
    warn "  1) Открой @MTProxybot → /newproxy"
    warn "  2) Адрес:   ${ip}:${PORT}"
    warn "  3) Secret:  ${SECRET}    (короткий, БЕЗ ee и БЕЗ домена!)"
    warn "  4) Бот вернёт PROXY_TAG (32 hex) → /setpromo → выбери канал."
    warn "  5) Перезапусти с тегом и тем же секретом:"
    warn "     sudo bash install.sh -d ${EE_DOMAIN} -s ${SECRET} -t <PROXY_TAG>"
  fi
  echo
  echo "Логи:        docker logs -f ${CONTAINER_NAME}"
  echo "Перезапуск:  docker restart ${CONTAINER_NAME}"
  echo "Удалить:     sudo bash install.sh --uninstall"
}

main() {
  install_docker
  ask_domain
  generate_secret
  ask_tag
  open_firewall
  run_container
  print_links
}

main "$@"
