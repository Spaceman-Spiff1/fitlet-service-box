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

BACKUP_DIR="${BACKUP_DIR:-/var/backups/fitlet-service-box}"
CONFIG_DIR="${CONFIG_DIR:-/srv/qbittorrent/config}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="${BACKUP_DIR}/fitlet-service-box-${TIMESTAMP}.tar.gz"

mkdir -p "$BACKUP_DIR"

tar \
  --exclude='.git' \
  --exclude='.env' \
  -czf "$ARCHIVE" \
  README.md \
  .env.example \
  docker-compose.yml \
  install.sh \
  bundle/README.md \
  scripts \
  docs \
  templates \
  systemd \
  "$CONFIG_DIR"

printf 'Backup created: %s\n' "$ARCHIVE"
printf 'Note: .env is excluded by design. Back it up separately and securely.\n'
