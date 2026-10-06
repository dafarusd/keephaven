# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# REPLICATION — PHASE 2, SENDER SIDE (box A, the primary).
#
# Nightly: dump the Immich database, then push the replica set to the paired
# box over the Phase 1 trust channel. One-way, A -> B, and A NEVER blocks on B.
#
# The replica set (decisions.md 2026-08-05 #5) is deliberately explicit:
#   the five Samba shares          -- Movies / Music / Audiobooks / Books / Photos
#   + immich/library               -- the MANAGED upload library (phone backups).
#                                     NOT a Samba share; omitting it would restore
#                                     a database referencing missing originals,
#                                     which is exactly the artefact the .26 bench
#                                     hit (decisions.md 2026-07-27).
#   + the nightly pg_dump          -- Immich's DB; the media files alone are not a
#                                     restorable library.
#
# ORDER: dump FIRST, files second. The worst inconsistency then is files the DB
# doesn't know about (harmless, picked up next cycle) rather than DB rows
# pointing at files that were never copied.
#
# NO-DELETE is enforced on the RECEIVER (replication.nix refuses every --delete*
# form); the sender simply never asks. That is deliberate — the sender is never
# trusted with the safety property (decisions.md #3). Losing a deletion to the
# replica is a cost we accept to keep the two copies independent enough that a
# mass-delete or ransomware event on A cannot follow the wire to B.
#
# INERTNESS — this must be a no-op on any box that is not deliberately paired:
#   1. the whole module is gated on keephaven.replication.enable (false on
#      customer images for the entire arc), and
#   2. the timer/service additionally require the pair record to exist.
# Belt and braces, per decisions.md 2026-08-06.
# ============================================================================

