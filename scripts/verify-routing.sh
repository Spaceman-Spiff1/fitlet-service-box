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

EXPECTED_DNS="${EXPECTED_DNS:-10.77.0.1}"
LAN_TEST_TARGET="${LAN_TEST_TARGET:-192.168.1.254}"
PUBLIC_IP_CHECK_URL="${PUBLIC_IP_CHECK_URL:-https://ifconfig.me}"

pass() {
  printf '[pass] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1"
}

info() {
  printf '[info] %s\n' "$1"
}

run_maybe() {
  local label="$1"
  shift
  printf '\n%s\n' "-- ${label} --"
  if "$@"; then
    pass "${label} succeeded"
  else
    warn "${label} failed"
  fi
}

info "This script validates what the host can observe. It cannot prove firewall behavior by itself."
info "Use OPNsense packet captures and failure simulation to confirm there is no WAN leak path."

printf '\n-- Public egress IP --\n'
if curl --silent --show-error --max-time 10 "$PUBLIC_IP_CHECK_URL"; then
  printf '\n'
  pass "Public IP check completed. Compare it to your expected Proton exit IP."
else
  warn "Unable to fetch public IP. If internet is intentionally blocked, confirm the reason on OPNsense."
fi

printf '\n-- Resolver inspection --\n'
if [[ -r /etc/resolv.conf ]]; then
  resolvers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | xargs echo || true)"
  printf 'Configured resolvers: %s\n' "${resolvers:-none detected}"
  if [[ "$resolvers" == *"${EXPECTED_DNS}"* ]]; then
    pass "Expected resolver ${EXPECTED_DNS} appears in /etc/resolv.conf"
  else
    warn "Expected resolver ${EXPECTED_DNS} not present in /etc/resolv.conf"
  fi
else
  warn "Cannot read /etc/resolv.conf"
fi

printf '\n-- DNS query through expected resolver --\n'
if command -v dig >/dev/null 2>&1; then
  if dig +time=3 +tries=1 @"${EXPECTED_DNS}" example.com A >/dev/null; then
    pass "DNS query through ${EXPECTED_DNS} succeeded"
  else
    warn "DNS query through ${EXPECTED_DNS} failed"
  fi
else
  warn "dig is not installed; run install.sh or apt-get install dnsutils"
fi

printf '\n-- Direct DNS query to 8.8.8.8 --\n'
if command -v dig >/dev/null 2>&1; then
  if dig +time=3 +tries=1 @8.8.8.8 example.com A >/dev/null; then
    warn "Direct DNS query to 8.8.8.8 succeeded. If your policy is strict, review OPNsense rules for DNS leak prevention."
  else
    pass "Direct DNS query to 8.8.8.8 failed or timed out, which is the expected result when the firewall blocks it"
  fi
else
  warn "dig is not installed; skipping direct DNS test"
fi

printf '\n-- LAN reachability smoke test --\n'
if ping -c 1 -W 2 "$LAN_TEST_TARGET" >/dev/null 2>&1; then
  warn "Ping to ${LAN_TEST_TARGET} succeeded. Review OPNsense LAN isolation rules before trusting the host."
else
  pass "Ping to ${LAN_TEST_TARGET} failed or timed out, which is consistent with LAN isolation"
fi

printf '\n-- qBittorrent listener check --\n'
if ss -lntup 2>/dev/null | grep -F ":${WEBUI_PORT:-8080}" >/dev/null 2>&1; then
  pass "A process is listening on Web UI port ${WEBUI_PORT:-8080}. Confirm it is bound only to ${FITLET_IP:-10.77.0.10}."
  ss -lntup 2>/dev/null | grep -F ":${WEBUI_PORT:-8080}" || true
else
  warn "Nothing appears to be listening on Web UI port ${WEBUI_PORT:-8080}"
fi

printf '\n-- Host-side validation boundary --\n'
cat <<EOF
Host-side checks can confirm:
- The configured resolver on the host
- Whether direct DNS to 8.8.8.8 appears blocked
- Whether the current public IP matches the expected VPN exit
- Whether qBittorrent is listening on the expected IP and ports

Host-side checks cannot prove:
- That peer traffic never leaks out WAN
- That NAT rules are correct on OPNsense
- That state killing behaves correctly on VPN failure
- That packet flow remains pinned to Proton under all failure modes

You must validate those on OPNsense with packet captures and controlled VPN failure tests.
EOF