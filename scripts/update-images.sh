#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

if [[ ! -f .env ]]; then
  printf '[update][error] Missing .env. Create it before updating.\n' >&2
  exit 1
fi

printf '[update] Pulling newer container images\n'
docker compose pull

printf '[update] Current image inventory after pull\n'
docker compose images

printf '[update] Recreating services with the updated images\n'
docker compose up -d

printf '[update] Final container status\n'
docker compose ps

cat <<EOF

Review the qBittorrent release notes and container changelog before treating an image update as routine.
Docker image updates are not harmless background noise on a single-purpose box. Validate routing and application behavior after every change.
EOF