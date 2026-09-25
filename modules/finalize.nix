{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  setupFlag = "${dataDir}/.setup-complete";
  sysctl = "${pkgs.systemd}/bin/systemctl";
  provisioners = [
    "cloudunit-jellyfin-provision"
    "cloudunit-navidrome-provision"
    "cloudunit-freshrss-provision"
    "cloudunit-kavita-provision"
    "cloudunit-audiobookshelf-provision"
    "cloudunit-immich-provision"
  ];
  startProvisioners = lib.concatMapStringsSep "\n"
    (s: "        ${sysctl} start --no-block ${s}.service || true") provisioners;
in
{
  systemd.services.cloudunit-finalize = {
    description = "Cloud Unit - finalize setup (wizard -> dashboard, no reboot)";
    after = [ "network.target" ];
    unitConfig.RequiresMountsFor = dataDir;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cloudunit-finalize" ''
        set -uo pipefail
        ${sysctl} stop cloudunit-wizard.service || true
        ${sysctl} start cloudunit-dashboard.service || true
        # BACKUP BOX (Phase 3): its six services stay stopped, so provisioning
        # them is pointless -- the provisioners would wait on health checks for
        # containers that are never coming up, and the box would sit "setting
        # up" forever. The dashboard still starts; it serves the backup view.
        # Absent marker = the original path, unchanged, line for line.
        if [ -e ${dataDir}/.backup-mode ]; then
          echo "cloudunit finalize: backup box - dashboard up, provisioners skipped"
          exit 0
        fi
${startProvisioners}
        echo "cloudunit finalize complete: dashboard up, provisioners started"
      '';
    };
  };
}
