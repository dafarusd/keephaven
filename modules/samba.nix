# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  sambaUser = "keephaven";

  # Edition switch (modules/editions.nix): a share only when its app is in the
  # edition. The order is preserved (Photos stays LAST), so for entertainment the
  # rendered smb.conf is identical. A Photos box keeps only the Photos share.
  shares = builtins.filter (s: builtins.elem s.app config.keephaven.activeApps) [
    { name = "Movies";     dir = "jellyfin/media";       app = "jellyfin"; }
    { name = "Music";      dir = "navidrome/media";      app = "navidrome"; }
    { name = "Audiobooks"; dir = "audiobookshelf/media"; app = "audiobookshelf"; }
    { name = "Books";      dir = "kavita/media";         app = "kavita"; }
    # "Photos" drop-in -> Immich External Library. dir is a SIBLING of Immich's
    # managed library (immich/library), never inside it. The share definition +
    # creds come from here; the authoritative dir-creation (owned by keephaven,
    # before immich mounts it, on every boot incl. OTA) is cloudunit-immich-external
    # in services.nix — because samba-bootstrap's mkShareDirs only runs on first
    # boot and would be skipped on already-provisioned (OTA'd) boxes.
    { name = "Photos";     dir = "immich/external";      app = "immich"; }
  ];

  # APP PICKER: a share whose app the owner switched off disappears. Each
  # pickable share includes a small file the box rewrites from the .off markers
  # (cloudunit-samba-apps below): empty when the app is on, "available = no /
  # browseable = no" when it is off. Photos (Immich) is never pickable.
  appsDir = config.keephaven.appsDir;
  pickableShares = builtins.filter (s: builtins.elem s.app config.keephaven.pickableApps) shares;
  shareInclude = s: "${appsDir}/smb-${s.app}.conf";

  shareSettings = lib.listToAttrs (map (s: {
    name = s.name;
    value = {
      path = "${dataDir}/${s.dir}";
      browseable = "yes";
      writeable = "yes";
      "valid users" = sambaUser;
      "force user" = sambaUser;
      "create mask" = "0664";
      "directory mask" = "0775";
    } // lib.optionalAttrs (builtins.elem s.app config.keephaven.pickableApps) {
      include = shareInclude s;
    };
  }) shares);

  mkShareDirs = lib.concatMapStringsSep "\n" (s: ''
    mkdir -p ${dataDir}/${s.dir}
    chown ${sambaUser}:${sambaUser} ${dataDir}/${s.dir}
  '') shares;
in
{
  users.users.${sambaUser} = {
    isSystemUser = true;
    group = sambaUser;
    description = "Keephaven file-share user";
  };
  users.groups.${sambaUser} = {};

  services.samba = {
    enable = true;
    openFirewall = true;
    # Advertise the box over exactly ONE discovery path: mDNS, via the avahi
    # _smb._tcp service below. NetBIOS (nmbd) was ALSO advertising the box, under a
    # separate (and truncated -> "netbios name too long") name, so a client listed
    # the same server -- and therefore every share -- twice. Turn NetBIOS off.
    nmbd.enable = false;
    settings = {
      global = {
        "server string" = "Keephaven";
        "workgroup" = "WORKGROUP";
        "security" = "user";
        "map to guest" = "never";
        "server min protocol" = "SMB2";
        # Belt and suspenders for the single-advertisement guarantee: no NetBIOS
        # presence from smbd either, and no samba-side mDNS registration (avahi is
        # the sole _smb._tcp registrant). Immune to a future samba build enabling
        # its own mDNS. Prevents the box (and its shares) appearing twice.
        "disable netbios" = "yes";
        "multicast dns register" = "no";
      };
    } // shareSettings;
  };

  services.avahi.extraServiceFiles.smb = ''
    <?xml version="1.0" standalone='no'?>
    <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
    <service-group>
      <name replace-wildcards="yes">%h</name>
      <service>
        <type>_smb._tcp</type>
        <port>445</port>
      </service>
    </service-group>
  '';

  # APP PICKER: render each pickable share's include file from the .off markers.
  # Runs every boot BEFORE smbd, so smbd starts with the right share list; a later
  # `systemctl restart` (the dashboard toggle, P2) re-renders and has a running
  # smbd re-read its config. No markers (a box set up before the picker) = every
  # include empty = every share exactly as before.
  systemd.services.cloudunit-samba-apps = {
    description = "Cloud Unit - hide network folders of apps the owner switched off";
    before = [ "samba-smbd.service" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = dataDir;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      mkdir -p ${appsDir}
      ${lib.concatMapStringsSep "\n" (s: ''
        if [ -e ${appsDir}/${s.app}.off ]; then
          printf 'available = no\nbrowseable = no\n' > ${shareInclude s}.tmp
        else
          : > ${shareInclude s}.tmp
        fi
        mv -f ${shareInclude s}.tmp ${shareInclude s}
      '') pickableShares}
      if ${pkgs.systemd}/bin/systemctl -q is-active samba-smbd.service; then
        ${pkgs.samba}/bin/smbcontrol smbd reload-config || true
      fi
    '';
  };

  systemd.services.cloudunit-samba-bootstrap = {
    description = "Cloud Unit - Samba credential bootstrap (from unit.env)";
    after = [ "samba-smbd.service" "cloudunit-unit-bootstrap.service" ];
    wants = [ "cloudunit-unit-bootstrap.service" ];
    wantedBy = [ "multi-user.target" ];
    # Runs EVERY boot -- deliberately NOT marker-gated. The samba passdb (the
    # smbpasswd credential) lives under /var/lib/samba on the ROOT fs (p2), which
    # an OTA REPLACES -- wiping the password. A first-boot-only marker on p4 would
    # survive the update and (falsely) report "already bootstrapped", so the passdb
    # would never be re-seeded -> empty password -> Samba auth fails after every
    # update. Re-asserting from unit.env each boot is idempotent and OTA-safe.
    unitConfig = {
      RequiresMountsFor = dataDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      ${mkShareDirs}
      if [ ! -f ${dataDir}/unit.env ]; then
        echo "unit.env not present yet; retrying" >&2
        exit 1
      fi
      . ${dataDir}/unit.env
      if [ -z "''${UNIT_PASSWORD:-}" ]; then
        echo "UNIT_PASSWORD empty; retrying" >&2
        exit 1
      fi
      # Idempotent: add the samba user on first seed, update the password on every
      # later boot (including after an OTA p2-swap left an empty passdb). smbpasswd
      # -a fails on an existing entry in some builds, so branch on existence.
      if ${pkgs.samba}/bin/pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx ${sambaUser}; then
        printf '%s\n%s\n' "$UNIT_PASSWORD" "$UNIT_PASSWORD" \
          | ${pkgs.samba}/bin/smbpasswd -s ${sambaUser}
      else
        printf '%s\n%s\n' "$UNIT_PASSWORD" "$UNIT_PASSWORD" \
          | ${pkgs.samba}/bin/smbpasswd -a -s ${sambaUser}
      fi
    '';
  };
}
