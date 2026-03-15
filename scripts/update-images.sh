#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

if [[ ! -f .env ]]; then
  printf '[update][error] Missing .env. Create it before updating.\n' >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

INSTALL_MODE="${INSTALL_MODE:-auto}"
BUNDLE_DIR="${FITLET_BUNDLE_SOURCE_DIR:-$REPO_DIR/bundle}"
IMAGE_BUNDLE_DIR="${BUNDLE_DIR}/images"

load_bundled_images() {
  local archives=()

  shopt -s nullglob
  archives=("$IMAGE_BUNDLE_DIR"/*.tar)
  shopt -u nullglob

  (( ${#archives[@]} > 0 )) || return 1

  printf '[update] Loading bundled images from %s\n' "$IMAGE_BUNDLE_DIR"
  for archive in "${archives[@]}"; do
    docker load -i "$archive"
  done
}

case "$INSTALL_MODE" in
  bundle-only)
    if ! load_bundled_images; then
      printf '[update][error] INSTALL_MODE=bundle-only but no image archives were found in %s\n' "$IMAGE_BUNDLE_DIR" >&2
      exit 1
    fi
    ;;
  auto)
    if load_bundled_images; then
      printf '[update] Using bundled images from the local repo copy\n'
    else
      printf '[update] Pulling newer container images\n'
      docker compose pull
    fi
    ;;
  online-only)
    printf '[update] Pulling newer container images\n'
    docker compose pull
    ;;
  *)
    printf '[update][error] Unsupported INSTALL_MODE: %s\n' "$INSTALL_MODE" >&2
    exit 1
    ;;
esac

printf '[update] Current image inventory after refresh\n'
docker compose images

printf '[update] Recreating services with the refreshed images\n'
docker compose up -d

printf '[update] Final container status\n'
docker compose ps

cat <<EOF

Review the qBittorrent release notes and container changelog before treating an image update as routine.
Docker image updates are not harmless background noise on a single-purpose box. Validate routing and application behavior after every change.
EOF
