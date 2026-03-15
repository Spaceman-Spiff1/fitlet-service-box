#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_DIR/dist"

VERSION="dev"
INCLUDE_BUNDLE=0

log() {
  printf '[build-installer] %s\n' "$*"
}

die() {
  printf '[build-installer][error] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: ./scripts/build-installer.sh [--version VERSION] [--include-bundle]

Builds installer artifacts in dist/:
- fitlet-service-box-installer-<version>.run
- fitlet-service-box-installer-<version>.tar.gz
- fitlet-service-box-installer-<version>.sha256

Options:
  --version VERSION   Version string used in output filenames (default: dev)
  --include-bundle    Include local bundle/ payload contents in the installer
  --help              Show this help text
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --version)
      shift
      (( $# > 0 )) || die "--version requires a value"
      VERSION="$1"
      ;;
    --include-bundle)
      INCLUDE_BUNDLE=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unsupported argument: $1"
      ;;
  esac
  shift
done

[[ "$VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "VERSION may contain only letters, digits, dot, underscore, and hyphen"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

require_cmd tar
require_cmd gzip
require_cmd sha256sum
require_cmd mktemp

stage_root="$(mktemp -d "${TMPDIR:-/tmp}/fitlet-service-box-build.XXXXXX")"
package_root="${stage_root}/fitlet-service-box"
payload_archive="${stage_root}/payload.tar.gz"

cleanup() {
  rm -rf "$stage_root"
}

trap cleanup EXIT

mkdir -p "$DIST_DIR" "$package_root"

log "Copying repository into packaging workspace"
tar \
  --exclude='.git' \
  --exclude='.env' \
  --exclude='dist' \
  --exclude='docs/LOCAL-VALUES.md' \
  -cf - \
  -C "$REPO_DIR" \
  . | tar -xf - -C "$package_root"

if (( INCLUDE_BUNDLE == 0 )) && [[ -d "$package_root/bundle" ]]; then
  find "$package_root/bundle" -mindepth 1 ! -name 'README.md' -exec rm -rf -- {} +
fi

installer_base="fitlet-service-box-installer-${VERSION}"
installer_path="${DIST_DIR}/${installer_base}.run"
tarball_path="${DIST_DIR}/${installer_base}.tar.gz"
checksum_path="${DIST_DIR}/${installer_base}.sha256"

log "Creating payload archive"
tar -C "$stage_root" -czf "$payload_archive" fitlet-service-box
cp "$payload_archive" "$tarball_path"

log "Building self-extracting installer"
cat >"$installer_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[installer] %s\n' "$*"
}

die() {
  printf '[installer][error] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: ./fitlet-service-box-installer.run [--extract-only] [--target-dir PATH]

Options:
  --extract-only      Extract the packaged repo and print the extracted repo path
  --target-dir PATH   Extract into PATH instead of a temporary directory
  --help              Show this help text

Notes:
- If a sidecar .env file is present next to the installer, it is copied into the
  extracted repo before install.sh runs.
- If a sidecar bundle/ directory is present next to the installer, it is copied
  into the extracted repo before install.sh runs.
USAGE
}

extract_only=0
target_dir=""

while (( $# > 0 )); do
  case "$1" in
    --extract-only)
      extract_only=1
      ;;
    --target-dir)
      shift
      (( $# > 0 )) || die "--target-dir requires a value"
      target_dir="$1"
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "Unsupported argument: $1"
      ;;
  esac
  shift
done

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
self_path="${self_dir}/$(basename "${BASH_SOURCE[0]}")"
archive_line="$(awk '/^__ARCHIVE_BELOW__$/ {print NR + 1; exit}' "$self_path")"
[[ -n "$archive_line" ]] || die "Installer payload marker not found"

if [[ -n "$target_dir" ]]; then
  extract_root="$target_dir"
  mkdir -p "$extract_root"
else
  extract_root="$(mktemp -d "${TMPDIR:-/tmp}/fitlet-service-box-installer.XXXXXX")"
fi

cleanup() {
  if (( extract_only == 0 )) && [[ -z "$target_dir" && -d "${extract_root:-}" ]]; then
    rm -rf "$extract_root"
  fi
}

trap cleanup EXIT

tail -n +"$archive_line" "$self_path" | tar -xzf - -C "$extract_root"

repo_dir="${extract_root}/fitlet-service-box"
[[ -d "$repo_dir" ]] || die "Extracted payload is missing fitlet-service-box/"

if [[ -f "${self_dir}/.env" && ! -f "${repo_dir}/.env" ]]; then
  cp "${self_dir}/.env" "${repo_dir}/.env"
  log "Copied sidecar .env into extracted workspace"
fi

if [[ -d "${self_dir}/bundle" ]]; then
  rm -rf "${repo_dir}/bundle"
  mkdir -p "${repo_dir}"
  tar -C "${self_dir}" -cf - bundle | tar -xf - -C "${repo_dir}"
  log "Copied sidecar bundle/ into extracted workspace"
fi

if (( extract_only == 1 )); then
  printf '%s\n' "$repo_dir"
  exit 0
fi

log "Running install.sh from extracted workspace"
if (( EUID != 0 )); then
  exec sudo bash "${repo_dir}/install.sh"
else
  exec bash "${repo_dir}/install.sh"
fi

__ARCHIVE_BELOW__
EOF
cat "$payload_archive" >>"$installer_path"
chmod 0755 "$installer_path"

log "Writing checksums"
(
  cd "$DIST_DIR"
  sha256sum "$(basename "$installer_path")" "$(basename "$tarball_path")" > "$(basename "$checksum_path")"
)

cat <<EOF

Installer artifacts created:
  ${installer_path}
  ${tarball_path}
  ${checksum_path}

Tips:
- Run ${installer_path##*/} directly on the Fitlet with sudo for a one-file install.
- Place a sidecar .env next to the installer if you want host-specific settings applied before install.sh starts.
- Place a sidecar bundle/ directory next to the installer for USB/offline installs.
- Use --include-bundle when building locally if you want bundle/ contents embedded in the installer itself.
EOF
