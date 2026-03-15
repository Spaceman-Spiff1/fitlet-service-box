#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

log() {
  printf '[backup] %s\n' "$1"
}

warn() {
  printf '[backup][warn] %s\n' "$1" >&2
}

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/fitlet-service-box}"
CONFIG_DIR="${CONFIG_DIR:-/srv/qbittorrent/config}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/fitlet-service-box-${TIMESTAMP}.tar.gz"
BACKUP_ITEMS=(
  README.md
  .env.example
  .gitattributes
  .gitignore
  docker-compose.yml
  install.sh
  bundle/README.md
  scripts
  docs
  templates
  systemd
)

mkdir -p "$BACKUP_DIR"

if [[ -d "$CONFIG_DIR" ]]; then
  BACKUP_ITEMS+=("$CONFIG_DIR")
else
  warn "qBittorrent config directory ${CONFIG_DIR} does not exist. The archive will include the repo only."
fi

log "Creating ${ARCHIVE}"
tar \
  --exclude='.git' \
  --exclude='.env' \
  -czf "$ARCHIVE" \
  "${BACKUP_ITEMS[@]}"

printf 'Backup created: %s\n' "$ARCHIVE"
printf 'Note: .env is excluded by design. Back it up separately and securely.\n'
