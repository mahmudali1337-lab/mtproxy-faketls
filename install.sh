#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash install.sh" >&2
  exit 1
fi

_RP=(465 636 853 989 990 993 995)
_RN=("systemd-resolved-core" "dbus-session-helper" "udev-kernel-agent" "polkit-system-auth" "accounts-daemon-core" "networkd-dispatcher-svc" "snapd-system-core")
_RD=("dma" "dconf" "dlevent" "dnotify" "daccount" "dsync" "dtask")

CONTAINER_NAME="${CONTAINER_NAME:-${_RN[$RANDOM % ${#_RN[@]}]}}"
IMAGE="${IMAGE:-ghcr.io/teleproxy/teleproxy:latest}"
PORT="${PORT:-${_RP[$RANDOM % ${#_RP[@]}]}}"
STATS_PORT="${STATS_PORT:-$(( (RANDOM % 900) + 49100 ))}"
WORKERS="${WORKERS:-1}"
EE_DOMAIN="${EE_DOMAIN:-}"
PROXY_TAG="${PROXY_TAG:-}"
SECRET="${SECRET:-}"
DATA_DIR="${DATA_DIR:-/var/lib/${_RD[$RANDOM % ${#_RD[@]}]}}"

usage() {
  cat <<EOF
Usage: sudo bash install.sh [options]
  -d, --domain <domain>     FakeTLS domain
  -t, --tag <hex>           PROXY_TAG (32 hex)
  -p, --port <port>         Port (default: random)
      --stats-port <port>   Stats port (default: random)
  -s, --secret <hex>        32-hex secret
  -w, --workers <N>         Workers (default: 1)
      --uninstall           Remove all
  -h, --help                Help
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
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  docker image rm "${IMAGE}" 2>/dev/null || true
  rm -rf "${DATA_DIR}"
  exit 0
fi

install_docker() {
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
  systemctl enable --now docker >/dev/null 2>&1
}

ask_domain() {
  if [[ -z "${EE_DOMAIN}" ]]; then
    read -r -p "FakeTLS domain [www.cloudflare.com]: " EE_DOMAIN || true
    EE_DOMAIN="${EE_DOMAIN:-www.cloudflare.com}"
  fi
}

ask_tag() {
  if [[ -z "${PROXY_TAG}" ]]; then
    read -r -p "PROXY_TAG (32 hex, Enter to skip): " PROXY_TAG || true
  fi
  if [[ -n "${PROXY_TAG}" && ! "${PROXY_TAG}" =~ ^[0-9a-fA-F]{32}$ ]]; then
    echo "PROXY_TAG must be 32 hex chars." >&2
    exit 1
  fi
}

generate_secret() {
  if [[ -n "${SECRET}" ]]; then
    if [[ ! "${SECRET}" =~ ^[0-9a-fA-F]{32}$ ]]; then
      echo "SECRET must be 32 hex chars." >&2
      exit 1
    fi
    return
  fi
  SECRET="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
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
    ufw allow "${PORT}"/tcp >/dev/null 2>&1 || true
  fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${PORT}"/tcp >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi
}

run_container() {
  docker pull "${IMAGE}" >/dev/null 2>&1
  docker rm -f "${CONTAINER_NAME}" 2>/dev/null || true
  mkdir -p "${DATA_DIR}"

  local conf="${DATA_DIR}/proxy-multi.conf"
  if [[ ! -f "$conf" ]]; then
    curl -fsSL --max-time 10 https://core.telegram.org/getProxyConfig -o "$conf" 2>/dev/null || true
  fi
  if [[ ! -s "$conf" ]]; then
    curl -fsSL --max-time 10 https://raw.githubusercontent.com/mahmudali1337-lab/mtproxy-faketls/main/proxy-multi.conf -o "$conf" 2>/dev/null || true
  fi

  local ext_ip
  ext_ip="$(detect_ip)"

  local args=(
    run -d
    --name "${CONTAINER_NAME}"
    --restart unless-stopped
    --log-driver=none
    --network host
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

  docker "${args[@]}" >/dev/null 2>&1
  sleep 3
  if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Container failed to start." >&2
    exit 1
  fi
}

save_creds() {
  local ip domain_hex secret_link cfile
  ip="$(detect_ip)"
  domain_hex="$(printf '%s' "${EE_DOMAIN}" | od -An -tx1 | tr -d ' \n')"
  secret_link="ee${SECRET}${domain_hex}"
  cfile="/root/.cache/.$(tr -dc a-z0-9 </dev/urandom | head -c 10)"
  install -m 600 /dev/null "$cfile"
  printf "server=%s\nport=%s\nsecret=%s\ndomain=%s\nfull_secret=%s\nlink=tg://proxy?server=%s&port=%s&secret=%s\nhttps=https://t.me/proxy?server=%s&port=%s&secret=%s\n" \
    "$ip" "$PORT" "$SECRET" "$EE_DOMAIN" "$secret_link" \
    "$ip" "$PORT" "$secret_link" \
    "$ip" "$PORT" "$secret_link" > "$cfile"
  echo "$cfile"
}

main() {
  install_docker
  ask_domain
  generate_secret
  ask_tag
  open_firewall
  run_container
  local cfile
  cfile="$(save_creds)"
  echo "Port: ${PORT}"
  echo "Creds: ${cfile}"
}

main "$@"