let
  cfg = config.keephaven.replication;
  dataDir = "/var/lib/cloudunit";
  replDir = "${dataDir}/replication";
  pairEnv = "${replDir}/pair.env";
  keyFile = "${replDir}/pair_key";
  # Staging dir name is load-bearing: the sync push splits the rsync source
  # path here (-R), so dumps land under "dump/" on the receiver.
  outDir = "${replDir}/dump";
  statusFile = "${replDir}/sync-status.json";
  # What this box remembers about the backup box's SSH host key. On the data
  # partition (root's own ~/.ssh is on the system partition and is wiped by
  # every update), inside the pairing folder so unpairing and a factory reset
  # take it too.
  knownHosts = "${replDir}/known_hosts";
  # The paired box's Tailscale node key, as "<node id> <node key>", written by
  # the sender after a good push. See peer_is_paired_node below.
  nodeKeyFile = "${replDir}/peer_nodekey";
  immichEnv = "${dataDir}/immich/.env";
  versionFile = "/etc/cloudunit/update/version";

  # Keep-last-N of the LOCAL staging dumps. The authoritative retention lives on
  # the receiving box (it holds the copies that matter); this is just so the
  # primary doesn't accumulate dumps on p4.
  localKeep = 2;

  # The dump producer now lives in modules/immich-dump.nix, OUTSIDE the
  # replication feature flag: the update arc's pre-update dump needs it on every
  # box, including customer boxes with replication switched off. This module just
  # points it at the replication staging directory.
  dumpBin = config.cloudunit.wrappers.immichDump;

  # ---- The nightly sync ------------------------------------------------------
  # Guarded, locked, timeout-bounded, and it NEVER blocks or fails the box:
  # every outcome is recorded in sync-status.json and the unit exits 0, because
  # "the backup box is unreachable" is a normal condition (it lives in someone
  # else's house) and must not show up as a failed unit in the health report.
  # Silence is handled by the staleness card reading that status, not by systemd.
  #
  # rsync flag discipline (matters): the receiver refuses every LONG option, so
  # the sender must use short flags only. -a (archive) and -R (relative) travel
  # as part of rsync's short server cluster; --timeout / --numeric-ids / --delete
  # would appear verbatim on the server command line and be refused. Bounding is
  # done with ssh ConnectTimeout + systemd TimeoutStartSec instead.
  #
  # -R with a "/./" split point is what builds the tree on the receiver:
  #   <dataDir>/./immich/library      -> landing/immich/library
  #   <replDir>/./dump/immich-*.zst   -> landing/dump/immich-*.zst
  sync = pkgs.writeShellScriptBin "cloudunit-replica-sync" ''
    set -u
    co=${pkgs.coreutils}/bin
    LOGGER=${pkgs.util-linux}/bin/logger
    START="$($co/date -u +%s)"

    # status <state> <message>  -- atomic; the card reads this, never our exit code
    status() {
      NOW="$($co/date -u '+%Y-%m-%dT%H:%M:%SZ')"
      LAST_OK="$(${pkgs.gnugrep}/bin/grep -o '"last_success":"[^"]*"' ${statusFile} 2>/dev/null | ${pkgs.gnused}/bin/sed 's/.*:"//;s/"//' || true)"
      [ "$1" = "ok" ] && LAST_OK="$NOW"
      TMP="$($co/mktemp ${replDir}/.sync.XXXXXX)"
      $co/printf '{"state":"%s","message":"%s","last_attempt":"%s","last_success":"%s","duration_s":%s,"peer":"%s"}\n' \
        "$1" "$2" "$NOW" "''${LAST_OK:-}" "$(( $($co/date -u +%s) - START ))" "''${PEER:-}" > "$TMP"
      $co/chmod 644 "$TMP"
      $co/mv -f "$TMP" ${statusFile}
    }

    # ---- guards: a no-op unless this box is a primary with a usable pairing ----
    [ -f ${pairEnv} ] || exit 0
    ROLE="$(${pkgs.gawk}/bin/awk -F= '/^ROLE=/{print $2; exit}' ${pairEnv})"
    PEER="$(${pkgs.gawk}/bin/awk -F= '/^PEER_SUFFIX=/{print $2; exit}' ${pairEnv})"
    NODEID="$(${pkgs.gawk}/bin/awk -F= '/^PEER_NODEID=/{print $2; exit}' ${pairEnv})"
    [ "''${ROLE:-}" = "primary" ] || exit 0
    if [ ! -s ${keyFile} ]; then
      status broken "pairing key missing - re-pair the two Keephavens"
      exit 0
    fi
    if [ -z "''${NODEID:-}" ]; then
      status pending "waiting for both Keephavens to see each other - turn on Remote access on both"
      exit 0
    fi

    # ---- resolve the peer's CURRENT tailnet address from its durable node id ----
    # Never a stored IP or hostname: both churn across factory resets.
    IP="$($co/timeout 15 ${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null \
      | ${pkgs.jq}/bin/jq -r --arg id "$NODEID" '.Peer[]? | select(.ID==$id) | .TailscaleIPs[0] // empty' \
      | ${pkgs.coreutils}/bin/head -n1)"
    if [ -z "$IP" ]; then
      status unreachable "couldn't find the backup Keephaven on your private network"
      exit 0
    fi

    # The host key is filed under the peer's durable Tailscale node id, not its
    # address (addresses churn, see above).
    ALIAS="keephaven-peer-$(printf '%s' "$NODEID" | ${pkgs.coreutils}/bin/tr -cd 'A-Za-z0-9')"
    SSH="${pkgs.openssh}/bin/ssh -i ${keyFile} -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${knownHosts} -o HostKeyAlias=$ALIAS -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=40"

    # ---- who we are about to send to, and when a changed host key is accepted ----
    # A box's host key used to live on its system partition and changed at every
    # update (base.nix keeps it on the data partition now). The first update TO
    # that fix still changes it once more, and pairs in the field were already
    # stuck on "Host key verification failed" with nothing the owner could
    # press. So the sender has to get itself out, without becoming a sender that
    # accepts whatever answers.
    #
    # Two things identify the backup box, kept apart on purpose: its SSH host
    # key (known_hosts) and its Tailscale node key (${nodeKeyFile}). Each one
    # vouches for a change in the other; both unknown or both changed is refused:
    #   host key same, node key new  -> a re-login on the backup box. The push
    #                                   passes the host key check, so the new
    #                                   node key is recorded.
    #   host key new, node key same  -> an update on the backup box. Re-learn.
    #   both new, or node key new and
    #   no host key on file          -> not provably the same machine. Refuse;
    #                                   the owner pairs again.
    # The node id alone is not enough: whoever runs the coordination server
    # could hand that id to another machine, which would carry another node key.
    # A pair made before this existed has no node key on file. It is taken on
    # the first good push, and until then the node id decides (as it always did
    # on first contact).
    AUDIT=${replDir}/host-key-changes.log
    audit() {   # journal AND a file on the data partition: a box's journal starts over at every update
      "$LOGGER" -t cloudunit-replication "sync: $*"
      echo "$($co/date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$AUDIT" 2>/dev/null || true
    }
    # The address has to be one Tailscale carries. tailscaled can still answer
    # questions while it is not routing; a 100.x address would then leave by the
    # LAN, to whatever answers there.
    via_tailscale() {
      ${pkgs.iproute2}/bin/ip -o route get "$IP" 2>/dev/null | ${pkgs.gnugrep}/bin/grep -q ' dev tailscale0 '
    }
    RELEARNED=0
    PINNED_KEY=""
    if [ -s ${nodeKeyFile} ]; then
      read -r PIN_ID PIN_KEY < ${nodeKeyFile} || true
      [ "''${PIN_ID:-}" = "$NODEID" ] && PINNED_KEY="''${PIN_KEY:-}"
    fi
    HAD_ENTRY=0
    ${pkgs.openssh}/bin/ssh-keygen -F "$ALIAS" -f ${knownHosts} >/dev/null 2>&1 && HAD_ENTRY=1
    SNAP_ID=""; SNAP_KEY=""
    # Asked ONCE, before anything is sent. Every later decision in this run
    # uses this answer, not a fresh one.
    preflight() {   # 0 = go. Otherwise CSTATE/CMSG say why not, and nothing was sent.
      if ! via_tailscale; then
        CSTATE=unreachable; CMSG="couldn't find the backup Keephaven on your private network"; return 1
      fi
      WJ="$($co/timeout 15 ${pkgs.tailscale}/bin/tailscale whois --json "$IP" 2>/dev/null || true)"
      SNAP_ID="$(printf '%s' "$WJ" | ${pkgs.jq}/bin/jq -r '.Node.StableID // empty' 2>/dev/null || true)"
      SNAP_KEY="$(printf '%s' "$WJ" | ${pkgs.jq}/bin/jq -r '.Node.Key // empty' 2>/dev/null || true)"
      if [ -z "$SNAP_ID" ]; then
        # No answer is not a verdict. Tonight's run is skipped, nobody re-pairs.
        CSTATE=unreachable; CMSG="couldn't find the backup Keephaven on your private network"; return 1
      fi
      if [ "$SNAP_ID" != "$NODEID" ]; then
        audit "refused: $IP answers as Tailscale node $SNAP_ID, the paired node is $NODEID"
        CSTATE=rejected; CMSG="couldn't confirm the other box is your backup Keephaven - pair the two boxes again"; return 1
      fi
      if [ -n "$PINNED_KEY" ] && [ "$SNAP_KEY" != "$PINNED_KEY" ] && [ "$HAD_ENTRY" != 1 ]; then
        audit "refused: the backup box's Tailscale node key changed and there is no host key on file to vouch for it"
        CSTATE=rejected; CMSG="couldn't confirm the other box is your backup Keephaven - pair the two boxes again"; return 1
      fi
      return 0
    }
    may_relearn() {   # a changed host key is accepted only for the paired node, with the node key we know
      via_tailscale || return 1
      [ -n "$SNAP_ID" ] && [ "$SNAP_ID" = "$NODEID" ] || return 1
      if [ -n "$PINNED_KEY" ]; then
        [ -n "$SNAP_KEY" ] && [ "$SNAP_KEY" = "$PINNED_KEY" ] || return 1
      fi
      return 0
    }
    record_node_key() {   # called once, right after the first push of a run has succeeded
      [ -n "$SNAP_KEY" ] || return 0
      [ "$SNAP_KEY" = "$PINNED_KEY" ] && return 0
      # A key already on file is replaced only when the host key vouched for the
      # machine: it was on file before this run and was not re-learned in it.
      if [ -n "$PINNED_KEY" ]; then
        [ "$HAD_ENTRY" = 1 ] && [ "$RELEARNED" = 0 ] || return 0
      fi
      TMPK="$($co/mktemp ${replDir}/.nodekey.XXXXXX)" || return 0
      if $co/printf '%s %s\n' "$NODEID" "$SNAP_KEY" > "$TMPK" && $co/chmod 600 "$TMPK" && $co/mv -f "$TMPK" ${nodeKeyFile}; then
        if [ -n "$PINNED_KEY" ]; then
          audit "the backup box's Tailscale node key changed (same host key); recorded the new one"
        else
          audit "recorded the backup box's Tailscale node key"
        fi
        PINNED_KEY="$SNAP_KEY"
      else
        $co/rm -f "$TMPK"
        "$LOGGER" -t cloudunit-replication "sync: could not record the backup box's Tailscale node key"
      fi
    }
    push() {   # push <source>  -> OUT holds the transcript; returns rsync's verdict
      OUT="$(${pkgs.rsync}/bin/rsync -a -R -e "$SSH" "$1" kh-replica@"$IP":. 2>&1)" && return 0
      case "$OUT" in
        *"Host key verification failed"*)
          [ "$RELEARNED" = 0 ] || return 1
          if ! may_relearn; then
            audit "refused: the backup box's host key changed and it could not be confirmed as the paired node (node key differs, or the address is not on Tailscale)"
            return 1
          fi
          RELEARNED=1
          ${pkgs.openssh}/bin/ssh-keygen -R "$ALIAS" -f ${knownHosts} >/dev/null 2>&1 || true
          if OUT="$(${pkgs.rsync}/bin/rsync -a -R -e "$SSH" "$1" kh-replica@"$IP":. 2>&1)"; then
            audit "the backup box's host key changed; re-learned it (Tailscale node $NODEID at $IP, node key unchanged or first seen)"
            return 0
          fi
          audit "the backup box's host key changed; the old one was forgotten but the retry failed, nothing learned yet"
          ;;
      esac
      return 1
    }

    if ! preflight; then
      status "$CSTATE" "$CMSG"
      exit 0
    fi

    # ---- 1. DUMP FIRST (see header) ----
    if ! DUMPOUT="$(${dumpBin} ${outDir} ${toString localKeep} 2>&1)"; then
      status error "couldn't prepare the photo database backup"
      "$LOGGER" -t cloudunit-replication "sync: dump failed: $DUMPOUT"
      exit 0
    fi

    # Classify a failed push from the transcript. The RECEIVER states its reason
    # on stderr ("keephaven-replication: refused: <why>") and ssh passes it
    # through; discarding it and printing one generic error made "your backup box
    # is FULL" byte-identical to "your backup box is UNPLUGGED" (Phase 2 gate
    # G8). Those need OPPOSITE actions from the owner, so the reason has to
    # survive the trip.
    classify() {
      CREASON="$(printf '%s' "$1" | ${pkgs.gnused}/bin/sed -n 's/.*keephaven-replication: refused: //p' | ${pkgs.coreutils}/bin/head -n1)"
      case "$CREASON" in
        "backup storage is full")
          CSTATE=full
          CMSG="your backup Keephaven is out of space - free some room on it, then back up again"
          ;;
        "")
          # No receiver verdict reached us: we never got far enough to be
          # refused, so this is a transport problem, not a policy one.
          case "$1" in
            *"Host key verification failed"*)
              # Only reached when re-learning was refused or did not help.
              CSTATE=rejected
              CMSG="couldn't confirm the other box is your backup Keephaven - pair the two boxes again"
              ;;
            *"Permission denied"*|*publickey*)
              CSTATE=rejected
              CMSG="your backup Keephaven refused the connection - the two boxes may need pairing again"
              ;;
            *"No route to host"*|*"Connection refused"*|*"Connection timed out"*|*"Network is unreachable"*|*"Connection closed"*|*"Connection reset"*|*"broken pipe"*)
              CSTATE=unreachable
              CMSG="couldn't reach your backup Keephaven - check it's powered on and connected"
              ;;
            *)
              CSTATE=error
              CMSG="couldn't send the backup to your other Keephaven"
              ;;
          esac
          ;;
        *)
          CSTATE=rejected
          CMSG="your backup Keephaven refused the transfer: $CREASON"
          ;;
      esac
      # The full transcript goes to the journal for support even though only the
      # plain-language line reaches the owner.
      "$LOGGER" -t cloudunit-replication "sync: push failed [$CSTATE]: $(printf '%s' "$1" | ${pkgs.coreutils}/bin/tail -n 3 | ${pkgs.coreutils}/bin/tr '\n' ' ')"
    }

    # ---- 2. push the dump, then the media. Short flags ONLY. ----
    if ! push ${replDir}/./dump; then
      classify "$OUT"
      status "$CSTATE" "$CMSG"
      exit 0
    fi
    record_node_key

    # APP PICKER: this box's picks as ONE snapshot file, rewritten every run, so a
    # backup box that takes over turns on the same apps (promote.nix phase 3b).
    # One file, not the markers folder: the receiver refuses --delete, so a folder
    # would keep a marker the owner later removed. Sent first, it is a few bytes.
    : > ${dataDir}/apps-off.list.tmp
    for a in ${lib.concatStringsSep " " config.keephaven.pickableApps}; do
      if [ -e "${config.keephaven.appsDir}/$a.off" ]; then
        echo "$a" >> ${dataDir}/apps-off.list.tmp
      fi
    done
    ${pkgs.coreutils}/bin/mv -f ${dataDir}/apps-off.list.tmp ${dataDir}/apps-off.list

    FAILED=""
    FSTATE=""
    FMSG=""
    for d in apps-off.list immich/library immich/external jellyfin/media navidrome/media \
             audiobookshelf/media kavita/media; do
      [ -e "${dataDir}/$d" ] || continue
      if ! push "${dataDir}/./$d"; then
        FAILED="$FAILED $d"
        # Keep the FIRST classification: it is the one that explains the run.
        if [ -z "$FSTATE" ]; then
          classify "$OUT"
          FSTATE="$CSTATE"
          FMSG="$CMSG"
        fi
      fi
    done

    if [ -n "$FAILED" ]; then
      status "$FSTATE" "$FMSG"
      "$LOGGER" -t cloudunit-replication "sync: partial failure:$FAILED"
      exit 0
    fi

    status ok "backup sent"
    "$LOGGER" -t cloudunit-replication "sync ok -> keephaven-$PEER ($IP)"
    exit 0
  '';
  # Owner-initiated "Back up now". --no-block so the Settings request returns
  # instantly: a first seed can run for hours and must never hold the handler.
  # Starting an already-running unit is a harmless no-op, so a double-click
  # cannot stack transfers.
  syncNow = pkgs.writeShellScriptBin "cloudunit-replica-sync-now" ''
    set -u
    ${pkgs.systemd}/bin/systemctl start --no-block cloudunit-replica-sync.service \
      || { echo "could not start the backup" >&2; exit 1; }
    echo "OK: backup started"
  '';
