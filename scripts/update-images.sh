#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

log() {
  printf '[update] %s\n' "$1"
}

warn() {
  printf '[update][warn] %s\n' "$1" >&2
}

die() {
  printf '[update][error] %s\n' "$1" >&2
  exit 1
}

if [[ ! -f .env ]]; then
  die "Missing .env. Create it before updating."
fi

set -a
# shellcheck disable=SC1091
source ./.env
set +a

INSTALL_MODE="${INSTALL_MODE:-auto}"
BUNDLE_DIR="${FITLET_BUNDLE_SOURCE_DIR:-$REPO_DIR/bundle}"
IMAGE_BUNDLE_DIR="${BUNDLE_DIR}/images"
QBITTORRENT_IMAGE="${QBITTORRENT_IMAGE:-}"

[[ -n "$QBITTORRENT_IMAGE" ]] || die "QBITTORRENT_IMAGE is not set in .env"
command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"
docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required"

image_available() {
  docker image inspect "$QBITTORRENT_IMAGE" >/dev/null 2>&1
}

load_bundled_images() {
  local archives=()

  shopt -s nullglob
  archives=("$IMAGE_BUNDLE_DIR"/*.tar)
  shopt -u nullglob

  (( ${#archives[@]} > 0 )) || return 1

  log "Loading bundled images from $IMAGE_BUNDLE_DIR"
  for archive in "${archives[@]}"; do
    docker load -i "$archive"
  done
}

case "$INSTALL_MODE" in
  bundle-only)
    if ! load_bundled_images; then
      die "INSTALL_MODE=bundle-only but no image archives were found in ${IMAGE_BUNDLE_DIR}"
    fi
    if ! image_available; then
      die "INSTALL_MODE=bundle-only but ${QBITTORRENT_IMAGE} is still unavailable after loading the bundle"
    fi
    ;;
  auto)
    if load_bundled_images; then
      if image_available; then
        log "Using bundled images from the local repo copy"
      else
        warn "Bundled images were loaded, but ${QBITTORRENT_IMAGE} is still unavailable. Falling back to registry pull."
        docker compose pull
      fi
    else
      log "Pulling newer container images"
      docker compose pull
    fi
    ;;
  online-only)
    log "Pulling newer container images"
    docker compose pull
    ;;
  *)
    die "Unsupported INSTALL_MODE: ${INSTALL_MODE}"
    ;;
esac

image_available || die "Target image ${QBITTORRENT_IMAGE} is not present after refresh"

log "Current image inventory after refresh"
docker compose images

log "Recreating services with the refreshed images"
docker compose up -d

log "Final container status"
docker compose ps

cat <<EOF

Review the qBittorrent release notes and container changelog before treating an image update as routine.
Docker image updates are not harmless background noise on a single-purpose box. Validate routing and application behavior after every change.
EOF
