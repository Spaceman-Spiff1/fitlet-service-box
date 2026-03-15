#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

PUBLIC_IP_CHECK_URL="${PUBLIC_IP_CHECK_URL:-https://ifconfig.me}"

section() {
  printf '\n== %s ==\n' "$1"
}

section "IP addresses"
ip -br address || true

section "Default route"
ip route show default || true

section "Resolvers from /etc/resolv.conf"
if [[ -r /etc/resolv.conf ]]; then
  awk '/^nameserver/ {print $2}' /etc/resolv.conf || true
else
  echo "/etc/resolv.conf is not readable"
fi

section "Docker containers"
docker compose ps || true

section "qBittorrent container"
docker ps --filter name=^/qbittorrent$ --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true

section "Public IP"
curl --silent --show-error --max-time 10 "$PUBLIC_IP_CHECK_URL" || echo "Unable to determine public IP"
printf '\n'

section "Disk space"
df -h / "${DOWNLOADS_DIR:-/srv/downloads}" 2>/dev/null || df -h || true