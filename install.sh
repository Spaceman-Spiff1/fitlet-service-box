#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

BUNDLE_DIR="${FITLET_BUNDLE_SOURCE_DIR:-$SCRIPT_DIR/bundle}"
HELPER_BUNDLE_DIR="${BUNDLE_DIR}/packages/helpers"
DOCKER_BUNDLE_DIR="${BUNDLE_DIR}/packages/docker"
IMAGE_BUNDLE_DIR="${BUNDLE_DIR}/images"
QBITTORRENT_IMAGE_ARCHIVE="${IMAGE_BUNDLE_DIR}/qbittorrent-image.tar"
DOCKER_GROUP_CHANGED=0

HELPER_PACKAGES=(curl dnsutils tar jq ca-certificates iproute2 iputils-ping unattended-upgrades)
DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

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

strip_wrapping_quotes() {
  local value="$1"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi
  if [[ "$value" == \'*\' ]]; then
    value="${value#\'}"
    value="${value%\'}"
  fi
  printf '%s\n' "$value"
}

resolve_project_dir() {
  local env_file raw_value
  for env_file in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/.env.example"; do
    if [[ -f "$env_file" ]]; then
      raw_value="$(grep -m1 '^PROJECT_DIR=' "$env_file" | cut -d'=' -f2- || true)"
      if [[ -n "$raw_value" ]]; then
        strip_wrapping_quotes "$raw_value"
        return 0
      fi
    fi
  done
  die "Could not determine PROJECT_DIR from .env or .env.example."
}

stage_project_if_needed() {
  local target_dir="$1"

  if [[ "$SCRIPT_DIR" == "$target_dir" ]] || [[ "${FITLET_STAGE_COMPLETE:-0}" == "1" ]]; then
    return 0
  fi

  log "Staging project from $SCRIPT_DIR to $target_dir"
  mkdir -p "$target_dir"

  tar \
    --exclude='.git' \
    --exclude='.env' \
    --exclude='docs/LOCAL-VALUES.md' \
    -cf - \
    . | tar -xf - -C "$target_dir"

  if [[ -f "$SCRIPT_DIR/.env" && ! -f "$target_dir/.env" ]]; then
    cp "$SCRIPT_DIR/.env" "$target_dir/.env"
  fi

  log "Re-launching installer from $target_dir"
  exec env FITLET_STAGE_COMPLETE=1 bash "$target_dir/install.sh"
}

load_env() {
  if [[ ! -f .env ]]; then
    log "Creating .env from .env.example"
    cp .env.example .env
    warn "Review $SCRIPT_DIR/.env and replace every REPLACE_ME_* value before putting this host into service."
  fi

  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
}

is_placeholder() {
  [[ "$1" == REPLACE_ME_* ]]
}

is_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

is_valid_port() {
  is_integer "$1" && (( $1 >= 1 && $1 <= 65535 ))
}

is_ipv4() {
  local candidate="$1"
  local octets=()
  local octet

  IFS='.' read -r -a octets <<<"$candidate"
  [[ ${#octets[@]} -eq 4 ]] || return 1

  for octet in "${octets[@]}"; do
    is_integer "$octet" || return 1
    (( octet >= 0 && octet <= 255 )) || return 1
  done
}

is_ipv4_cidr() {
  local candidate="$1"
  local network prefix

  IFS='/' read -r network prefix <<<"$candidate"
  [[ -n "$network" && -n "$prefix" ]] || return 1
  is_ipv4 "$network" || return 1
  is_integer "$prefix" || return 1
  (( prefix >= 0 && prefix <= 32 ))
}

is_absolute_path() {
  [[ "$1" == /* ]]
}

normalize_install_mode() {
  INSTALL_MODE="${INSTALL_MODE:-auto}"
  case "$INSTALL_MODE" in
    auto|bundle-only|online-only)
      ;;
    *)
      die "Unsupported INSTALL_MODE: $INSTALL_MODE (expected auto, bundle-only, or online-only)"
      ;;
  esac
}

validate_env() {
  local required_vars=(
    TZ
    PUID
    PGID
    FITLET_IP
    WEBUI_PORT
    TORRENTING_PORT
    CONFIG_DIR
    DOWNLOADS_DIR
    PROJECT_DIR
    QBITTORRENT_IMAGE
    EXPECTED_DNS
    EXPECTED_GATEWAY
    EXPECTED_NTP
    EXPECTED_SUBNET
    LAN_TEST_TARGET
    BACKUP_DIR
  )
  local var_name value missing=()

  for var_name in "${required_vars[@]}"; do
    value="${!var_name:-}"
    if [[ -z "$value" ]] || is_placeholder "$value"; then
      missing+=("$var_name")
    fi
  done

  if (( ${#missing[@]} > 0 )); then
    printf '[install][error] Update .env before install. These values are unset or still placeholders: %s\n' "${missing[*]}" >&2
    exit 1
  fi

  is_integer "$PUID" || die "PUID must be a numeric UID. Current value: ${PUID}"
  is_integer "$PGID" || die "PGID must be a numeric GID. Current value: ${PGID}"
  is_valid_port "$WEBUI_PORT" || die "WEBUI_PORT must be an integer between 1 and 65535. Current value: ${WEBUI_PORT}"
  is_valid_port "$TORRENTING_PORT" || die "TORRENTING_PORT must be an integer between 1 and 65535. Current value: ${TORRENTING_PORT}"
  [[ "$WEBUI_PORT" != "$TORRENTING_PORT" ]] || die "WEBUI_PORT and TORRENTING_PORT must not be the same value."

  is_ipv4 "$FITLET_IP" || die "FITLET_IP must be a valid IPv4 address. Current value: ${FITLET_IP}"
  is_ipv4 "$EXPECTED_DNS" || die "EXPECTED_DNS must be a valid IPv4 address. Current value: ${EXPECTED_DNS}"
  is_ipv4 "$EXPECTED_GATEWAY" || die "EXPECTED_GATEWAY must be a valid IPv4 address. Current value: ${EXPECTED_GATEWAY}"
  is_ipv4 "$EXPECTED_NTP" || die "EXPECTED_NTP must be a valid IPv4 address. Current value: ${EXPECTED_NTP}"
  is_ipv4 "$LAN_TEST_TARGET" || die "LAN_TEST_TARGET must be a valid IPv4 address. Current value: ${LAN_TEST_TARGET}"
  is_ipv4_cidr "$EXPECTED_SUBNET" || die "EXPECTED_SUBNET must be an IPv4 CIDR like 10.0.0.0/24. Current value: ${EXPECTED_SUBNET}"

  is_absolute_path "$PROJECT_DIR" || die "PROJECT_DIR must be an absolute path. Current value: ${PROJECT_DIR}"
  is_absolute_path "$CONFIG_DIR" || die "CONFIG_DIR must be an absolute path. Current value: ${CONFIG_DIR}"
  is_absolute_path "$DOWNLOADS_DIR" || die "DOWNLOADS_DIR must be an absolute path. Current value: ${DOWNLOADS_DIR}"
  is_absolute_path "$BACKUP_DIR" || die "BACKUP_DIR must be an absolute path. Current value: ${BACKUP_DIR}"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

render_local_values() {
  local template="$SCRIPT_DIR/templates/LOCAL-VALUES.md.tmpl"
  local output="$SCRIPT_DIR/docs/LOCAL-VALUES.md"

  [[ -f "$template" ]] || die "Missing template: $template"

  sed \
    -e "s/__TZ__/$(escape_sed_replacement "$TZ")/g" \
    -e "s/__FITLET_IP__/$(escape_sed_replacement "$FITLET_IP")/g" \
    -e "s/__WEBUI_PORT__/$(escape_sed_replacement "$WEBUI_PORT")/g" \
    -e "s/__TORRENTING_PORT__/$(escape_sed_replacement "$TORRENTING_PORT")/g" \
    -e "s/__EXPECTED_DNS__/$(escape_sed_replacement "$EXPECTED_DNS")/g" \
    -e "s/__EXPECTED_GATEWAY__/$(escape_sed_replacement "$EXPECTED_GATEWAY")/g" \
    -e "s/__EXPECTED_NTP__/$(escape_sed_replacement "$EXPECTED_NTP")/g" \
    -e "s/__EXPECTED_SUBNET__/$(escape_sed_replacement "$EXPECTED_SUBNET")/g" \
    -e "s/__LAN_TEST_TARGET__/$(escape_sed_replacement "$LAN_TEST_TARGET")/g" \
    -e "s#__PROJECT_DIR__#$(escape_sed_replacement "$PROJECT_DIR")#g" \
    -e "s#__CONFIG_DIR__#$(escape_sed_replacement "$CONFIG_DIR")#g" \
    -e "s#__DOWNLOADS_DIR__#$(escape_sed_replacement "$DOWNLOADS_DIR")#g" \
    "$template" > "$output"

  log "Rendered local deployment notes to docs/LOCAL-VALUES.md"
}

render_systemd_units() {
  local template_dir="$SCRIPT_DIR/templates/systemd"
  local output_dir="$SCRIPT_DIR/systemd"
  local file template output

  for file in fitlet-healthcheck.service fitlet-update-notify.service; do
    template="$template_dir/${file}.tmpl"
    output="$output_dir/${file}"
    [[ -f "$template" ]] || die "Missing systemd template: $template"
    sed \
      -e "s#__PROJECT_DIR__#$(escape_sed_replacement "$PROJECT_DIR")#g" \
      "$template" > "$output"
  done

  log "Rendered optional systemd unit files with PROJECT_DIR=${PROJECT_DIR}"
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

has_bundle_packages() {
  local bundle_path="$1"
  local debs=()
  shopt -s nullglob
  debs=("$bundle_path"/*.deb)
  shopt -u nullglob
  (( ${#debs[@]} > 0 ))
}

install_local_debs() {
  local label="$1"
  local bundle_path="$2"
  local debs=()
  local apt_flags=(-y --no-install-recommends)

  shopt -s nullglob
  debs=("$bundle_path"/*.deb)
  shopt -u nullglob

  (( ${#debs[@]} > 0 )) || return 1

  if [[ "$INSTALL_MODE" == "bundle-only" ]]; then
    apt_flags+=(--no-download)
  fi

  log "Installing ${label} from local bundle in $bundle_path"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install "${apt_flags[@]}" "${debs[@]}"
}

enable_unattended_upgrades() {
  if ! systemctl enable --now unattended-upgrades >/dev/null 2>&1; then
    warn "Unable to enable unattended-upgrades automatically"
  fi
}

install_helper_packages_online() {
  log "Installing helper packages from Debian repositories: ${HELPER_PACKAGES[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${HELPER_PACKAGES[@]}"
  enable_unattended_upgrades
}

install_helper_packages() {
  case "$INSTALL_MODE" in
    online-only)
      install_helper_packages_online
      ;;
    bundle-only|auto)
      if has_bundle_packages "$HELPER_BUNDLE_DIR"; then
        if install_local_debs "helper packages" "$HELPER_BUNDLE_DIR"; then
          enable_unattended_upgrades
          return 0
        fi
        if [[ "$INSTALL_MODE" == "bundle-only" ]]; then
          die "Failed to install helper packages from $HELPER_BUNDLE_DIR"
        fi
        warn "Falling back to online helper package install because the local bundle failed"
      elif [[ "$INSTALL_MODE" == "bundle-only" ]]; then
        die "INSTALL_MODE=bundle-only but no helper package bundle was found in $HELPER_BUNDLE_DIR"
      fi
      install_helper_packages_online
      ;;
  esac
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

install_docker_online() {
  log "Installing Docker from Docker's official Debian repository"
  add_docker_repo
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y "${DOCKER_PACKAGES[@]}"
}

install_docker() {
  case "$INSTALL_MODE" in
    online-only)
      install_docker_online
      ;;
    bundle-only|auto)
      if has_bundle_packages "$DOCKER_BUNDLE_DIR"; then
        if install_local_debs "Docker packages" "$DOCKER_BUNDLE_DIR"; then
          return 0
        fi
        if [[ "$INSTALL_MODE" == "bundle-only" ]]; then
          die "Failed to install Docker packages from $DOCKER_BUNDLE_DIR"
        fi
        warn "Falling back to online Docker install because the local bundle failed"
      elif [[ "$INSTALL_MODE" == "bundle-only" ]]; then
        die "INSTALL_MODE=bundle-only but no Docker package bundle was found in $DOCKER_BUNDLE_DIR"
      fi
      install_docker_online
      ;;
  esac
}

check_docker() {
  require_cmd docker
  docker info >/dev/null 2>&1 || die "Docker is installed but not reachable. Is the daemon running?"
  docker compose version >/dev/null 2>&1 || die "Docker Compose plugin is required."
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    if ! docker info >/dev/null 2>&1; then
      systemctl enable --now docker >/dev/null 2>&1 || true
    fi
    if docker info >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
      return 0
    fi
  fi

  install_docker
  if ! systemctl enable --now docker >/dev/null 2>&1; then
    warn "Unable to enable Docker automatically"
  fi
  check_docker
}

ensure_admin_docker_access() {
  local admin_user="${SUDO_USER:-}"

  if [[ -z "$admin_user" || "$admin_user" == "root" ]]; then
    warn "Install was not started via sudo from a non-root admin account. Add your normal admin user to the docker group manually if you want day-to-day docker access without sudo."
    return 0
  fi

  if ! getent group docker >/dev/null 2>&1; then
    warn "The docker group does not exist yet, so the installer could not grant day-to-day docker access to ${admin_user}."
    return 0
  fi

  if id -nG "$admin_user" | tr ' ' '\n' | grep -Fxq docker; then
    return 0
  fi

  if usermod -aG docker "$admin_user"; then
    DOCKER_GROUP_CHANGED=1
    log "Added ${admin_user} to the docker group for day-to-day administration"
  else
    warn "Unable to add ${admin_user} to the docker group automatically"
  fi
}

load_bundled_images() {
  local archives=()
  shopt -s nullglob
  archives=("$IMAGE_BUNDLE_DIR"/*.tar)
  shopt -u nullglob

  (( ${#archives[@]} > 0 )) || return 1

  log "Loading bundled container images from $IMAGE_BUNDLE_DIR"
  for archive in "${archives[@]}"; do
    docker load -i "$archive"
  done
}

ensure_qbittorrent_image() {
  if docker image inspect "$QBITTORRENT_IMAGE" >/dev/null 2>&1; then
    return 0
  fi

  if load_bundled_images && docker image inspect "$QBITTORRENT_IMAGE" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$INSTALL_MODE" == "bundle-only" ]]; then
    die "INSTALL_MODE=bundle-only but image ${QBITTORRENT_IMAGE} is not available locally. Add ${QBITTORRENT_IMAGE_ARCHIVE} to the USB bundle or switch INSTALL_MODE."
  fi

  log "Pulling image ${QBITTORRENT_IMAGE} from the registry"
  docker compose pull qbittorrent
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
  ensure_qbittorrent_image
  log "Starting stack"
  docker compose up -d
}

print_next_steps() {
  local docker_group_note=""

  if (( DOCKER_GROUP_CHANGED == 1 )); then
    docker_group_note=$'\n10. Log out and back in (or run newgrp docker) before using docker commands without sudo\n11. Remember that docker group access is effectively root-equivalent on this host'
  fi

  cat <<EOF

Installation complete.

Next steps:
1. Work from ${PROJECT_DIR} for day-to-day administration; the USB copy is no longer required
2. Review docker status with: docker compose ps
3. Review docs/LOCAL-VALUES.md for the rendered local deployment summary
4. Read qBittorrent startup logs to get the temporary admin password:
   docker logs qbittorrent --tail 100
5. Open the Web UI on http://${FITLET_IP}:${WEBUI_PORT}
6. Change the admin password immediately
7. In qBittorrent, disable UPnP/NAT-PMP and confirm the bind address, port, and download path
8. Run ./scripts/healthcheck.sh and ./scripts/verify-routing.sh
9. Follow packet-capture validation in docs/VALIDATION.md before trusting the box
${docker_group_note}
EOF
}

main() {
  local target_project_dir
  require_root
  check_os
  target_project_dir="$(resolve_project_dir)"
  stage_project_if_needed "$target_project_dir"
  require_cmd apt-get
  load_env
  normalize_install_mode
  validate_env
  install_helper_packages
  ensure_docker
  ensure_admin_docker_access
  create_dirs
  network_sanity
  render_local_values
  render_systemd_units
  deploy_stack
  print_next_steps
}

main "$@"
