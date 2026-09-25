{ config, pkgs, lib, ... }:
let
  composeDir = "/etc/cloudunit/compose";
  dataDir = "/var/lib/cloudunit";

  mkService = { name, description, needsEnv ? false, preUp ? "" }:
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
          ConditionPathExists = "!${dataDir}/.backup-mode";
        } // lib.optionalAttrs needsEnv {
          # NOTE both conditions must hold; systemd ANDs repeated
          # ConditionPathExists, so this narrows rather than replaces.
          ConditionPathExists = [ "!${dataDir}/.backup-mode" "${dataDir}/${name}/.env" ];
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
  environment.etc."cloudunit/compose/immich/docker-compose.yml".source =
    ../compose/immich/docker-compose.yml;
  environment.etc."cloudunit/compose/immich/.env.template".source =
    ../compose/immich/.env.template;
  environment.etc."cloudunit/compose/jellyfin/docker-compose.yml".source =
    ../compose/jellyfin/docker-compose.yml;
  environment.etc."cloudunit/compose/navidrome/docker-compose.yml".source =
    ../compose/navidrome/docker-compose.yml;
  environment.etc."cloudunit/compose/audiobookshelf/docker-compose.yml".source =
    ../compose/audiobookshelf/docker-compose.yml;
  environment.etc."cloudunit/compose/kavita/docker-compose.yml".source =
    ../compose/kavita/docker-compose.yml;
  environment.etc."cloudunit/compose/freshrss/docker-compose.yml".source =
    ../compose/freshrss/docker-compose.yml;
  #   environment.etc."cloudunit/compose/vaultwarden/docker-compose.yml".source =
  #     ../compose/vaultwarden/docker-compose.yml;

  systemd.services =
    (mkService { name = "immich"; description = "Cloud Unit - Immich photo service"; needsEnv = true; })
    // (mkBootstrap { name = "immich"; })
    // (mkService { name = "jellyfin"; description = "Cloud Unit - Jellyfin media server"; needsEnv = false; })
    // (mkService { name = "navidrome"; description = "Cloud Unit - Navidrome music"; needsEnv = false; })
    // (mkService { name = "audiobookshelf"; description = "Cloud Unit - AudioBookshelf"; needsEnv = false; })
    // (mkService { name = "kavita"; description = "Cloud Unit - Kavita books"; needsEnv = false;
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
    // (mkService { name = "freshrss"; description = "Cloud Unit - FreshRSS"; needsEnv = false; })
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
