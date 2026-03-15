# fitlet-service-box

Single-purpose deployment repo for a Fitlet2 service host on Debian 12. This project sets up qBittorrent in Docker on an isolated subnet and assumes OPNsense is already enforcing VPN-only egress, DNS/NTP pinning, LAN isolation, and no-WAN-fallback behavior.

This host is not the media server. It is an acquisition node only.

## Purpose

This repo gives you a reproducible, low-maintenance blueprint for deploying qBittorrent on a Fitlet2 while keeping the firewall as the primary network security boundary.

Intended protections:
- Reduce ISP visibility into destination traffic when OPNsense is correctly policy-routed through Proton WireGuard.
- Reduce accidental WAN leakage by keeping VPN enforcement on OPNsense.
- Reduce DNS leakage when the firewall pins DNS to its own resolver.
- Contain the workload host away from the main LAN.
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
- Host IP: `${FITLET_IP}` via DHCP reservation.
- Firewall gateway: `${EXPECTED_GATEWAY}`.
- DNS: `${EXPECTED_DNS}`.
- NTP: `${EXPECTED_NTP}`.
- Isolated service subnet: `${EXPECTED_SUBNET}` on a dedicated OPNsense interface.
- Egress design: OPNsense terminates Proton WireGuard and policy-routes this host through the VPN.

## OPNsense Prerequisites

This repo assumes the firewall side already exists and is working. It does not automate OPNsense.

Required prerequisites:
- Dedicated `TORRENT_NET` interface on `${EXPECTED_SUBNET}`.
- DHCP reservation for the Fitlet at `${FITLET_IP}`.
- DNS pinned to OPNsense / AdGuard at `${EXPECTED_DNS}`.
- NTP pinned to OPNsense at `${EXPECTED_NTP}`.
- No access from `TORRENT_NET` to your primary LAN.
- No access from `TORRENT_NET` to firewall services except required local DNS and NTP.
- Policy-based routing of this host or subnet through the Proton WireGuard gateway.
- Gateway switching disabled.
- State killing enabled on gateway failure.
- No WAN NAT for `${EXPECTED_SUBNET}`.
- Kill-switch style blocking for non-VPN egress.
- IPv6 disabled or equivalently controlled.

Packet-level validation on OPNsense is part of the design, not an optional extra.

## Repo Layout

```text
fitlet-service-box/
|-- .github/
|   `-- workflows/
|       `-- ci.yml
|-- README.md
|-- .env.example
|-- .gitignore
|-- .pylintrc
|-- .yamllint.yml
|-- docker-compose.yml
|-- install.sh
|-- scripts/
|   |-- healthcheck.sh
|   |-- ci-checks.sh
|   |-- docker-smoke-test.sh
|   |-- prepare-usb-bundle.sh
|   |-- verify-routing.sh
|   |-- backup-config.sh
|   `-- update-images.sh
|-- bundle/
|   `-- README.md
|-- docs/
|   |-- LOCAL-VALUES.md (generated on install, not tracked)
|   |-- OPERATIONS.md
|   `-- VALIDATION.md
|-- templates/
|   |-- LOCAL-VALUES.md.tmpl
|   `-- systemd/
`-- systemd/
    |-- fitlet-healthcheck.service
    |-- fitlet-healthcheck.timer
    |-- fitlet-update-notify.service
    `-- fitlet-update-notify.timer
```

## GitHub Actions

This repo now includes a small GitHub Actions framework in [.github/workflows/ci.yml](.github/workflows/ci.yml).

It runs:
- `shellcheck` for the shell scripts
- a Docker smoke test that pulls the qBittorrent image and starts the real compose stack on GitHub runners
- `yamllint` for compose, workflow, and config YAML
- `pylint` for Python files when the repo has any
- `actionlint` for the GitHub workflow itself
- `./scripts/ci-checks.sh` for repo-specific smoke checks

