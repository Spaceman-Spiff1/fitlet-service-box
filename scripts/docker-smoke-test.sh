#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

log() {
  printf '[docker-smoke] %s\n' "$1"
}

die() {
  printf '[docker-smoke][error] %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd docker
require_cmd curl

docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required"

runtime_root="$(mktemp -d "${TMPDIR:-/tmp}/fitlet-service-box-ci.XXXXXX")"
env_file="${runtime_root}/.env.ci"
project_name="fitlet-ci"
compose_args=(-p "$project_name" --env-file "$env_file" -f "$REPO_DIR/docker-compose.yml")

cleanup() {
  docker compose "${compose_args[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  rm -rf "$runtime_root"
}

trap cleanup EXIT

mkdir -p "${runtime_root}/config" "${runtime_root}/downloads" "${runtime_root}/backups"

cat >"$env_file" <<EOF
TZ=Etc/UTC
PUID=1000
PGID=1000
FITLET_IP=127.0.0.1
WEBUI_PORT=8080
TORRENTING_PORT=49152
CONFIG_DIR=${runtime_root}/config
DOWNLOADS_DIR=${runtime_root}/downloads
PROJECT_DIR=${REPO_DIR}
INSTALL_MODE=online-only
QBITTORRENT_IMAGE=lscr.io/linuxserver/qbittorrent:latest
PUBLIC_IP_CHECK_URL=https://ifconfig.me
EXPECTED_DNS=127.0.0.1
EXPECTED_GATEWAY=127.0.0.1
EXPECTED_NTP=127.0.0.1
EXPECTED_SUBNET=127.0.0.0/8
LAN_TEST_TARGET=127.0.0.1
BACKUP_DIR=${runtime_root}/backups
EOF

log "Rendering compose configuration"
docker compose "${compose_args[@]}" config >/dev/null

log "Pulling qBittorrent image"
docker compose "${compose_args[@]}" pull qbittorrent

log "Starting qBittorrent stack"
docker compose "${compose_args[@]}" up -d

log "Waiting for Web UI on http://127.0.0.1:8080"
for _ in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/ >/dev/null; then
    log "Web UI responded successfully"
    break
  fi
  sleep 2
done

if ! curl --fail --silent --show-error --max-time 5 http://127.0.0.1:8080/ >/dev/null; then
  docker compose "${compose_args[@]}" logs qbittorrent || true
  die "qBittorrent Web UI did not become reachable on 127.0.0.1:8080"
fi

log "Inspecting published ports"
ports_output="$(docker ps --filter name='^/qbittorrent$' --format '{{.Ports}}')"
[[ "$ports_output" == *"127.0.0.1:8080->8080/tcp"* ]] || die "Expected Web UI port mapping was not present"
[[ "$ports_output" == *"127.0.0.1:49152->49152/tcp"* ]] || die "Expected torrent TCP port mapping was not present"
[[ "$ports_output" == *"127.0.0.1:49152->49152/udp"* ]] || die "Expected torrent UDP port mapping was not present"

log "Container status"
docker compose "${compose_args[@]}" ps

log "Docker smoke test passed"
