#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log() {
  printf '[install] %s\n' "$*"
}

warn() {
  printf '[install][warn] %s\n' "$*" >&2
}

die() {
  printf '[install][error] %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi
}

load_env() {
  if [[ ! -f .env ]]; then
    log "Creating .env from .env.example"
    cp .env.example .env
    warn "Review .env before putting this host into service."
  fi

  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "12" ]]; then
      warn "This repo targets Debian 12. Detected ${PRETTY_NAME:-unknown}. Proceed with caution."
    fi
  else
    warn "Unable to verify operating system. /etc/os-release is missing."
  fi
}

install_packages() {
  local packages=(curl dnsutils tar jq ca-certificates iproute2 iputils-ping unattended-upgrades)
  log "Installing helper packages: ${packages[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${packages[@]}"
  if ! systemctl enable --now unattended-upgrades >/dev/null 2>&1; then
    warn "Unable to enable unattended-upgrades automatically"
  fi
}

check_docker() {
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker is installed but not reachable. Is the daemon running?"
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required."
}

create_dirs() {
  local dirs=("${CONFIG_DIR}" "${DOWNLOADS_DIR}" "${BACKUP_DIR}")
  for dir in "${dirs[@]}"; do
    mkdir -p "$dir"
  done
  chown -R "${PUID}:${PGID}" "${CONFIG_DIR}" "${DOWNLOADS_DIR}"
}

network_sanity() {
  local current_ips dns_servers default_gw
  current_ips="$(hostname -I 2>/dev/null || true)"
  if [[ "$current_ips" != *"${FITLET_IP}"* ]]; then
    warn "Host IP ${FITLET_IP} is not currently assigned. Current addresses: ${current_ips:-none detected}"
  fi

  dns_servers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf 2>/dev/null | xargs echo || true)"
  if [[ "$dns_servers" != *"${EXPECTED_DNS}"* ]]; then
    warn "Expected DNS ${EXPECTED_DNS} not found in /etc/resolv.conf. Found: ${dns_servers:-none detected}"
  fi

  default_gw="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  if [[ -n "$default_gw" && "$default_gw" != "$EXPECTED_GATEWAY" ]]; then
    warn "Expected default gateway ${EXPECTED_GATEWAY}, found ${default_gw}"
  fi
}

deploy_stack() {
  log "Pulling images"
  docker compose pull
  log "Starting stack"
  docker compose up -d
}

print_next_steps() {
  cat <<EOF

Installation complete.

Next steps:
1. Review docker status with: docker compose ps
2. Read qBittorrent startup logs to get the temporary admin password:
   docker logs qbittorrent --tail 100
3. Open the Web UI on http://${FITLET_IP}:${WEBUI_PORT}
4. Change the admin password immediately
5. In qBittorrent, disable UPnP/NAT-PMP and confirm the bind address, port, and download path
6. Run ./scripts/healthcheck.sh and ./scripts/verify-routing.sh
7. Follow packet-capture validation in docs/VALIDATION.md before trusting the box
EOF
}

main() {
  require_root
  check_os
  require_cmd apt-get
  install_packages
  load_env
  check_docker
  create_dirs
  network_sanity
  deploy_stack
  print_next_steps
}

main "$@"