# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  composeDir = "/etc/cloudunit/compose";
  dataDir = "/var/lib/cloudunit";

  mkService = { name, description, needsEnv ? false, preUp ? "" }:
    let
      # systemd ANDs repeated ConditionPathExists, so each entry narrows.
      conds = [ "!${dataDir}/.backup-mode" ]
        # APP PICKER: a pickable app stays down while its .off marker exists
        # (modules/editions.nix). No marker = runs, exactly as before the picker.
        ++ lib.optional (builtins.elem name config.keephaven.pickableApps)
             "!${config.keephaven.appsDir}/${name}.off"
        ++ lib.optional needsEnv "${dataDir}/${name}/.env";
    in
    {
      "cloudunit-${name}" = {
        inherit description;
        # Order after THIS service's own image loader so every image the compose
        # file references is already in the local store — but NOT behind the other
        # services' loads, so a light service comes up without waiting for Immich's
        # heavy stack. requires (not just after) makes a load failure fail the
        # service loudly rather than letting it try to pull (it can't: pull_policy
        # is never).
        after = [ "docker.service" "network-online.target" "cloudunit-image-load-${name}.service" ];
        requires = [ "docker.service" "cloudunit-image-load-${name}.service" ];
        wants = [ "network-online.target" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          RequiresMountsFor = dataDir;
          # BACKUP MODE (Phase 3): on a box holding a replica, the six services
          # stay stopped across every boot. Absent marker = today's behaviour
          # exactly, so a primary is unaffected. Phase 4's promotion removes the
          # marker, which is what lets the services come back.
          ConditionPathExists = if builtins.length conds == 1 then builtins.head conds else conds;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          WorkingDirectory = "${composeDir}/${name}";
          Restart = "on-failure";
          RestartSec = "20s";
          # Pinned image refs (NAME:kh-<digest12>) for compose `${…}`
          # substitution. Rendered from the single-source pin in images.nix.
          EnvironmentFile = "/etc/cloudunit/compose/images.env";
        };
        script = ''
          set -e
          mkdir -p ${dataDir}/${name}
          ${lib.optionalString needsEnv ''
            cp ${dataDir}/${name}/.env ${composeDir}/${name}/.env
          ''}
          ${preUp}
          # Clear any stale container+network left by an UNCLEAN prior boot
          # (power-cut => ExecStop's `compose down` never ran => a `restart: always`
          # container is resurrected by dockerd against an OLD network id while `up`
          # recreates <svc>_default with a NEW id => "network <OLD_ID> not found",
          # exit 128, shifting set each boot). Tearing the project down first makes
          # `up` recreate a matching container+network pair every boot.
          # -v is deliberately OMITTED: these stacks use bind mounts (p4 data is a
          # host path compose never removes) and have no named volumes, so service
          # DATA is untouched. `|| true` keeps a clean first boot (nothing to remove)
          # from tripping `set -e`.
          ${pkgs.docker}/bin/docker compose \
            --project-directory ${composeDir}/${name} \
            -f ${composeDir}/${name}/docker-compose.yml \
            down --remove-orphans || true
          ${pkgs.docker}/bin/docker compose \
            --project-directory ${composeDir}/${name} \
            -f ${composeDir}/${name}/docker-compose.yml \
            up -d --force-recreate
        '';
        preStop = ''
          ${pkgs.docker}/bin/docker compose \
            --project-directory ${composeDir}/${name} \
            -f ${composeDir}/${name}/docker-compose.yml \
            down
        '';
      };
    };

  # APP PICKER: the ONE privileged entry point for switching an app on or off
  # (Settings -> Apps, via sudo -n as cloudunit-web). Arguments are untrusted:
  # the app must be in THIS image's pickable list and the state exactly on/off.
  #   cloudunit-app-set status          -> "<app> on|off" per pickable app,
  #                                        or "backup-mode" on a backup box
  #   cloudunit-app-set <app> on|off
  # The marker is written FIRST, so even a racing start is condition-blocked.
  # Turning an app off never deletes its files.
  appSet = pkgs.writeShellScriptBin "cloudunit-app-set" ''
    set -u
    APPS_DIR=${config.keephaven.appsDir}
    SYSCTL=${pkgs.systemd}/bin/systemctl
    PICKABLE="${lib.concatStringsSep " " config.keephaven.pickableApps}"
    CMD="''${1-}"
    if [ "$CMD" = status ]; then
      if [ -e ${dataDir}/.backup-mode ]; then echo backup-mode; exit 0; fi
      for a in $PICKABLE; do
        if [ -e "$APPS_DIR/$a.off" ]; then echo "$a off"; else echo "$a on"; fi
      done
      exit 0
    fi
    APP="$CMD"; STATE="''${2-}"
    [ -n "$APP" ] || { echo "no app given" >&2; exit 2; }
    # EXACT match against the list. (A substring test like *" $APP "* lets
    # "jellyfin navidrome" through as one argument -- caught in the P2 test.)
    known=0
    for a in $PICKABLE; do [ "$a" = "$APP" ] && known=1; done
    [ "$known" = 1 ] || { echo "unknown app: $APP" >&2; exit 2; }
    case "$STATE" in (on|off) ;; (*) echo "state must be on or off" >&2; exit 2 ;; esac
    if [ -e ${dataDir}/.backup-mode ]; then
      echo "this Keephaven is a backup box; its apps stay off until it takes over" >&2; exit 3
    fi
    ${pkgs.coreutils}/bin/mkdir -p "$APPS_DIR"
    if [ "$STATE" = off ]; then
      ${pkgs.coreutils}/bin/touch "$APPS_DIR/$APP.off"
      $SYSCTL stop --no-block "cloudunit-$APP-provision.service" "cloudunit-$APP.service" || true
    else
      ${pkgs.coreutils}/bin/rm -f "$APPS_DIR/$APP.off"
      $SYSCTL start --no-block "cloudunit-$APP.service" || true
      # Restart (not start): re-runs first-time setup for an app that was off
      # since setup, and is a no-op "already provisioned" for one that ran before.
      $SYSCTL restart --no-block "cloudunit-$APP-provision.service" || true
    fi
    $SYSCTL restart cloudunit-samba-apps.service || true
    ${pkgs.util-linux}/bin/logger -t cloudunit-apps "owner switched $APP $STATE"
    echo ok
  '';

  mkBootstrap = { name }:
    {
      "cloudunit-${name}-bootstrap" = {
        description = "Cloud Unit - ${name} env bootstrap (DEV)";
        before = [ "cloudunit-${name}.service" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          ConditionPathExists = "!${dataDir}/${name}/.env";
          RequiresMountsFor = dataDir;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p ${dataDir}/${name}
          DB_PW=$(${pkgs.openssl}/bin/openssl rand -hex 24)
          ${pkgs.gnused}/bin/sed "s|{{DB_PASSWORD}}|$DB_PW|" \
            ${composeDir}/${name}/.env.template \
            > ${dataDir}/${name}/.env
          chmod 600 ${dataDir}/${name}/.env
        '';
      };
    };
in
{
  # Immich is in every edition, so its compose files are unconditional. The five
  # media apps' compose files are emitted only when the edition includes them
  # (modules/editions.nix). For entertainment all five are active, so the merged
  # set is identical to before.
  environment.etc = {
    "cloudunit/compose/immich/docker-compose.yml".source = ../compose/immich/docker-compose.yml;
    "cloudunit/compose/immich/.env.template".source = ../compose/immich/.env.template;
  }
    // lib.optionalAttrs (builtins.elem "jellyfin" config.keephaven.activeApps) {
      "cloudunit/compose/jellyfin/docker-compose.yml".source = ../compose/jellyfin/docker-compose.yml;
    }
    // lib.optionalAttrs (builtins.elem "navidrome" config.keephaven.activeApps) {
      "cloudunit/compose/navidrome/docker-compose.yml".source = ../compose/navidrome/docker-compose.yml;
    }
    // lib.optionalAttrs (builtins.elem "audiobookshelf" config.keephaven.activeApps) {
      "cloudunit/compose/audiobookshelf/docker-compose.yml".source = ../compose/audiobookshelf/docker-compose.yml;
    }
    // lib.optionalAttrs (builtins.elem "kavita" config.keephaven.activeApps) {
      "cloudunit/compose/kavita/docker-compose.yml".source = ../compose/kavita/docker-compose.yml;
    }
    // lib.optionalAttrs (builtins.elem "freshrss" config.keephaven.activeApps) {
      "cloudunit/compose/freshrss/docker-compose.yml".source = ../compose/freshrss/docker-compose.yml;
    };
  #   environment.etc."cloudunit/compose/vaultwarden/docker-compose.yml".source =
  #     ../compose/vaultwarden/docker-compose.yml;

  cloudunit.wrappers.appSet = "${appSet}/bin/cloudunit-app-set";

  systemd.services =
    (mkService { name = "immich"; description = "Cloud Unit - Immich photo service"; needsEnv = true; })
    // (mkBootstrap { name = "immich"; })
    // lib.optionalAttrs (builtins.elem "jellyfin" config.keephaven.activeApps)
       (mkService { name = "jellyfin"; description = "Cloud Unit - Jellyfin media server"; needsEnv = false; })
    // lib.optionalAttrs (builtins.elem "navidrome" config.keephaven.activeApps)
       (mkService { name = "navidrome"; description = "Cloud Unit - Navidrome music"; needsEnv = false; })
    // lib.optionalAttrs (builtins.elem "audiobookshelf" config.keephaven.activeApps)
       (mkService { name = "audiobookshelf"; description = "Cloud Unit - AudioBookshelf"; needsEnv = false; })
    // lib.optionalAttrs (builtins.elem "kavita" config.keephaven.activeApps)
       (mkService { name = "kavita"; description = "Cloud Unit - Kavita books"; needsEnv = false;
         # Offline pre-seed: copy the image's OWN bundled email templates into the
         # customizable config/templates dir before Kavita starts, copy-if-absent
         # (cp -n) so existing/user-edited templates are never clobbered. Kavita's
         # first-run MigrateEmailTemplates then finds them locally and skips its
         # synchronous GitHub download (which hangs for minutes on the offline
         # setup AP). Sourced from the image (the loaded KAVITA_IMAGE) via a
         # throwaway container, so it tracks whatever each image version bundles
         # rather than a host-side hardcoded copy. Runs every boot, idempotent,
         # best-effort (|| true) — if it ever fails, the scoped extra_hosts
         # blackhole in the compose file still fast-fails the download in ms.
         preUp = ''
           ${pkgs.docker}/bin/docker run --rm --entrypoint /bin/bash \
             -v ${dataDir}/kavita/config:/kavita/config "$KAVITA_IMAGE" \
             -c 'mkdir -p /kavita/config/templates && cp -n /kavita/EmailTemplates/*.html /kavita/config/templates/ 2>/dev/null || true' || true
         '';
       })
    // lib.optionalAttrs (builtins.elem "freshrss" config.keephaven.activeApps)
       (mkService { name = "freshrss"; description = "Cloud Unit - FreshRSS"; needsEnv = false; })
    // {
      # Ensure the Immich External Library drop-in dir exists and is owned by the
      # share user BEFORE the immich container bind-mounts it. If the dir is absent
      # when docker mounts it, docker auto-creates it as ROOT and the Samba "Photos"
      # share (force user = keephaven) can't write to it. Runs EVERY boot with no
      # first-boot gate, so it also fixes already-provisioned (OTA'd) boxes where
      # cloudunit-samba-bootstrap's mkShareDirs has already fired and won't re-run.
      # `before` only (not `requires`): a failure here must never block Immich itself.
      cloudunit-immich-external = {
        description = "Cloud Unit - ensure Immich external-library drop-in dir (keephaven-owned)";
        before = [ "cloudunit-immich.service" ];
        wantedBy = [ "multi-user.target" ];
        unitConfig = {
          RequiresMountsFor = dataDir;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p ${dataDir}/immich/external
          chown keephaven:keephaven ${dataDir}/immich/external
          chmod 0775 ${dataDir}/immich/external
        '';
      };
    };
  #     // (mkService { name = "vaultwarden"; description = "Cloud Unit - Vaultwarden password manager"; needsEnv = false; });
}
