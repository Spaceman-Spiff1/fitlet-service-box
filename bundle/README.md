# USB Bundle

This directory is for USB-staged install assets that are too large or too environment-specific to keep in git.

Expected layout after running `scripts/prepare-usb-bundle.sh`:

```text
bundle/
|-- README.md
|-- manifest.txt
|-- packages/
|   |-- docker/
|   `-- helpers/
`-- images/
    `-- qbittorrent-image.tar
```

What goes here:
- `packages/helpers/`: Debian `.deb` files for helper tools used by `install.sh`
- `packages/docker/`: Debian `.deb` files for Docker Engine and the Compose plugin
- `images/`: container image tarballs that `install.sh` can load without pulling from the internet
- `manifest.txt`: a prep-time summary written by `scripts/prepare-usb-bundle.sh`

These bundle contents are ignored by git on purpose. They belong on the USB drive, not in the public repo history.

During install, the staged copy under `${PROJECT_DIR}` keeps the bundle locally so the USB drive is no longer required after the installer re-launches from the staged repo.
If you are using a GitHub release installer, place this `bundle/` directory next to the `.run` file on the USB drive so the installer can copy it into its extracted workspace before `install.sh` starts.
