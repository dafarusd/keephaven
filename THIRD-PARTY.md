# Third-party software in Keephaven

This repo's own code - the NixOS modules and scripts that turn a Raspberry Pi 5 into a Keephaven box, and the Windows program and writer that run the drive edition on a PC - is AGPL-3.0 (see `LICENSE`).

The images it builds also contain other people's software. Each keeps its own license, and nothing in Keephaven's license changes that. If you ship boxes or drives built from this, their terms apply to you as well as ours.

## The apps

Pinned by digest in `modules/images.nix` and baked into the image as container images. Source is at each project's repo.

| App | Role | License | Source |
|---|---|---|---|
| Immich (server + machine learning) | Photos | AGPL-3.0 | https://github.com/immich-app/immich |
| Immich Postgres with VectorChord | Photos database | Postgres: PostgreSQL License. VectorChord: AGPL-3.0 or Elastic License 2.0. Immich's image build files: AGPL-3.0 | https://github.com/immich-app/base-images, https://github.com/tensorchord/VectorChord |
| Valkey | Photos cache | BSD-3-Clause | https://github.com/valkey-io/valkey |
| Jellyfin | Movies and video | GPL-2.0 | https://github.com/jellyfin/jellyfin |
| Navidrome | Music | GPL-3.0 | https://github.com/navidrome/navidrome |
| Audiobookshelf | Audiobooks | GPL-3.0 | https://github.com/advplyr/audiobookshelf |
| Kavita | Books and comics | GPL-3.0 | https://github.com/Kareadita/Kavita |
| FreshRSS | News | AGPL-3.0 | https://github.com/FreshRSS/FreshRSS |

## The operating system

Built from nixpkgs and nixos-raspberrypi at the exact revisions in `flake.lock`. Every package keeps its own license, recorded in its nixpkgs metadata. The main ones:

| Component | License |
|---|---|
| nixpkgs package expressions | MIT |
| nixos-raspberrypi | MIT |
| Linux kernel (Raspberry Pi 5) | GPL-2.0-only |
| Raspberry Pi boot firmware | Broadcom / Raspberry Pi binary redistribution license (`boot/LICENCE.broadcom` in raspberrypi/firmware) |
| Docker | Apache-2.0 |
| Samba | GPL-3.0 |
| Tailscale | BSD-3-Clause |
| hostapd | BSD-3-Clause |
| Avahi | LGPL-2.0-or-later |
| minisign | ISC |
| OpenSSH | BSD-2-Clause |
| Python | Python-2.0 (PSF) |

Source for everything in the OS is reproducible from `flake.lock`: `nix build` fetches the same inputs this image was built from.

## The drive edition's extras

The drive edition builds the same system for x86-64 and adds a Windows program to start it. These are what that brings in beyond the list above.

| Component | Role | License | Source |
|---|---|---|---|
| QEMU 11.1.0, with one patch of ours | Runs Keephaven on a Windows PC | GPL-2.0, and so is our patch | https://www.qemu.org/ , and `launcher/qemu-windows/` here |
| OVMF / edk2 | UEFI firmware the drive boots through | BSD-2-Clause-Patent | https://github.com/tianocore/edk2 |
| systemd, its EFI stub and ukify | Build `linux.efi` on the drive | LGPL-2.1-or-later | https://github.com/systemd/systemd |
| Go standard library | The Windows program and the writer | BSD-3-Clause | https://go.dev/ |

**QEMU is the one we changed.** `launcher/qemu-windows/win32-hdev-fixed-length.patch` is a change to QEMU's own `block/file-win32.c`; a derivative of GPL-2.0 code is GPL-2.0 whoever wrote it, and so is `keephaven-qemu.nix`, the recipe that compiles it. Every drive carries QEMU's licence, that patch in full, the recipe, the package pin, and a written offer of the complete corresponding source good for three years. Nothing has to be fetched to rebuild the binary: the recipe and its lock are on the drive.

Samba is in the drive image too, although file sharing over the house network does not work while Keephaven runs on a PC - Windows itself holds the one port it needs. The drive's own `README.txt` says so.

Licenses checked 2026-09-28 against each project's GitHub license field, nixpkgs `meta.license`, and VectorChord's README. The drive edition's rows were checked 2026-10-13 against the build files in that image.
