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

EXPECTED_DNS="${EXPECTED_DNS:-REPLACE_ME_DNS_IP}"
EXPECTED_GATEWAY="${EXPECTED_GATEWAY:-REPLACE_ME_GATEWAY_IP}"
LAN_TEST_TARGET="${LAN_TEST_TARGET:-REPLACE_ME_LAN_TEST_TARGET}"
FITLET_IP="${FITLET_IP:-REPLACE_ME_FITLET_IP}"
WEBUI_PORT="${WEBUI_PORT:-8080}"
TORRENTING_PORT="${TORRENTING_PORT:-49152}"
PUBLIC_IP_CHECK_URL="${PUBLIC_IP_CHECK_URL:-https://ifconfig.me}"

is_placeholder() {
  [[ "$1" == REPLACE_ME_* ]]
}

pass() {
  printf '[pass] %s\n' "$1"
}

warn() {
  printf '[warn] %s\n' "$1"
}

info() {
  printf '[info] %s\n' "$1"
}

collect_listener_addresses() {
  local port="$1"
  local protocol_filter="${2:-any}"

  ss -H -lntup 2>/dev/null | awk -v port="$port" -v protocol_filter="$protocol_filter" '
    $5 ~ ":" port "$" && (protocol_filter == "any" || $1 == protocol_filter) {print $1 "|" $5}
  '
}

report_listener_check() {
  local label="$1"
  local port="$2"
  local protocol_filter="${3:-any}"
  local listeners=()
  local listener_line protocol address
  local saw_expected=0
  local saw_wildcard=0

  mapfile -t listeners < <(collect_listener_addresses "$port" "$protocol_filter")

  printf '\n-- %s --\n' "$label"
  if (( ${#listeners[@]} == 0 )); then
    if [[ "$protocol_filter" == "any" ]]; then
      warn "Nothing appears to be listening on port ${port}"
    else
      warn "Nothing appears to be listening on ${protocol_filter} port ${port}"
    fi
    return 0
  fi

  printf 'Observed listeners:\n'
  for listener_line in "${listeners[@]}"; do
    IFS='|' read -r protocol address <<<"$listener_line"
    printf '  - %s %s\n' "$protocol" "$address"

    case "$address" in
      "${FITLET_IP}:${port}"|"[::ffff:${FITLET_IP}]:${port}")
        saw_expected=1
        ;;
      "*:${port}"|"0.0.0.0:${port}"|"[::]:${port}"|":::${port}")
        saw_wildcard=1
        ;;
    esac
  done

  if is_placeholder "$FITLET_IP"; then
    warn "FITLET_IP is still a placeholder in .env. Update it before using listener binding checks as an acceptance test."
    return 0
  fi

  if (( saw_expected == 1 && saw_wildcard == 0 )); then
    pass "${label} is bound only to ${FITLET_IP}:${port}"
  elif (( saw_expected == 1 )); then
    warn "${label} includes the expected bind but also appears on a wildcard listener. Review qBittorrent bind settings."
  else
    warn "${label} is not bound to ${FITLET_IP}:${port}. Review qBittorrent bind settings before trusting the host."
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
if is_placeholder "$EXPECTED_DNS"; then
  warn "EXPECTED_DNS is still a placeholder in .env. Update it before trusting these checks."
elif [[ -r /etc/resolv.conf ]]; then
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

printf '\n-- Default gateway inspection --\n'
if is_placeholder "$EXPECTED_GATEWAY"; then
  warn "EXPECTED_GATEWAY is still a placeholder in .env. Update it before trusting these checks."
else
  default_gateway="$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')"
  printf 'Default gateway: %s\n' "${default_gateway:-none detected}"
  if [[ "$default_gateway" == "$EXPECTED_GATEWAY" ]]; then
    pass "Default gateway matches ${EXPECTED_GATEWAY}"
  else
    warn "Default gateway does not match ${EXPECTED_GATEWAY}"
  fi
fi

printf '\n-- DNS query through expected resolver --\n'
if is_placeholder "$EXPECTED_DNS"; then
  warn "Skipping DNS check because EXPECTED_DNS is still a placeholder."
elif command -v dig >/dev/null 2>&1; then
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
if is_placeholder "$LAN_TEST_TARGET"; then
  warn "Skipping LAN reachability test because LAN_TEST_TARGET is still a placeholder."
elif ping -c 1 -W 2 "$LAN_TEST_TARGET" >/dev/null 2>&1; then
  warn "Ping to ${LAN_TEST_TARGET} succeeded. Review OPNsense LAN isolation rules before trusting the host."
else
  pass "Ping to ${LAN_TEST_TARGET} failed or timed out, which is consistent with LAN isolation"
fi

report_listener_check "qBittorrent Web UI listener check" "$WEBUI_PORT" tcp
report_listener_check "qBittorrent torrent TCP listener check" "$TORRENTING_PORT" tcp
report_listener_check "qBittorrent torrent UDP listener check" "$TORRENTING_PORT" udp

printf '\n-- Host-side validation boundary --\n'
cat <<EOF
Host-side checks can confirm:
- The configured resolver on the host
- The default gateway the host is using
- Whether direct DNS to 8.8.8.8 appears blocked
- Whether the current public IP matches the expected VPN exit
- Whether qBittorrent is listening on the expected IP and ports without wildcard binds

Host-side checks cannot prove:
- That peer traffic never leaks out WAN
- That NAT rules are correct on OPNsense
- That state killing behaves correctly on VPN failure
- That packet flow remains pinned to Proton under all failure modes

You must validate those on OPNsense with packet captures and controlled VPN failure tests.
EOF
