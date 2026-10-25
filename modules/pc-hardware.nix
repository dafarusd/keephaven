# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, modulesPath, ... }:

# The hardware entry for the PC target (x86-64, UEFI), the counterpart of the
# Raspberry Pi 5 entry in flake.nix. NOT RELEASED.
#
# It reuses the stock nixpkgs image builder the Pi build is based on, so
# disk-layout.nix carries over: the same GPT conversion, the same 16 GiB system
# and recovery partitions, the same first-boot data partition. What differs:
#   - partition 1 is an EFI system partition (disk-layout.nix types it ef00 here)
#     holding a loader the firmware starts by itself, EFI/BOOT/BOOTX64.EFI, so a
#     drive works in any machine without anything being installed into its NVRAM;
#   - what boots sits in one file, nixos/default/linux.efi, under the same folder
#     name the Pi uses, with nixos/rollback beside it (update.nix copies it);
#   - one extra partition, visible to Windows, for the launcher (disk-layout.nix).
let
  toplevel = config.system.build.toplevel;

  loaderConf = pkgs.writeText "loader.conf" ''
    default default.conf
    timeout 0
    editor no
  '';

  # One file per slot: kernel, initrd and the kernel command line (init= included)
  # packed into nixos/<slot>/linux.efi. Everything that decides what boots is then
  # INSIDE the slot folder, as it is on the Pi (kernel.img + initrd + cmdline.txt),
  # so the update's "swap the folder" rollback swaps all of it together. The two
  # entry files below never change after the image is built.
  entry = slot: pkgs.writeText "keephaven-${slot}.conf" ''
    title Keephaven (${slot})
    efi /nixos/${slot}/linux.efi
  '';
  ukify = "${pkgs.buildPackages.systemdUkify}/lib/systemd/ukify";
  stub = "${pkgs.systemd}/lib/systemd/boot/efi/linuxx64.efi.stub";

  # What boots, built ONCE as one artifact and then placed twice: on partition 1 where the
  # firmware starts it, and inside the system partition at /boot/linux.efi so an update carries
  # its own. An update has to put a new one on partition 1, and the Pi's way of doing that —
  # reassembling it on the box from the candidate's kernel and initrd — would mean shipping
  # ukify and the stub into every image and doing the assembly on a stranger's PC at the one
  # moment that decides whether their Keephaven starts again. Carrying the finished file inside
  # the update instead makes the on-box step a copy, a check and a swap.
  #
  # Built once rather than twice on purpose: two ukify invocations would be two sources of
  # truth and would drift. This way "the copy inside the system partition is the file on
  # partition 1" is true by construction, not by a comparison somebody has to remember to run.
  bootEfi = pkgs.runCommand "keephaven-linux-efi" { } ''
    set -euo pipefail
    mkdir -p $out
    ${ukify} build \
      --linux ${toplevel}/kernel \
      --initrd ${toplevel}/initrd \
      --cmdline "init=${toplevel}/init $(cat ${toplevel}/kernel-params)" \
      --os-release @${toplevel}/etc/os-release \
      --stub ${stub} \
      --output $out/linux.efi
    # The apply step will refuse a boot file whose own command line does not name the system
    # that was just written. Prove here that the string it will look for is actually in there,
    # so a build can never produce a file that apply would have to reject.
    ${pkgs.python3}/bin/python3 - "$out/linux.efi" <<'PYEOF'
    import sys
    want = b"init=${toplevel}/init"
    blob = open(sys.argv[1], "rb").read()
    if want not in blob:
        sys.exit("the boot file does not carry %r" % want)
    print("the boot file carries its own init= line, %d bytes" % len(blob))
    PYEOF
  '';
