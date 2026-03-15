# Operations

## Admin Workflow

Normal workflow should stay boring and predictable:
- SSH to the Fitlet from your management network.
- Run `docker compose ps` in `${PROJECT_DIR}` to confirm service state.
- Run `./scripts/healthcheck.sh` for a quick status snapshot.
- Review `docs/LOCAL-VALUES.md` after install if you want a host-local summary of the actual deployment values.
- Use the qBittorrent Web UI only from trusted management paths.
- Keep changes small, documented, and reversible.

If you installed from USB, stop using the USB copy after the initial staging step. Treat `${PROJECT_DIR}` as the canonical working copy on the Fitlet.

Do not treat this host like a general-purpose Debian box. The more extra services and packages you add, the less confidence you can keep in the original threat model.

## USB Bundle

If you rely on USB-based installs or rebuilds:
- Prepare the bundle on a connected Debian 12 machine with `sudo ./scripts/prepare-usb-bundle.sh`.
- Copy the refreshed `bundle/` directory to the USB drive along with the repo.
- Use `INSTALL_MODE=bundle-only` in `.env` when you want to forbid package or image downloads during install.
- Use `INSTALL_MODE=auto` when the USB bundle is preferred but online fallback is acceptable.

## Logs To Check

Host and container checks:
- `docker compose ps`
- `docker logs qbittorrent --tail 100`
- `journalctl -u docker --since today`
- `journalctl -u fitlet-healthcheck.service --since today`

Firewall-side checks still matter more for routing assurance:
- OPNsense packet captures on WAN and the Proton WireGuard interface
- OPNsense live firewall log during torrent activity
- OPNsense state table during controlled VPN failure tests

## Updating

1. Review the image tag in `.env` and decide whether you want to move it.
2. Run `./scripts/update-images.sh`.
3. If you use USB bundles for rebuilds, rerun `sudo ./scripts/prepare-usb-bundle.sh` on your connected prep machine so the bundle matches the new image and package set.
4. Confirm qBittorrent comes back cleanly.
5. Re-run `./scripts/healthcheck.sh` and `./scripts/verify-routing.sh`.
6. Re-run OPNsense packet-capture validation if the stack behavior changed.

Avoid watchtower-style blind auto-updates for this box. A low-maintenance host is not the same thing as an unattended trust leap.

If you want the optional timers:
- Copy the unit files from `systemd/` into `/etc/systemd/system/`.
- Run `sudo systemctl daemon-reload`.
- Enable them with `sudo systemctl enable --now fitlet-healthcheck.timer fitlet-update-notify.timer`.

## Backups

Run:

```bash
sudo ./scripts/backup-config.sh
```

This creates a timestamped tarball of the repo and qBittorrent config directory while excluding `.env` by design.

Back up separately and securely:
- `.env`
- Any credentials you choose to keep
- Any operational notes you need for rebuild

## Rebuild-First Response

If compromise is suspected, the model is rebuild first.

Recommended sequence:
1. Isolate or power off the host.
2. Preserve any evidence or disk image you actually care about.
3. Reinstall Debian 12 minimal.
4. Reinstall Docker from the official Docker repository.
5. Restore this repo.
6. Restore `.env` and only the config you trust.
7. Run `install.sh`.
8. Re-run all validation in `docs/VALIDATION.md`.
9. Return the host to service only after OPNsense checks pass again.

Do not describe compromise cleanup as removing a container and starting over. That is false confidence.

## What Not To Do

- Do not expose qBittorrent to WAN.
- Do not add a reverse proxy or tunnel in front of it.
- Do not install a host-side VPN client for this design.
- Do not enable UPnP or NAT-PMP.
- Do not assume Docker isolates a compromised application from the host.
- Do not add LAN firewall exceptions because something is temporarily inconvenient.
- Do not ignore validation after making network changes.

## Tradeoffs

This design intentionally trades convenience for containment and rebuildability.

Tradeoffs to keep in mind:
- qBittorrent remains a network-facing application on an untrusted workload host.
- The VPN provider remains a trust dependency.
- Host-side scripts can show symptoms, but only firewall captures can prove non-leakage.
- A 64 GB SSD is fine for the host and staging but poor for long-term media storage.
- Docker simplifies deployment but does not meaningfully replace a hardened network boundary.
