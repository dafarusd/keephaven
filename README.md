# Keephaven

A private home cloud for the Raspberry Pi 5. Photos, movies, music, audiobooks, books and news on a box in your house — no subscription, no account with anyone.

This repo is the whole OS: a NixOS flake that builds the exact image Keephaven boxes run. Built solo by [@Dafarusd](https://x.com/Dafarusd).

## What's on it

Six open-source apps, installed and signed in on first boot:

| For | App |
|---|---|
| Photos | [Immich](https://github.com/immich-app/immich) |
| Movies and video | [Jellyfin](https://github.com/jellyfin/jellyfin) |
| Music | [Navidrome](https://github.com/navidrome/navidrome) |
| Audiobooks | [Audiobookshelf](https://github.com/advplyr/audiobookshelf) |
| Books and comics | [Kavita](https://github.com/Kareadita/Kavita) |
| News | [FreshRSS](https://github.com/FreshRSS/FreshRSS) |

Around them:

- **Its own Wi-Fi network.** Works with no internet and no router.
- **One password** for the Wi-Fi, every app and the network folders.
- **Network folders** (SMB) for Movies, Music, Audiobooks and Books, so you can drag files in from any computer.
- **A recovery copy of the system** on its own partition. If the system partition gets corrupted, the box restores it from that copy on the next boot.
- **Signed updates.** The box checks once a day, shows an update on the dashboard, and installs only when you tap Install now. It refuses anything not signed by the key in `keys/keephaven-update.pub`.
- **Box-to-box backup.** Pair two Keephavens over Tailscale and one keeps a nightly copy of the other.
- **Remote access**, off by default, through your own Tailscale account.

The app images are pinned by digest and baked into the image. Nothing gets pulled from Docker Hub at runtime.

## Download

Current release: **2026.08.19** — the same version the update server hands out to every box.

Step-by-step setup lives on the site: https://keephaven.co/download#setup

- File: [`keephaven-2026.08.19.img.zst`](https://updates.keephaven.co/download/keephaven-2026.08.19.img.zst)
- Size: 6,266,477,542 bytes compressed, 35,445,014,528 bytes unpacked
- SHA-256: `1c2134b55e729a87fbc270d60c9d18b73d93997361f57f548c30bb84dbc9ddd7`

Check it before you flash:

```
sha256sum keephaven-2026.08.19.img.zst
```

## What you need

- A Raspberry Pi 5. Tested on the 8 GB model.
- An NVMe SSD on a Pi 5 NVMe case or HAT. Tested with a Samsung 990 PRO 1 TB. The system takes the first 35.4 GB and your files get the rest.
- A computer to write the image to the SSD, and a microSD card with Raspberry Pi OS to read the setup password once (see First boot).

Some NVMe cases need `PCIE_PROBE=1` in the Pi's EEPROM config before the Pi sees the drive. That's a Pi firmware setting, not part of this image.

## Flash it

These commands are for Linux. Find your SSD first — writing to the wrong disk erases it:

```
lsblk -o NAME,SIZE,MODEL,TRAN
```

Then, with your SSD's name in place of `sdX`:

```
zstd -d keephaven-2026.08.19.img.zst -o keephaven.img
sudo blkdiscard -f /dev/sdX
sudo dd if=keephaven.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

`blkdiscard` wipes the drive first. Skip it and a drive that had Keephaven on it before brings back its old Wi-Fi name and password, because first boot adopts any existing data partition instead of making a new one.

## First boot

1. Put the SSD in the Pi and plug in power. Ethernet is optional.
2. Within about 3 minutes a Wi-Fi network named `Keephaven-` plus five characters shows up. The box made that name, and a random password, on this first boot.
3. Sold boxes carry that password on a sticker. On a box you flashed yourself, read it off the drive once. The easiest way uses the Pi itself: unplug it at the wall, put in a microSD card with Raspberry Pi OS, leave the SSD connected, and power on. It boots Pi OS from the card. Then run:

   ```
   sudo mkdir -p /mnt/keephaven
   sudo mount -o ro /dev/disk/by-label/cloudunit-data /mnt/keephaven
   sudo cat /mnt/keephaven/unit.env
   ```

   You'll see three lines. `UNIT_PASSWORD` is your password. Power off, take the card out, and power on again. It boots Keephaven.

   If it boots Keephaven even with the card in, your Pi is set to try the SSD first. With a USB SSD, unplug it until Pi OS has started, then plug it back in. No SD card? Move the SSD to any Linux computer and run the same three commands. Windows and macOS can't read the data partition.
4. Join the `Keephaven-…` network with that password. The setup page opens by itself. If it doesn't, go to `http://192.168.50.1`.
5. Finish setup. The dashboard links all six apps. Username `keephaven`, same password. Photos (Immich) signs in with `keephaven@local` instead of a username.

Settings live at port 8888 on the box. Changing the password there changes it everywhere.

## Build it yourself

You need Nix with flakes, plus either an aarch64 machine or QEMU emulation. On x86 Linux that means `binfmt` for aarch64 and `extra-platforms = aarch64-linux` in your Nix config.

```
git clone https://github.com/dafarusd/keephaven
cd keephaven
nix build .#packages.aarch64-linux.prod --accept-flake-config -o result-prod
```

The image lands in `result-prod/sd-image/`. `--accept-flake-config` lets Nix use the `nixos-raspberrypi` binary cache, so the Pi kernel downloads instead of compiling.

To confirm this source is what built the download:

```
nix eval --raw .#packages.aarch64-linux.prod.outPath --accept-flake-config
```

At this commit it prints `/nix/store/1kiiky37ksyj8fil78f5f7y7c15xgwhh-nixos-image-rpi5-kernel.img.zst`, the same store path the published image was built as. Same source, same inputs. Your own build's bytes may still differ from the download, since that isn't checked bit for bit.

There are two builds from one module list:

- **prod** — no SSH key at all, SSH only over Tailscale. This is the download.
- **dev** — bakes *your* SSH public key and opens SSH on the LAN, for poking at a bench box. Put your key in `keys/dev-admin.pub`, run `git add -f keys/dev-admin.pub`, then build `.#packages.aarch64-linux.dev`. It won't build without a key.

## What the box sends out

Keephaven's own code makes one outside call. Once a day it fetches `manifest.json` from `https://updates.keephaven.co/`. Apart from your IP address, which any request carries, the only thing it says about the box is its version, in the `User-Agent` header. No serial, no account, no ID.

The Tailscale client runs with its stock settings and isn't signed in to anything until you turn on remote access. The six apps are stock upstream builds with their own defaults.

If you'd rather not get updates from here, build with your own `keephaven.updateBaseUrl` and your own key in `keys/keephaven-update.pub`.

## Layout

- `flake.nix` — the prod and dev builds.
- `modules/` — one file per piece: disk layout and recovery, the setup wizard, dashboard, settings, updates, Wi-Fi access point, Tailscale, backup.
- `modules/access-profile.nix` — the only file that differs between prod and dev.
- `compose/` — the app stacks.
- `keys/keephaven-update.pub` — the public key updates are checked against.

## Limits

- Tested on a Pi 5 8 GB booting from NVMe only. SD card boot and the 4 GB Pi haven't been tested.
- Reading the setup password takes one extra boot from a Raspberry Pi OS SD card, or a Linux computer.
- Code comments point at a build log and decision notes that aren't in this repo.
- `compose/vaultwarden` is here but not switched on.

## License

AGPL-3.0 — see `LICENSE`. Copyright (c) 2026 Keephaven LLC. Commercial licenses for Keephaven's own code are available from Keephaven LLC; see `NOTICE`.

Keephaven™ and the Keephaven logo are trademarks of Keephaven LLC. The license covers the code, not the name or the logo.

The apps inside the image keep their own licenses: Immich AGPL-3.0, Jellyfin GPL-2.0, Navidrome GPL-3.0, Audiobookshelf GPL-3.0, Kavita GPL-3.0, FreshRSS AGPL-3.0. Their source is at the links in the table above.

---

Built by Dafarus — local-first software and hardware you own.

Follow the work on X: [@Dafarusd](https://x.com/Dafarusd)

My company:
- Keephaven — [keephaven.co](https://keephaven.co) · [source](https://github.com/dafarusd/keephaven) · [X](https://x.com/Keephaven) · [Facebook](https://www.facebook.com/profile.php?id=61592155452190)

More work: [gate](https://github.com/dafarusd/gate) · [Sentinel](https://github.com/dafarusd/sentinel-public) · [Agent Ultra](https://github.com/dafarusd/Ultra-Agent-Release) · [EveryVoice](https://github.com/dafarusd/everyvoice) · [Mind Meld](https://github.com/dafarusd/mindmeld) · [monero-swap](https://github.com/dafarusd/monero-swap)

Donations help keep it going:
- BTC `bc1qpyeupsjkrny259upq9jrg7d22h32ncrlknj3vw`
- ETH `0x8ec99D65C23D39772Cc2425cfd1F7a3872af8636`
- XMR `428vC4FYUs7Dm2aAAN2i2zY39z4sM5RDYBAPdyCxCS4ZUJ36KENQaP5AdjYpytvtkXZ15sB8ooAGGR1GehJjo5GUSPnHVAV`
