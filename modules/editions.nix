# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# The edition switch. ONE place that says which apps a box installs, so the eight
# modules that wire apps read from here instead of each keeping its own copy of
# "the six". See docs/architecture/editions.md.
#
# Design invariant: for edition = "entertainment" the list is the same six in the
# same order as before, so the built image is byte-identical to today's. The proof
# is that cloudunit-prod's toplevel store path does not move when a module is
# switched to read activeApps. If it moves, that module reordered or dropped
# something — fix it, don't lower the bar.
{ config, lib, ... }:
let
  # Canonical order: Immich first (every edition has it), then the five media apps
  # in the order most modules already use. A module whose own order differs (samba
  # puts Photos last) must filter ITS list by membership, not replace it with this.
  editions = {
    entertainment = [ "immich" "jellyfin" "navidrome" "audiobookshelf" "kavita" "freshrss" ];
    photos = [ "immich" ];
  };

  # Every app any edition can name.
  universe = lib.unique (lib.concatLists (lib.attrValues editions));

  # The data folders each app backs up, [] for none (FreshRSS keeps nothing a
  # media box replicates). This is the AUTHORITY for backup coverage: it must
  # equal, in order, the rsync path list in replication-sender.nix and the
  # restorePaths in promote.nix. Those stay hard-coded (they are runtime-guarded
  # with `[ -d ]`, so they are already edition-safe), but the assertion below
  # catches the real drift: adding an app to an edition without declaring whether
  # it has backup data, which would silently leave that app out of box-to-box
  # backup. Keep this list and those two in sync when an app is added.
  appBackup = {
    immich = [ "immich/library" "immich/external" ];
    jellyfin = [ "jellyfin/media" ];
    navidrome = [ "navidrome/media" ];
    audiobookshelf = [ "audiobookshelf/media" ];
    kavita = [ "kavita/media" ];
    freshrss = [ ];
  };
  undeclared = lib.subtractLists (builtins.attrNames appBackup) universe;
in
{
  options.keephaven.edition = lib.mkOption {
    type = lib.types.enum (builtins.attrNames editions);
    default = "entertainment";
    description = ''
      Which edition this image builds — the app payload on the shared base.
      "entertainment" is today's box (the six media apps). "photos" is Immich only.
      Default is entertainment, so an unset value builds exactly today's image.
    '';
  };

  options.keephaven.activeApps = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      The apps the selected edition installs. Modules READ this to decide which
      services, images, shares, tiles, provisioners and backup paths to emit.
      Never set it directly — it is derived from keephaven.edition.
    '';
  };

  options.keephaven.activeBackupPaths = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    readOnly = true;
    description = ''
      The data folders the active edition backs up and restores, in order, derived
      from appBackup over activeApps. promote.nix reads this for its restorePaths;
      replication-sender.nix's rsync list should be wired to it too (deferred to the
      edition-marker release wave, since that reformats a shell for-loop). The
      appBackup authority and its drift assertion live in modules/editions.nix.
    '';
  };

  config.keephaven.activeApps = editions.${config.keephaven.edition};
  config.keephaven.activeBackupPaths =
    lib.concatMap (a: appBackup.${a}) config.keephaven.activeApps;

  # Each edition updates along its OWN feed, so a box is only ever offered images
  # of its own edition. Entertainment stays at the bucket root (the shipped value,
  # so its image is unchanged); Photos points at the photos/ sub-path. The runtime
  # bench override (update.conf) still wins for testing.
  config.keephaven.updateBaseUrl =
    if config.keephaven.edition == "entertainment"
    then "https://updates.keephaven.co/"
    else "https://updates.keephaven.co/${config.keephaven.edition}/";

  # Drift guard (eval-time, path-neutral — a passing assertion adds nothing to the
  # build). Fires if an edition names an app with no appBackup entry, so no app can
  # be added without a decision about its box-to-box backup.
  config.assertions = [
    {
      assertion = undeclared == [ ];
      message =
        "modules/editions.nix: these edition apps have no appBackup entry: "
        + lib.concatStringsSep ", " undeclared
        + ". Declare each app's backup folders (or [ ] if it has none), and keep "
        + "that in sync with replication-sender.nix's rsync paths and promote.nix "
        + "restorePaths, or the app would be silently left out of backups.";
    }
  ];
}
