# Third-party software in the Keephaven image

This repo's own code, the NixOS modules and scripts that turn a Raspberry Pi 5 into a Keephaven, is AGPL-3.0 (see `LICENSE`).

The image it builds also contains other people's software. Each keeps its own license, and nothing in Keephaven's license changes that. If you ship boxes with this image, their terms apply to you as well as ours.

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

Licenses checked 2026-09-28 against each project's GitHub license field, nixpkgs `meta.license`, and VectorChord's README.
