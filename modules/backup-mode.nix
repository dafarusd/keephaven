# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# BACKUP MODE — PHASE 3. Turns a Keephaven into a dedicated backup box.
#
# A backup box holds the replica and nothing else: its six services stay STOPPED,
# its dashboard shows backup status instead of tiles, and it keeps itself current
# without anyone touching it. Everything keys off ONE marker on p4,
# `.backup-mode`, so the state survives reboots and reflashes and can be undone
# — Phase 4's promotion clears it, which is why enable/disable are symmetric
# wrappers rather than a one-way switch.
#
# WHAT IT DOES NOT DO: it does not delete the box's own pre-existing data.
# Services stop; their data sits on p4 untouched. Deleting it would be a surprise
# the owner never asked for, and the role-reversal guard (replication.nix)
# already blocks the genuinely dangerous case — a box that has served as a MAIN
# Keephaven cannot silently become someone's backup. [Dafarus, 2026-08-09]
#
# THE AUTO-UPDATE EXCEPTION (decisions.md 2026-08-06, scoped exception to U0):
# U0 says the box never installs without the owner clicking, because a surprise
# restart on a box in daily use is unacceptable. A backup-mode box inverts every
# premise: no interactive user, all six services already stopped so there is
# nothing to interrupt, the rollback arc proven autonomous, and staleness is
# itself the data-safety threat — a backup box that lags is BLOCKED from
# restoring by the Phase 4 version interlock. So here, and ONLY here, the box
# stages and applies on its own.
#
# Note it must do BOTH: on a primary a human clicks "Install now" to stage and
# again to apply. Nobody clicks on a backup box, so an apply-only exception would
# never have anything to apply.
# ============================================================================

let
  cfg = config.keephaven.replication;
  dataDir = "/var/lib/cloudunit";
  backupFlag = "${dataDir}/.backup-mode";
  statusFile = "${dataDir}/update/status.json";
  replUser = "kh-replica";

  # The edition's apps (edition switch, modules/editions.nix). For entertainment
  # this is the same six in the same order, so the rendered unit is unchanged.
  services = config.keephaven.activeApps;
  stopAll = lib.concatMapStringsSep "\n    "
    (s: "$SYSTEMCTL stop cloudunit-${s}.service 2>/dev/null || true") services;
  startAll = lib.concatMapStringsSep "\n    "
    (s: "$SYSTEMCTL start --no-block cloudunit-${s}.service 2>/dev/null || true") services;

  enable = pkgs.writeShellScriptBin "cloudunit-backup-mode-enable" ''
    set -u
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    LOGGER=${pkgs.util-linux}/bin/logger
    ${pkgs.coreutils}/bin/printf 'backup mode\n' > ${backupFlag} || {
      "$LOGGER" -t cloudunit-backup-mode "FAILED to write ${backupFlag}"
      echo "could not switch to backup mode" >&2
      exit 1
    }
    ${pkgs.coreutils}/bin/chmod 644 ${backupFlag}
    # Stop the services NOW rather than at the next boot: the owner just made a
    # choice and should see it take effect. The units also carry a
    # ConditionPathExists on this marker (services.nix), which is what keeps them
    # stopped across every subsequent boot.
    ${stopAll}
    "$LOGGER" -t cloudunit-backup-mode "backup mode ON (six services stopped; existing data left untouched)"
    echo "OK: backup mode on"
  '';

  disable = pkgs.writeShellScriptBin "cloudunit-backup-mode-disable" ''
    set -u
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    LOGGER=${pkgs.util-linux}/bin/logger
    ${pkgs.coreutils}/bin/rm -f ${backupFlag}
    ${startAll}
    "$LOGGER" -t cloudunit-backup-mode "backup mode OFF (services starting)"
    echo "OK: backup mode off"
  '';

  status = pkgs.writeShellScriptBin "cloudunit-backup-mode-status" ''
    set -u
    if [ -f ${backupFlag} ]; then echo "on"; else echo "off"; fi
  '';

  # The unattended updater. Runs only on a backup-mode box, does both halves
  # (stage, then apply), and refuses to act while a replication transfer is in
  # flight so a reboot never lands mid-receive.
  autoUpdate = pkgs.writeShellScriptBin "cloudunit-backup-auto-update" ''
    set -u
    set -o pipefail
    LOGGER=${pkgs.util-linux}/bin/logger
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl

    # log() writes BOTH ways, deliberately, because this unit runs with nobody
    # watching and "invisible" is its worst failure mode:
    #   echo   -> systemd captures stdout, so the line appears under
    #             `journalctl -u cloudunit-backup-auto-update` AND under
    #             `-t cloudunit-backup-auto-update` (the identifier is the
    #             binary's name). Those are the two searches anyone actually
    #             types, and they are what the Phase 3 gate tried and found
    #             empty: every message was tagged cloudunit-backup-mode, which
    #             matches neither the unit nor the binary.
    #   logger -> keeps the message in the cross-cutting backup-mode tag too, so
    #             enable/disable (which run as sudo children of settings, where
    #             stdout is captured and discarded) and this unit still read as
    #             one story.
    log() {
      echo "$*"
      "$LOGGER" -t cloudunit-backup-mode "$*"
    }

    [ -f ${backupFlag} ] || exit 0

    # An incoming replica push shows up as an rsync running AS the receiving
    # account. Rebooting mid-transfer would leave a partial tree and cost the
    # primary a full retry, so defer -- the timer comes back around.
    if ${pkgs.procps}/bin/pgrep -u ${replUser} -x rsync >/dev/null 2>&1; then
      log "auto-update: a backup transfer is in flight; deferring"
      exit 0
    fi

    STATE="$(${pkgs.jq}/bin/jq -r '.state // ""' ${statusFile} 2>/dev/null || echo "")"
    case "$STATE" in
      update-available)
        log "auto-update: update available; staging (unattended - backup box)"
        $SYSTEMCTL start --no-block cloudunit-update-stage.service \
          || log "auto-update: FAILED to start staging"
        ;;
      staged-ok)
        log "auto-update: verified update staged; applying (unattended - backup box)"
        $SYSTEMCTL start --no-block cloudunit-update-apply.service \
          || log "auto-update: FAILED to start apply"
        ;;
      held)
        # Should not happen on a backup box (no Immich running => the pre-update
        # dump returns "nothing to protect" and the stage proceeds), so if it
        # does, say so rather than looping silently.
        log "auto-update: update HELD on a backup box - unexpected, leaving it"
        ;;
      *) : ;;
    esac
  '';
in
{
  config = lib.mkMerge [
    {
      cloudunit.wrappers.backupModeEnable = "${enable}/bin/cloudunit-backup-mode-enable";
      cloudunit.wrappers.backupModeDisable = "${disable}/bin/cloudunit-backup-mode-disable";
      cloudunit.wrappers.backupModeStatus = "${status}/bin/cloudunit-backup-mode-status";
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ enable disable status autoUpdate ];

      systemd.services.cloudunit-backup-auto-update = {
        description = "Cloud Unit - keep a backup box current without anyone touching it";
        unitConfig = {
          RequiresMountsFor = dataDir;
          # Doubly inert: the feature flag above, and this marker. On any box
          # that is not a backup box the unit never runs at all.
          ConditionPathExists = backupFlag;
        };
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${autoUpdate}/bin/cloudunit-backup-auto-update";
        };
      };

      systemd.timers.cloudunit-backup-auto-update = {
        description = "Cloud Unit - backup-box unattended update check";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "15min";
          OnUnitActiveSec = "1h";
          RandomizedDelaySec = "10m";
          Persistent = true;
        };
      };
    })
  ];
}
