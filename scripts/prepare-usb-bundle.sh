#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

BUNDLE_DIR="$REPO_DIR/bundle"
HELPER_BUNDLE_DIR="${BUNDLE_DIR}/packages/helpers"
DOCKER_BUNDLE_DIR="${BUNDLE_DIR}/packages/docker"
IMAGE_BUNDLE_DIR="${BUNDLE_DIR}/images"
MANIFEST_FILE="${BUNDLE_DIR}/manifest.txt"

HELPER_PACKAGES=(curl dnsutils tar jq ca-certificates iproute2 iputils-ping unattended-upgrades)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

log() {
  printf '[bundle] %s\n' "$*"
}

warn() {
  printf '[bundle][warn] %s\n' "$*" >&2
}

die() {
  printf '[bundle][error] %s\n' "$*" >&2
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

load_env_like() {
  local env_file
  env_file=".env.example"
  if [[ -f .env ]]; then
    env_file=".env"
  fi

  set -a
  # shellcheck disable=SC1091
  source "$env_file"
  set +a
}

check_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "${ID:-}" != "debian" || "${VERSION_ID:-}" != "12" ]]; then
      warn "This bundle helper targets Debian 12. Detected ${PRETTY_NAME:-unknown}. Proceed with caution."
    fi
  fi
}

prepare_dirs() {
  mkdir -p "$HELPER_BUNDLE_DIR/partial" "$DOCKER_BUNDLE_DIR/partial" "$IMAGE_BUNDLE_DIR"
  rm -f "$HELPER_BUNDLE_DIR"/*.deb "$DOCKER_BUNDLE_DIR"/*.deb "$IMAGE_BUNDLE_DIR"/*.tar "$MANIFEST_FILE"
}

download_package_set() {
  local label="$1"
  local archive_dir="$2"
  shift 2

  log "Downloading ${label} into ${archive_dir}"
  apt-get install --download-only -y --reinstall \
    -o Dir::Cache::archives="${archive_dir}" \
    "$@"
}

add_docker_repo() {
  local arch codename

  arch="$(dpkg --print-architecture)"
  codename="${VERSION_CODENAME:-bookworm}"

  install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
  fi

  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF
}

save_qbittorrent_image() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "Docker is not installed on this bundle-prep machine. Skipping image save for ${QBITTORRENT_IMAGE}."
    return 0
  fi

  log "Pulling ${QBITTORRENT_IMAGE}"
  docker pull "$QBITTORRENT_IMAGE"
  log "Saving ${QBITTORRENT_IMAGE} to ${IMAGE_BUNDLE_DIR}/qbittorrent-image.tar"
  docker save -o "${IMAGE_BUNDLE_DIR}/qbittorrent-image.tar" "$QBITTORRENT_IMAGE"
}

write_manifest() {
  {
    printf 'Prepared: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Repo: fitlet-service-box\n'
    printf 'Image: %s\n' "${QBITTORRENT_IMAGE}"
    printf 'Install modes supported: auto, bundle-only, online-only\n'
    printf '\nHelper packages:\n'
    printf '  - %s\n' "${HELPER_PACKAGES[@]}"
    printf '\nDocker packages:\n'
    printf '  - %s\n' "${DOCKER_PACKAGES[@]}"
  } > "$MANIFEST_FILE"
}

main() {
  require_root
  require_cmd apt-get
  require_cmd curl
  check_os
  load_env_like
  prepare_dirs

  log "Refreshing apt metadata"
  apt-get update

  download_package_set "helper packages" "$HELPER_BUNDLE_DIR" "${HELPER_PACKAGES[@]}"

  add_docker_repo
  apt-get update
  download_package_set "Docker packages" "$DOCKER_BUNDLE_DIR" "${DOCKER_PACKAGES[@]}"

  save_qbittorrent_image
  write_manifest

  cat <<EOF

USB bundle prepared in:
  ${BUNDLE_DIR}

For a no-download install on the Fitlet:
1. Copy this repo plus the bundle/ directory to the USB drive.
2. Set INSTALL_MODE=bundle-only in .env on the Fitlet.
3. Run sudo ./install.sh from the USB copy.

If you leave INSTALL_MODE=auto, install.sh will prefer the USB bundle and only use the network when something is missing.
EOF
}

main "$@"
