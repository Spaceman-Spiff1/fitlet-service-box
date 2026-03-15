# fitlet-torrent-box

Single-purpose deployment repo for a Fitlet2 torrent acquisition host on Debian 12. This project sets up qBittorrent in Docker on an isolated subnet and assumes OPNsense is already enforcing VPN-only egress, DNS/NTP pinning, LAN isolation, and no-WAN-fallback behavior.

This host is not the media server. It is an acquisition node only.

## Purpose

This repo gives you a reproducible, low-maintenance blueprint for deploying qBittorrent on a Fitlet2 while keeping the firewall as the primary network security boundary.

Intended protections:
- Reduce ISP visibility into destination traffic when OPNsense is correctly policy-routed through Proton WireGuard.
- Reduce accidental WAN leakage by keeping VPN enforcement on OPNsense.
- Reduce DNS leakage when the firewall pins DNS to its own resolver.
- Contain the torrent host away from the main LAN.
- Keep the host easy to rebuild.

Not guaranteed:
- Anonymity from trackers or swarm observers.
- Protection from VPN provider logging.
- Immunity from host compromise.
- Perfect application confinement.
- Safety if OPNsense is misconfigured.

Git is a deployment blueprint, not a complete resurrection spell. Rebuild-first incident response is the model.

## Architecture Summary

- Hardware: Fitlet2, Intel Atom x7-E3950, 8 GB RAM, 64 GB SSD.
- OS: Debian 12 minimal.
- Workload: qBittorrent in Docker Compose.
- Host IP: `10.77.0.10` via DHCP reservation.
- Firewall, DNS, and NTP: `10.77.0.1`.
- Torrent subnet: `10.77.0.0/24` on a dedicated OPNsense interface.
- Egress design: OPNsense terminates Proton WireGuard and policy-routes this host through the VPN.

## OPNsense Prerequisites

This repo assumes the firewall side already exists and is working. It does not automate OPNsense.

Required prerequisites:
- Dedicated `TORRENT_NET` interface on `10.77.0.0/24`.
- DHCP reservation for the Fitlet at `10.77.0.10`.
- DNS pinned to OPNsense / AdGuard at `10.77.0.1`.
- NTP pinned to OPNsense at `10.77.0.1`.
- No access from `TORRENT_NET` to the main LAN `192.168.1.0/24`.
- No access from `TORRENT_NET` to firewall services except required local DNS and NTP.
- Policy-based routing of this host or subnet through the Proton WireGuard gateway.
- Gateway switching disabled.
- State killing enabled on gateway failure.
- No WAN NAT for `10.77.0.0/24`.
- Kill-switch style blocking for non-VPN egress.
- IPv6 disabled or equivalently controlled.

Packet-level validation on OPNsense is part of the design, not an optional extra.

## Repo Layout

```text
fitlet-torrent-box/
|-- README.md
|-- .env.example
|-- .gitignore
|-- docker-compose.yml
|-- install.sh
|-- scripts/
|   |-- healthcheck.sh
|   |-- verify-routing.sh
|   |-- backup-config.sh
|   `-- update-images.sh
|-- docs/
|   |-- OPERATIONS.md
|   `-- VALIDATION.md
`-- systemd/
    |-- fitlet-healthcheck.service
    |-- fitlet-healthcheck.timer
    |-- fitlet-update-notify.service
    `-- fitlet-update-notify.timer
```

## Install

1. Copy this repo to the Fitlet, for example to `/opt/fitlet-torrent-box`.
2. Review `.env.example` and create `.env` with your actual values.
3. Make sure Docker Engine and the Docker Compose plugin are installed from Docker's official Debian repository.
4. Enable `unattended-upgrades` on the host so Debian security updates keep flowing.
5. Run:

```bash
sudo chmod +x install.sh scripts/*.sh
sudo ./install.sh
```

6. Open the qBittorrent Web UI at `http://10.77.0.10:8080` from a management network that can reach the torrent subnet.

## First Login

1. Sign in with the temporary qBittorrent credentials shown in the container logs.
2. Immediately change the admin password.
3. In qBittorrent settings, confirm or set the following:
   - Disable `UPnP / NAT-PMP`.
   - Set the listening port to the value from `TORRENTING_PORT`.
   - Bind qBittorrent to the interface or address for `10.77.0.10`.
   - Confirm the default download path matches `/downloads`.
4. Save settings and restart the container if qBittorrent requests it.

Some qBittorrent settings are safer to verify in the UI than to template blindly. This repo documents those steps instead of pretending they are fully automated.

## Access

- Web UI: `http://10.77.0.10:8080`
- Torrent port: `49152/tcp` and `49152/udp`
- Host management: SSH from LAN or existing OpenVPN access to OPNsense only

The compose file binds ports only to `FITLET_IP`, not to all interfaces.

## Security Notes

- Docker is used for packaging and service management, not as a hard security boundary.
- This design reduces ISP observability when the firewall is configured correctly, but it does not provide tracker or swarm anonymity.
- The VPN provider remains a trust dependency.
- If OPNsense is wrong, the host cannot compensate for it.
- Do not expose qBittorrent to WAN, do not add a reverse proxy, and do not enable UPnP or NAT-PMP.
- Do not install a VPN client on the Fitlet for this design.

## Rebuild Notes

If compromise is suspected:
1. Isolate or power down the host.
2. Preserve any evidence you care about.
3. Reinstall Debian.
4. Restore this repo.
5. Restore `.env` and any other required secrets.
6. Restore qBittorrent config only if you trust it.
7. Re-run `install.sh`.
8. Re-run all validation steps in [docs/VALIDATION.md](docs/VALIDATION.md).

Do not treat "remove the container and restart" as incident response.

## Operations

- Health check: `./scripts/healthcheck.sh`
- Routing validation: `./scripts/verify-routing.sh`
- Config backup: `./scripts/backup-config.sh`
- Image refresh: `./scripts/update-images.sh`

Detailed operational guidance lives in [docs/OPERATIONS.md](docs/OPERATIONS.md) and [docs/VALIDATION.md](docs/VALIDATION.md).