in
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image.nix") ];

  nixpkgs.hostPlatform = "x86_64-linux";
  keephaven.platform = "pc";

  # ---- this is a different product from the Pi box, and it says so ----
  #
  # Until now a drive called itself 2026.10.05 and asked the Pi's manifest the same question a
  # Pi asks, with nothing in the request saying it was a drive. Two consequences, both bad: a
  # drive counted as a Pi in the release figures, and a drive offered a Pi image — which it
  # then refuses, because the install step is the Pi's (update.nix's pcRefuseApply). "What good
  # is a unit frozen in time" is the right question and this is the first half of the answer.
  #
  # Its own name, its own version line, its own feed. The feed path is what keeps the two
  # apart on the server: a drive asks .../ssd/manifest.json and can never be handed a Pi image
  # by accident, whatever either side gets wrong later.
  # The Agent Memory edition is its own product on a drive too, with its own feed below.
  # Photos keeps the shipped name and path, byte for byte.
  keephaven.productName =
    if config.keephaven.edition == "photos" then "Keephaven SSD" else "Keephaven Agent Memory SSD";
  # Written HERE, not in update.nix: this module is only ever imported for a drive, so the file
  # cannot reach a Pi image. Doing it in the shared module moved both Pi store paths.
  environment.etc."cloudunit/update/product".text = config.keephaven.productName + "\n";
  # Bumped for the first real update test: a drive flashed from 63f97f1 reports 2026.10.13 and
  # is offered the candidate built from THIS commit, which reports 2026.10.14. The owner bumps
  # this per release and the same string names the published image and its manifest.
  keephaven.imageVersion = "2026.10.26";
  # mkForce because the edition already picks a feed (editions.nix sets .../photos/ for a
  # Photos box). A drive is not a Photos box on a Pi, so it takes its own path regardless of
  # edition — that separation is the whole point.
  # One feed per drive edition: an Agent Memory drive must never be offered a Photos image,
  # which it would accept, since every edition is signed with the same key (2026-10-24).
  keephaven.updateBaseUrl = lib.mkForce (
    if config.keephaven.edition == "photos" then "https://updates.keephaven.co/ssd/"
    else "https://updates.keephaven.co/ssd-${config.keephaven.edition}/");

  # The loader is a file placed on partition 1 at build time. Nothing runs
  # bootctl or grub-install on the box.
  boot.loader.grub.enable = false;
  boot.loader.systemd-boot.enable = false;

  # Wi-Fi and network cards on PCs need vendor firmware files. These are
  # redistributable but not free software (see the README before releasing).
  hardware.enableRedistributableFirmware = true;

  # disk-layout.nix's recovery step maps partition 3 through a loop device; on
  # the Pi kernel that driver is built in.
  boot.initrd.kernelModules = [ "loop" ];

  # The serial console first, so whatever runs this as a virtual machine can keep
  # a log; tty1 last, so the screen stays the kernel's console as on the Pi.
  boot.kernelParams = [ "console=ttyS0,115200n8" "console=tty1" ];
  # Same as the Pi ships: kernel messages on the console, so the log is worth reading.
  boot.consoleLogLevel = 7;
  # A serial console to log to, not to log in on.
  systemd.services."serial-getty@ttyS0".enable = false;

  # ---- the drive's sticker ----
  #
  # A Pi box has its password printed on a sticker on the bottom. A USB drive has
  # nowhere to print one, and the setup screen deliberately stops showing the
  # password once setup is done (setup-screen.nix) — so on 2026-10-12 finishing
  # setup without copying it meant no way into the photos app, into file sharing,
  # or into Settings, because /reset-password asks for the very password you have
  # lost. The drive itself is the PC's sticker: this writes the same three lines
  # the factory sticker-print pipeline emits (cloudunit-print-identity) to the
  # drive's Windows-visible partition, where the owner can read them any time the
  # drive is plugged in.
  #
  # Two things the first version of this got wrong, both found by reading it back off a real
  # drive on 2026-10-13: it said "open http://localhost" with no qualification, which is true
  # on the Windows PC and false from a phone or from a Keephaven running anywhere else; and it
  # said the password was for file sharing, which on a PC cannot be reached from the house
  # network at all — Windows owns port 445, so the only way in is the remote-access address.
  # Do not put a reachability claim in here that depends on where the reader is standing.
  #
  # It is plaintext, exactly as a sticker is plaintext, and anyone holding the
  # drive already holds an unencrypted data partition. It is NOT removed after
  # setup: removing it is the trap this exists to close.
  #
  # Written while Keephaven is running, which is the one time this partition is
  # safe to touch: the Windows helper has locked and dismounted it for the whole
  # run, so nothing on the PC can have it open. It lands beside Keephaven.exe and
  # under no folder the helper hashes, so the launcher's file check is unaffected.
  systemd.services.keephaven-drive-sticker = {
    description = "Write this Keephaven's address and password to the drive's Windows partition";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloudunit-unit-bootstrap.service" ];
    requires = [ "cloudunit-unit-bootstrap.service" ];
    unitConfig.ConditionPathExists = "/var/lib/cloudunit/unit.env";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -uo pipefail
      part=/dev/disk/by-partlabel/KEEPHAVEN
      [ -b "$part" ] || { echo "no KEEPHAVEN partition on this drive; nothing written"; exit 0; }
      . /var/lib/cloudunit/unit.env
      mnt=$(${pkgs.coreutils}/bin/mktemp -d)
      ${pkgs.util-linux}/bin/mount -t vfat -o rw,umask=0022 "$part" "$mnt" || {
        echo "could not mount the drive's Windows partition; nothing written"; exit 0; }
      ${pkgs.coreutils}/bin/cat > "$mnt/Keephaven-password.txt" <<EOF
      Keephaven

      Open your Keephaven in a browser on the PC it is plugged into:
        http://localhost
      From a phone or another computer in the house, use the address the
      Keephaven window on that PC shows you.

      Password:  $UNIT_PASSWORD

      ${if builtins.elem "immich" config.keephaven.activeApps then ''
      That password is for the photos app and for the Settings page. The photos
      app also wants an email address: keephaven@local'' else ''
      That password is for the Settings page, where you add and remove your AI
      agents (Settings > Agents).''}

      Keep this file. It is the only copy. A Keephaven box has this printed on a
      sticker underneath it; a drive has this file instead. Anyone who can read
      this drive can read it, so treat the drive the way you would treat the box.

      If you change the password in Settings, this file still shows the one the
      drive started with - the same as the sticker on a box.
      EOF
      ${pkgs.coreutils}/bin/sync
      ${pkgs.util-linux}/bin/umount "$mnt" && ${pkgs.coreutils}/bin/rmdir "$mnt"
      echo "wrote Keephaven-password.txt to the drive's Windows partition"
    '';
  };

  # ---- the drive's update code ----
  #
  # Reads the code the Windows writer stamped into Keephaven-code.txt on p4 and puts it in /run,
  # which is tmpfs: re-derived at every boot, never cached on a partition. That is deliberate.
  # p5 and p4 are both writable from the PC without privileges, so nothing on either may be
  # trusted to say WHERE updates come from - the host is baked into the image and only this one
  # path segment comes from the drive (gate section 4a). The worst a tampered code can do is
  # earn a 403, which the dashboard shows as "code was not accepted" rather than a network error.
  #
  # Mounted read-only, and failure is never fatal: no partition, no file or no field all leave
  # /run/cloudunit/update-code absent, which the update scripts read as the literal segment
  # "no-code" and the gate refuses out loud.
  systemd.services.keephaven-update-code = {
    description = "Read this drive's update code from its Windows-visible partition";
    wantedBy = [ "multi-user.target" ];
    before = [ "cloudunit-update-check.service" "cloudunit-update-stage.service" ];
    # After the sticker, which mounts the same partition read-write at boot: run together, this
    # read-only mount failed on 2 of 3 boots of a drive ("already mounted ... would change RO
    # state") and the drive came up with no code until its next boot (2026-10-24, VM journal).
    after = [ "keephaven-drive-sticker.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -uo pipefail
      part=/dev/disk/by-partlabel/KEEPHAVEN
      [ -b "$part" ] || { echo "no KEEPHAVEN partition; this drive has no update code"; exit 0; }
      mnt=$(${pkgs.coreutils}/bin/mktemp -d)
      ${pkgs.util-linux}/bin/mount -t vfat -o ro "$part" "$mnt" || {
        echo "could not read the drive's Windows partition; no update code"; exit 0; }
      raw=$(${pkgs.gnugrep}/bin/grep -ao 'KEEPHAVEN-UPDATE-CODE:[A-Za-z0-9.-]\{64\}' \
              "$mnt/Keephaven-code.txt" 2>/dev/null | ${pkgs.coreutils}/bin/head -1 || true)
      ${pkgs.util-linux}/bin/umount "$mnt"; ${pkgs.coreutils}/bin/rmdir "$mnt"
      field=''${raw#KEEPHAVEN-UPDATE-CODE:}
      # The padding is dots and a code never contains one, so cut at the first dot.
      code=''${field%%.*}
      if [ -z "$code" ]; then
        echo "no update code on this drive (the field is empty)"; exit 0
      fi
      if ! printf '%s' "$code" | ${pkgs.gnugrep}/bin/grep -qE '^[A-Za-z0-9][A-Za-z0-9-]{7,63}$'; then
        echo "the update code on this drive is not a code; ignoring it"; exit 0
      fi
      ${pkgs.coreutils}/bin/install -d -m 0755 /run/cloudunit
      ${pkgs.coreutils}/bin/install -m 0400 /dev/null /run/cloudunit/update-code
      printf '%s\n' "$code" > /run/cloudunit/update-code
      # Deliberately not echoed: it identifies the buyer, and the serial log is kept as evidence.
      echo "this drive carries an update code (''${#code} characters)"
    '';
  };

  sdImage.firmwareSize = 1024;
  # Ends in a newline on purpose: update.nix appends a command to this text.
  sdImage.populateRootCommands = ''
    mkdir -p ./files/boot
    cp ${bootEfi}/linux.efi ./files/boot/linux.efi
  '';
  sdImage.populateFirmwareCommands = ''
    mkdir -p firmware/EFI/BOOT firmware/loader/entries firmware/nixos/default
    cp ${pkgs.systemd}/lib/systemd/boot/efi/systemd-bootx64.efi firmware/EFI/BOOT/BOOTX64.EFI
    cp ${loaderConf} firmware/loader/loader.conf
    cp ${entry "default"} firmware/loader/entries/default.conf
    cp ${entry "rollback"} firmware/loader/entries/rollback.conf
    cp ${bootEfi}/linux.efi firmware/nixos/default/linux.efi
  '';
}
