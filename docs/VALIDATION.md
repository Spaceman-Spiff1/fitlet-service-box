# Validation

Validation is split between what the Fitlet can observe and what only OPNsense can prove. Packet capture and failure simulation are part of the design, not optional extras.

## Fitlet Validation

Run these from the repo directory on the Fitlet.

### 1. Health Snapshot

```bash
./scripts/healthcheck.sh
```

Expected:
- Host shows `10.77.0.10` on the torrent-side interface.
- Default route points at `10.77.0.1`.
- `/etc/resolv.conf` contains `10.77.0.1`.
- qBittorrent container is running.
- Public IP is the Proton exit IP, not the ISP IP.
- Disk space is reasonable for the download target.

Interpretation of failure:
- Missing `10.77.0.10` usually means DHCP reservation or cable/interface mismatch.
- Wrong resolver suggests DHCP or host override problems.
- Wrong public IP means stop and validate routing on OPNsense before using the box.

### 2. Routing and Leak Checks

```bash
./scripts/verify-routing.sh
```

Expected:
- Public egress IP matches your expected Proton exit.
- Resolver inspection shows `10.77.0.1`.
- DNS query through `10.77.0.1` succeeds.
- Direct DNS query to `8.8.8.8` fails or times out.
- Ping to the main LAN target fails or times out.
- qBittorrent Web UI listener appears on the expected port and only on `10.77.0.10`.

Interpretation of failure:
- If direct DNS to `8.8.8.8` works, review OPNsense DNS leak controls.
- If LAN reachability works, review the TORRENT_NET to LAN block rules.
- If the public IP is your ISP IP, do not proceed with torrent activity.

### 3. qBittorrent UI Checks

Sign into the Web UI and verify:
- Admin password has been changed from the initial temporary value.
- `UPnP / NAT-PMP` is disabled.
- The listening port matches `TORRENTING_PORT`.
- The network interface or optional bind address points to the torrent-side interface or `10.77.0.10`.
- Default save path is `/downloads`.

These checks matter because a host can be on the right subnet and still have unsafe application defaults.

## OPNsense Validation

These checks must be done on OPNsense. The Fitlet cannot prove them by itself.

### 1. Packet Capture During Torrent Activity

Run packet captures on:
- WAN interface
- Proton WireGuard interface
- TORRENT_NET interface

Expected:
- WAN capture shows VPN transport only, not raw peer traffic from `10.77.0.10`.
- WireGuard capture shows the expected encapsulated traffic.
- TORRENT_NET capture shows DNS and NTP to `10.77.0.1` plus ordinary traffic from the Fitlet toward the firewall.

Failure meaning:
- Any direct peer traffic on WAN is a design failure.
- Unexpected DNS egress anywhere other than the intended firewall path indicates a leak path.

### 2. Controlled VPN Failure Test

Disable the Proton WireGuard gateway or otherwise simulate gateway loss while observing:
- OPNsense firewall log
- OPNsense state table
- Fitlet public IP checks
- qBittorrent behavior

Expected:
- The Fitlet loses internet reachability.
- No fallback path to plain WAN appears.
- States tied to the failed VPN path are killed as designed.
- The Fitlet cannot continue resolving or transferring externally except for whatever local infrastructure rules you intentionally allow.

Failure meaning:
- Continued internet access during VPN loss means the kill-switch design is incomplete.
- Surviving states that keep traffic flowing need immediate review.

### 3. NAT and Rule Review

Confirm:
- No WAN NAT rule applies to `10.77.0.0/24`.
- Policy routing really matches `10.77.0.10` or the full torrent subnet, depending on your design.
- DNS and NTP are pinned to the firewall.
- IPv6 is disabled or equally constrained.
- Main LAN access is blocked.

## Quick Acceptance Checklist

You should be able to say yes to all of these before trusting the box:
- Public IP on the Fitlet is the Proton exit IP, not the ISP IP.
- DNS resolver on the Fitlet is `10.77.0.1`.
- Direct DNS to `8.8.8.8` fails.
- LAN access attempts fail.
- qBittorrent Web UI is reachable only on the expected IP and port.
- WAN packet capture shows only VPN transport, not peer traffic.
- Disabling the VPN causes loss of internet for the host.
- No unexpected NAT rule applies to `10.77.0.0/24`.

If any answer is no, the correct next step is investigation, not rationalization.