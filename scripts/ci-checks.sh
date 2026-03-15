#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

log() {
  printf '[ci] %s\n' "$1"
}

die() {
  printf '[ci][error] %s\n' "$1" >&2
  exit 1
}

require_file() {
  local file_path="$1"
  [[ -f "$file_path" ]] || die "Missing required file: ${file_path}"
}

require_pattern() {
  local pattern="$1"
  local file_path="$2"
  local description="$3"
  grep -Eq "$pattern" "$file_path" || die "Missing expected content for ${description} in ${file_path}"
}

ensure_not_present() {
  local pattern="$1"
  local path="$2"
  local description="$3"
  if grep -R -n -E --exclude-dir=.git --exclude-dir=bundle --exclude=ci-checks.sh "$pattern" "$path" >/dev/null 2>&1; then
    die "Found banned content for ${description}: ${pattern}"
  fi
}

log 'Checking required files'
required_files=(
  README.md
  .env.example
  .gitignore
  .gitattributes
  .pylintrc
  .yamllint.yml
  docker-compose.yml
  install.sh
  docs/OPERATIONS.md
  docs/VALIDATION.md
  scripts/backup-config.sh
  scripts/build-installer.sh
  scripts/ci-checks.sh
  scripts/docker-smoke-test.sh
  scripts/healthcheck.sh
  scripts/prepare-usb-bundle.sh
  scripts/update-images.sh
  scripts/verify-routing.sh
  .github/workflows/ci.yml
  .github/workflows/release.yml
)

for file_path in "${required_files[@]}"; do
  require_file "$file_path"
done

log 'Checking .env.example coverage'
required_env_vars=(
  TZ
  PUID
  PGID
  FITLET_IP
  WEBUI_PORT
  TORRENTING_PORT
  CONFIG_DIR
  DOWNLOADS_DIR
  PROJECT_DIR
  INSTALL_MODE
  QBITTORRENT_IMAGE
  PUBLIC_IP_CHECK_URL
  EXPECTED_DNS
  EXPECTED_GATEWAY
  EXPECTED_NTP
  EXPECTED_SUBNET
  LAN_TEST_TARGET
  BACKUP_DIR
)

for var_name in "${required_env_vars[@]}"; do
  require_pattern "^${var_name}=" .env.example "$var_name"
done

log 'Checking docker compose constraints'
require_pattern 'image: \$\{QBITTORRENT_IMAGE\}' docker-compose.yml 'qBittorrent image variable'
require_pattern '"\$\{FITLET_IP\}:\$\{WEBUI_PORT\}:\$\{WEBUI_PORT\}"' docker-compose.yml 'Web UI bind address'
require_pattern '"\$\{FITLET_IP\}:\$\{TORRENTING_PORT\}:\$\{TORRENTING_PORT\}"' docker-compose.yml 'torrent TCP bind address'
require_pattern '"\$\{FITLET_IP\}:\$\{TORRENTING_PORT\}:\$\{TORRENTING_PORT\}/udp"' docker-compose.yml 'torrent UDP bind address'
require_pattern 'restart: unless-stopped' docker-compose.yml 'restart policy'
require_pattern 'no-new-privileges:true' docker-compose.yml 'no-new-privileges'

log 'Checking workflow triggers'
require_pattern '^"on":' .github/workflows/ci.yml 'workflow trigger block'
require_pattern 'pull_request:' .github/workflows/ci.yml 'pull request trigger'
require_pattern 'workflow_dispatch:' .github/workflows/ci.yml 'manual trigger'

log 'Checking bash syntax'
mapfile -t shell_scripts < <(find . -type f -name '*.sh' | sort)
(( ${#shell_scripts[@]} > 0 )) || die 'No shell scripts found for bash -n checks'

for shell_script in "${shell_scripts[@]}"; do
  bash -n "$shell_script"
done

log 'Checking for stale hardcoded lab values'
ensure_not_present '10\.77\.0\.' . 'torrent subnet leak'
ensure_not_present '192\.168\.1\.' . 'main LAN leak'
ensure_not_present 'America/Chicago' . 'old timezone example'

log 'Checking validation language'
require_pattern 'packet captures' docs/VALIDATION.md 'packet-capture guidance'
require_pattern 'workflow' README.md 'GitHub workflow documentation'

log 'Repo smoke checks passed'
