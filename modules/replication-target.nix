# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# REPLICATION — PHASE 2, RECEIVER SIDE (box B, the backup target).
#
# Everything here is policy the SENDER CANNOT INFLUENCE (decisions.md #3): the
# receiving box owns retention and its own disk protection, exactly as it owns
# the no-delete rule. A compromised or buggy primary must not be able to talk
# this box out of any of it.
#
# Two jobs:
#   1. Keep the last N database dumps and drop older ones. Keep-last-N is a HARD
#      requirement, not an option: overwriting a single dump would let one bad
#      night (a corrupted DB faithfully dumped) destroy the only restore point.
#   2. Never let the replica fill the disk SILENTLY. A backup box that quietly
#      ran out of room is the same failure class as silent staleness — the
#      customer believes they are protected and are not.
#
# The cap is ENFORCED in the receiver's forced command (replication.nix), which
# refuses an incoming push when free space is below the floor, so a full disk
# becomes a loud error on the primary's staleness card rather than a wedged box.
# Reporting lives here.
# ============================================================================

let
  cfg = config.keephaven.replication;
  dataDir = "/var/lib/cloudunit";
  replDir = "${dataDir}/replication";
  landing = "${replDir}/landing";
  pairEnv = "${replDir}/pair.env";
  dumpDir = "${landing}/dump";

  # Retention. Three nightly dumps ~= three days of restore points; the media
  # files are kept in full (no-delete), so this bounds only the DB copies.
  keepDumps = 3;

  rotate = pkgs.writeShellScriptBin "cloudunit-replica-rotate" ''
    set -u
    co=${pkgs.coreutils}/bin
    # Path ONLY -- see immich-dump.nix: baking "-t tag" in here breaks
    # silently the moment someone quotes the expansion.
    LOG=${pkgs.util-linux}/bin/logger
    [ -d ${dumpDir} ] || exit 0
    cd ${dumpDir} || exit 0

    # 1. An EMPTY dump is not a restore point. Remove it loudly so it can never
    #    occupy a keep slot ahead of a real dump. (rsync stages under a dot-file
    #    name and renames, so an in-flight transfer never matches this glob.)
    ${pkgs.findutils}/bin/find . -maxdepth 1 -type f -name 'immich-*.sql.zst' -empty -printf '%f\n' 2>/dev/null \
      | while read -r f; do
          $co/rm -f "$f" "''${f%.sql.zst}.meta"
          "$LOG" -t cloudunit-replication "rotate: removed EMPTY dump $f (not a restore point)"
        done

    # 2. Keep the newest N by the timestamp in the FILENAME, not by mtime.
    #    Sorting by mtime was a real defect, caught by the Phase 2 gate on f3dy4:
    #    three zero-byte test files created later had NEWER mtimes than three
    #    genuine dumps, so rotation kept the fakes and deleted every real backup.
    #    The filename carries the canonical UTC stamp (it agrees with .meta's
    #    taken_utc) and, unlike mtime, cannot be reordered by a copy, a restore,
    #    a support engineer poking around, or a stray touch. Sorting the ISO-8601
    #    name lexicographically IS chronological order.
    ${pkgs.findutils}/bin/find . -maxdepth 1 -type f -name 'immich-*.sql.zst' -printf '%f\n' 2>/dev/null \
      | $co/sort -r | $co/tail -n +${toString (keepDumps + 1)} \
      | while read -r f; do
          $co/rm -f "$f" "''${f%.sql.zst}.meta"
          "$LOG" -t cloudunit-replication "rotate: removed $f"
        done
  '';

  # Read-only status for the Settings card (and, in Phase 3, the backup
  # dashboard). No secrets. Answers the only two questions the owner of a backup
  # box has: is it actually receiving, and is there room for more?
  # Runs via sudo because pair.env is root:600 (CLAUDE.md: settings can never
  # read it directly).
  targetStatus = pkgs.writeShellScriptBin "cloudunit-replica-target-status" ''
    set -u
    co=${pkgs.coreutils}/bin
    if [ ! -f ${pairEnv} ]; then echo "unpaired"; exit 0; fi
    ROLE="$(${pkgs.gawk}/bin/awk -F= '/^ROLE=/{print $2; exit}' ${pairEnv})"
    if [ "''${ROLE:-}" != "backup-target" ]; then echo "not-a-target"; exit 0; fi

    DUMPS=0; NEWEST=""; SRCVER=""
    if [ -d ${dumpDir} ]; then
      DUMPS="$(${pkgs.findutils}/bin/find ${dumpDir} -maxdepth 1 -name 'immich-*.sql.zst' 2>/dev/null | $co/wc -l)"
      # Same ordering as rotation (filename, not mtime) so the card can never
      # name a different dump than the one rotation is protecting.
      NEWESTF="${dumpDir}/$(${pkgs.findutils}/bin/find ${dumpDir} -maxdepth 1 -type f -name 'immich-*.sql.zst' -printf '%f\n' 2>/dev/null \
                 | $co/sort -r | $co/head -n1)"
      [ -f "$NEWESTF" ] || NEWESTF=""
      if [ -n "''${NEWESTF:-}" ]; then
        NEWEST="$($co/date -u -r "$NEWESTF" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")"
        SRCVER="$(${pkgs.gawk}/bin/awk -F= '/^source_version=/{print $2; exit}' "''${NEWESTF%.sql.zst}.meta" 2>/dev/null || echo "")"
      fi
    fi
    USED="$($co/du -sh ${landing} 2>/dev/null | $co/cut -f1)"
    FREE="$($co/df -Ph ${landing} 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2{print $4}')"
    PCT="$($co/df -Ph ${landing} 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2{print $5}')"
    PEER="$(${pkgs.gawk}/bin/awk -F= '/^PEER_SUFFIX=/{print $2; exit}' ${pairEnv})"
    $co/printf 'target dumps=%s newest=%s source_version=%s used=%s free=%s diskpct=%s peer=%s\n' \
      "''${DUMPS:-0}" "''${NEWEST:-none}" "''${SRCVER:-unknown}" "''${USED:-0}" "''${FREE:-unknown}" "''${PCT:-unknown}" "''${PEER:-unknown}"
  '';
in
{
  # Defined UNCONDITIONALLY (a store path costs nothing) so settings.nix can
  # always reference it without an eval hazard; the sudo grant and the UI are
  # what the feature flag gates.

  # An explicit `config` means every attribute must live inside it, so the
  # always-present wrapper registration is merged in beside the gated body.
  config = lib.mkMerge [
    { cloudunit.wrappers.replicaTargetStatus = "${targetStatus}/bin/cloudunit-replica-target-status"; }

    (lib.mkIf cfg.enable {
    environment.systemPackages = [ rotate targetStatus ];

    # Daily rotation. Independent of when pushes arrive: the sender cannot
    # trigger, delay, or skip it.
    systemd.services.cloudunit-replica-rotate = {
      description = "Cloud Unit - keep only the last few received database dumps";
      unitConfig = {
        RequiresMountsFor = dataDir;
        ConditionPathExists = pairEnv;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${rotate}/bin/cloudunit-replica-rotate";
      };
    };

    systemd.timers.cloudunit-replica-rotate = {
      description = "Cloud Unit - daily dump rotation on the backup box";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "05:30";
        RandomizedDelaySec = "30m";
        Persistent = true;
      };
    };
    })
  ];
}