Those checks are useful for catching script regressions, stale hardcoded values, and workflow mistakes before merge.
They do not prove the full Fitlet install path, your DHCP/firewall assumptions, or the OPNsense routing design by themselves.
Keep host-side validation and firewall packet captures in the loop.

## Install

If you are installing from a USB drive, treat the USB as the source media only. The installer stages the repo and the USB bundle into `${PROJECT_DIR}` and continues from there, so the local working copy becomes self-contained.

### USB Bundle Prep

On an internet-connected Debian 12 machine, run:

```bash
sudo ./scripts/prepare-usb-bundle.sh
```

That populates `bundle/` with:
- helper `.deb` packages used by `install.sh`
- Docker Engine and Compose plugin `.deb` packages
- a saved qBittorrent image tarball when Docker is available on the prep machine

The prep script resolves package dependency closure so `INSTALL_MODE=bundle-only` is aimed at a fresh Debian 12 target, not just the prep machine's already-installed state.

Copy the whole repo, including `bundle/`, to the USB drive.

### Fitlet Install

1. Mount the USB drive on the Fitlet and `cd` into the repo on the USB.
2. Review `.env.example`, copy it to `.env`, and replace every `REPLACE_ME_*` value with your local network details.
3. Pick an install mode in `.env`:
   - `INSTALL_MODE=bundle-only` for a no-download USB install
   - `INSTALL_MODE=auto` to prefer the USB bundle and only download missing pieces
   - `INSTALL_MODE=online-only` to ignore the USB bundle and install from the network
4. Run:

```bash
sudo chmod +x install.sh scripts/*.sh
sudo ./install.sh
```

5. If the installer created `${PROJECT_DIR}/.env` for the first time, edit it there and rerun `sudo ./install.sh` from `${PROJECT_DIR}`.
6. After staging completes, the install runs from `${PROJECT_DIR}` and no longer depends on the USB staying mounted.
7. When install is run with `sudo` from a normal admin account, it adds that account to the `docker` group so routine `docker compose` commands do not require `sudo`.
8. Log out and back in, or run `newgrp docker`, before using Docker commands without `sudo`.
9. After install renders `docs/LOCAL-VALUES.md`, open the qBittorrent Web UI at `http://${FITLET_IP}:${WEBUI_PORT}` from a management network that can reach the isolated subnet.

## First Login

1. Sign in with the temporary qBittorrent credentials shown in the container logs.
2. Immediately change the admin password.
3. In qBittorrent settings, confirm or set the following:
   - Disable `UPnP / NAT-PMP`.
   - Set the listening port to the value from `TORRENTING_PORT`.
   - Bind qBittorrent to the interface or address for `${FITLET_IP}`.
   - Confirm the default download path matches `/downloads`.
4. Save settings and restart the container if qBittorrent requests it.

Some qBittorrent settings are safer to verify in the UI than to template blindly. This repo documents those steps instead of pretending they are fully automated.

## Access

- Web UI: `http://${FITLET_IP}:${WEBUI_PORT}`
- Torrent port: `${TORRENTING_PORT}/tcp` and `${TORRENTING_PORT}/udp`
- Host management: SSH from LAN or existing OpenVPN access to OPNsense only

The compose file binds ports only to `FITLET_IP`, not to all interfaces.

The public repo keeps these values as placeholders on purpose. `install.sh` renders a local [docs/LOCAL-VALUES.md](docs/LOCAL-VALUES.md) file from your `.env` so the deployed host still has concrete, host-specific notes without publishing your exact topology.
For USB-based installs, that local rendered file lives in `${PROJECT_DIR}/docs/LOCAL-VALUES.md`, not on the removable media.
When `bundle/` is present, `install.sh` can install helper packages, Docker, and the qBittorrent image without pulling them again from the internet.
`install.sh` also renders the optional systemd service files in `systemd/` so they match your configured `PROJECT_DIR`.

## Security Notes

- Docker is used for packaging and service management, not as a hard security boundary.
- The `docker` group is effectively root-equivalent. This repo uses it for day-to-day admin convenience, not because it is a security boundary.
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