in
{
  # Defined UNCONDITIONALLY (just a store path) so settings.nix can always
  # reference it; the sudo grant and the UI are what the feature flag gates.

  # An explicit `config` means every attribute must live inside it, so the
  # always-present wrapper registration is merged in beside the gated body.
  config = lib.mkMerge [
    { cloudunit.wrappers.replicaSyncNow = "${syncNow}/bin/cloudunit-replica-sync-now"; }

    (lib.mkIf cfg.enable {
    environment.systemPackages = [ sync syncNow ];

    # Dump-only oneshot. Not wantedBy anything: Phase 2's sync service calls the
    # binary directly, and a future pre-update hook can pull this unit in.
    systemd.services.cloudunit-replica-dump = {
      description = "Cloud Unit - dump the Immich database for replication";
      unitConfig = {
        RequiresMountsFor = dataDir;
        # Inert unless this box is deliberately paired (belt-and-braces with the
        # feature flag above).
        ConditionPathExists = pairEnv;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${dumpBin} ${outDir} ${toString localKeep}";
      };
    };

    # The nightly push. Never Requires= the network: an offline night is a normal
    # outcome recorded in the status file, not a failure.
    systemd.services.cloudunit-replica-sync = {
      description = "Cloud Unit - send the nightly backup to the paired Keephaven";
      unitConfig = {
        RequiresMountsFor = dataDir;
        ConditionPathExists = pairEnv;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${sync}/bin/cloudunit-replica-sync";
        # Single instance: a long first seed must never overlap the next night.
        TimeoutStartSec = "12h";
      };
    };

    systemd.timers.cloudunit-replica-sync = {
      description = "Cloud Unit - nightly backup to the paired Keephaven";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "03:00";
        RandomizedDelaySec = "45m";
        # A box that was off overnight catches up rather than skipping a night.
        Persistent = true;
      };
    };
    })
  ];
}
