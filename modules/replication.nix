# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# REPLICATION (Phase 1: pairing only) — the trust layer between two Keephavens
# the SAME owner pairs for box-to-box backup (box A primary -> box B target).
#
# Shape of the trust (decisions.md 2026-08-05 #6):
#   - A per-pair ed25519 keypair is minted AT PAIRING TIME on box A's p4. It is
#     never baked into the image and never known to the vendor — pairing keys are
#     per-pair, so there is nothing fleet-wide to steal (same rationale as the
#     keyless-prod ship: a baked key is a fleet-wide backdoor).
#   - Box B authorizes that ONE public key for the dedicated kh-replica account,
#     scoped three ways: restrict (no pty/agent/port-forward/rc), from= the
#     tailscale CGNAT range (usable only over the owner's tailnet, mirroring
#     support-access.nix), and command= the fixed receiver below. sshd's Match
#     block adds ForceCommand + PermitTTY no as a second, config-level layer, so
#     even a hand-written bare key line could not escape the receiver.
#   - The receiver is NOT a login: it accepts exactly one shape of rsync server
#     invocation confined to the landing area, refuses --sender (no read-back of
#     anything outside what replication wrote), and refuses every deletion
#     option server-side (decisions.md #3: deletions must not propagate — the
#     RECEIVING box enforces this; the sender is never trusted).
#   - Revocation: Unpair truncates the authorized key (support-access revoke
#     idiom); factory reset wipes p4 and with it the pairing. Nothing survives
#     that the owner can't see and remove.
#
# Phase 1 builds and gates the trust layer only — nothing syncs. The Phase 2
# sender (nightly dump + rsync push) will use the pair key this module mints.
#
# This module is SHARED by both twins and reads nothing profile-dependent, so
# it contributes no third diff-closures root (the twin guarantee is untouched;
# access-profile.nix remains the only branch point).
# ============================================================================

let
  dataDir = "/var/lib/cloudunit";
  replDir = "${dataDir}/replication";
  landing = "${replDir}/landing";
  keyFile = "${replDir}/pair_key";
  authKeys = "${replDir}/authorized_keys";
  pairEnv = "${replDir}/pair.env";
  # Durable "this box has served as a MAIN Keephaven" marker. Written when this
  # box records a primary pairing; deliberately NOT removed by unpair, so the
  # role-reversal guard in pair-accept survives an unpair/re-pair cycle (that is
  # exactly the window the Phase 1 gate reversed the roles in). Cleared by a
  # factory reset — which does NOT wipe p4 wholesale but deletes an EXPLICIT list
  # of paths (`factory-reset.sh:40`), and `replication` had to be ADDED to that
  # list (2026-08-06) for this and every other pairing artefact to be removed.
  wasPrimary = "${replDir}/was-primary";
  unitEnv = "${dataDir}/unit.env";
  fromCidr = "100.64.0.0/10"; # tailscale CGNAT range (support-access.nix idiom)
  replUser = "kh-replica";
  # Disk-protection floor for the landing area, in KiB (10 GiB). The receiver
  # REFUSES an incoming push below this, so a filling backup box surfaces as a
  # loud error on the primary's staleness card instead of silently consuming the
  # disk until the box wedges (decisions.md 2026-08-05 #4: a backup box that
  # quietly ran out of room is the same failure class as silent staleness).
  # Enforced here, in the receiver, because retention and disk protection are
  # RECEIVER policy the sender must not be able to talk it out of.
  minFreeKiB = 10 * 1024 * 1024;

  # The forced-command receiver — the security boundary of the feature.
  # sshd invokes this for EVERY connection as kh-replica (ForceCommand + the
  # key's command=). It allows exactly one client shape:
  #     rsync --server <short-flag-cluster>... . <relative-dest>
  # executed inside the landing area. Everything else is refused and logged.
  # Notes on the allowlist:
  #   - --sender is refused: it would make B SEND files (read access). The pair
  #     direction is push-only (A writes to B's landing area).
  #   - ALL long options are refused (only --server itself is consumed). That
  #     covers the entire --delete*/--remove-source-files family and any future
  #     surprise; the Phase 2 sender is ours, so the allowlist can stay minimal
  #     and be widened deliberately if the sender ever needs a long option.
  #   - Short clusters are letters+dots only (rsync server compat clusters like
  #     -vlogDtpre.iLsfxC). Anything else is refused.
  #   - dest must be relative, no "..", not option-shaped. We chdir into the
  #     landing area first, so a valid dest can only land inside it.
  receiver = pkgs.writeShellScriptBin "cloudunit-replication-receiver" ''
    set -u
    set -f
    LANDING=${landing}
    LOGGER=${pkgs.util-linux}/bin/logger

    refuse() {
      "$LOGGER" -t cloudunit-replication "REFUSED: $1 (cmd: ''${SSH_ORIGINAL_COMMAND:-<none>})"
      echo "keephaven-replication: refused: $1" >&2
      exit 1
    }

    CMD="''${SSH_ORIGINAL_COMMAND:-}"
    [ -n "$CMD" ] || refuse "no command (interactive session)"

    # Reject multi-line commands and shell metacharacters outright. We never
    # eval the string (args go straight to exec), so these could not execute —
    # refusing them anyway keeps the parser's input trivial.
    [ "$(printf '%s' "$CMD" | ${pkgs.coreutils}/bin/wc -l)" -eq 0 ] || refuse "multi-line command"
    if printf '%s' "$CMD" | ${pkgs.gnugrep}/bin/grep -q "[;&|<>\`\$()'\"\\\\]"; then
      refuse "shell metacharacters"
    fi

    # Tokenize (set -f above: no glob expansion during the unquoted split).
    # shellcheck disable=SC2086
    set -- $CMD
    # NAME checks BEFORE the count check, so a non-rsync command names itself in
    # the refusal instead of hiding behind "too few arguments" (Phase 1 gate probe
    # P2: `ssh … id` refused correctly but reported the wrong reason).
    # ''${N:-} defaults are REQUIRED: with the name checks moved ahead of the
    # count check, `set -u` would abort on an unset $2 (bare "rsync") with a raw
    # shell error instead of a clean refusal.
    [ "''${1:-}" = "rsync" ] || refuse "not rsync: ''${1:-<empty>}"
    [ "''${2:-}" = "--server" ] || refuse "not an rsync server invocation"
    [ "$#" -ge 4 ] || refuse "too few arguments"
    shift 2

    FLAGS=""
    DEST=""
    DOTSEEN=0
    for arg do
      case "$arg" in
        --server)  refuse "duplicate --server" ;;
        --sender)  refuse "pull (read) access is not allowed" ;;
        --delete*|--remove-source-files|--force*) refuse "deletion options are not allowed" ;;
        --*)       refuse "long option not allowed: $arg" ;;
        -*)
          case "$arg" in
            (-[A-Za-z.]*) ;;
            (*) refuse "malformed option: $arg" ;;
          esac
          case "$arg" in
            (*[!A-Za-z.-]*) refuse "malformed option: $arg" ;;
          esac
          FLAGS="$FLAGS $arg"
          ;;
        .)
          # First bare "." is rsync's source placeholder; a SECOND one is the
          # destination (rsync's wire form for a push to the target root).
          if [ "$DOTSEEN" -eq 1 ]; then
            [ -z "$DEST" ] || refuse "multiple destinations"
            DEST=.
          else
            DOTSEEN=1
          fi
          ;;
        *)
          [ -z "$DEST" ] || refuse "multiple destinations"
          DEST="$arg"
          ;;
      esac
    done
    [ "$DOTSEEN" -eq 1 ] || refuse "missing source placeholder"
    [ -n "$DEST" ] || refuse "missing destination"
    case "$DEST" in
      (/*)   refuse "absolute destination" ;;
      (-*)   refuse "option-shaped destination" ;;
      (*..*) refuse "path traversal in destination" ;;
    esac

    FREE_KB="$(${pkgs.coreutils}/bin/df -Pk "$LANDING" 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2{print $4}')"
    case "''${FREE_KB:-}" in
      (""|*[!0-9]*) refuse "cannot determine free space on the backup storage" ;;
    esac
    [ "$FREE_KB" -ge ${toString minFreeKiB} ] || refuse "backup storage is full"

    cd "$LANDING" || refuse "landing area unavailable"
    "$LOGGER" -t cloudunit-replication "accepted: rsync --server$FLAGS . $DEST"
    # shellcheck disable=SC2086
    exec ${pkgs.rsync}/bin/rsync --server $FLAGS . "$DEST"
  '';

  # ---- Pairing wrappers (invoked from settings.nix via sudo NOPASSWD) ----

  # A-side: mint (or reuse) this box's pair keypair on p4 and print the PUBLIC
  # key. Idempotent — a re-pair after a failed ceremony reuses the same key.
  pairInit = pkgs.writeShellScriptBin "cloudunit-pair-init" ''
    set -u
    SUFFIX="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_SUFFIX=/{print $2; exit}' ${unitEnv} 2>/dev/null)"
    if [ -z "$SUFFIX" ]; then
      echo "pair-init: no UNIT_SUFFIX in ${unitEnv}; refusing" >&2
      exit 1
    fi
    ${pkgs.coreutils}/bin/mkdir -p ${replDir}
    ${pkgs.coreutils}/bin/chmod 755 ${replDir}
    if [ ! -f ${keyFile} ]; then
      ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f ${keyFile} -C "keephaven-pair-$SUFFIX"
      ${pkgs.coreutils}/bin/chmod 600 ${keyFile}
    fi
    ${pkgs.coreutils}/bin/cat ${keyFile}.pub
  '';

  # A-side: record the peer after a successful accept. Args: peer-suffix,
  # peer-tailnet-node-id (OPTIONAL). The node ID — not hostname or IP — is the
  # durable handle: tailnet names/IPs churn across factory resets (decisions.md
  # 2026-07-26), and Phase 2 resolves the live IP from this ID. An EMPTY node id
  # is the "pending" state: the pair was established before both boxes were on
  # the owner's tailnet (LAN ceremony / bench pre-pair), and the Settings card
  # re-runs this wrapper to complete it the first time the peer is visible.
  pairRecord = pkgs.writeShellScriptBin "cloudunit-pair-record" ''
    set -u
    PEER="''${1:-}"
    NODEID="''${2:-}"
    case "$PEER" in
      ([bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789]) ;;
      (*) echo "pair-record: bad peer suffix" >&2; exit 2 ;;
    esac
    case "$NODEID" in
      ("") ;; # pending: completed later, first time the peer is seen on the tailnet
      (*[!A-Za-z0-9]*) echo "pair-record: bad node id" >&2; exit 2 ;;
    esac
    ${pkgs.coreutils}/bin/mkdir -p ${replDir}
    ${pkgs.coreutils}/bin/chmod 755 ${replDir}
    TMP="$(${pkgs.coreutils}/bin/mktemp ${replDir}/.pair.XXXXXX)"
    printf 'ROLE=primary\nPEER_SUFFIX=%s\nPEER_NODEID=%s\n' "$PEER" "$NODEID" > "$TMP"
    ${pkgs.coreutils}/bin/chmod 600 "$TMP"
    ${pkgs.coreutils}/bin/mv -f "$TMP" ${pairEnv}
    # Durable role marker (see wasPrimary above): survives unpair so this box can
    # never silently become someone else's backup afterwards.
    printf 'was_primary=1\n' > ${wasPrimary} 2>/dev/null || true
    ${pkgs.coreutils}/bin/chmod 644 ${wasPrimary} 2>/dev/null || true
    ${pkgs.util-linux}/bin/logger -t cloudunit-replication "paired as primary with keephaven-$PEER ($NODEID)"
    echo "OK: recorded peer keephaven-$PEER"
  '';

  # B-side: authorize the pasted PUBLIC key for kh-replica. Arg 1 = the
  # PRIMARY's suffix (validated); key line arrives on STDIN, never argv (the
  # support-access.nix grant discipline). The authorized line is RECONSTRUCTED
  # from the validated type+base64 only — pasted text can never inject options.
  pairAccept = pkgs.writeShellScriptBin "cloudunit-pair-accept" ''
    set -u
    PEER="''${1:-}"
    # Arg 2 = "force": the owner explicitly confirmed a role reversal.
    FORCE="''${2:-}"
    case "$PEER" in
      ([bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789][bcdfghjkmnpqrstvwxyz23456789]) ;;
      (*) echo "pair-accept: bad peer suffix" >&2; exit 2 ;;
    esac

    # ROLE-REVERSAL GUARD. Accepting makes THIS box a backup target for the other
    # one. A box that has served as a MAIN Keephaven must never take that role
    # silently — that would point replication at the wrong box and, from Phase 3
    # on, stop the services on the owner's actual main box. The Phase 1 gate hit
    # exactly this: a former primary was re-paired backwards with no warning.
    # Exit 4 = "would reverse roles"; the initiating box turns that into an
    # explicit are-you-sure and re-sends with force.
    if [ -f ${wasPrimary} ] && [ "$FORCE" != "force" ]; then
      ${pkgs.util-linux}/bin/logger -t cloudunit-replication \
        "pair-accept: REFUSED - this box has served as a MAIN Keephaven; role reversal needs confirmation"
      echo "pair-accept: this Keephaven has been a main box; refusing to become a backup without confirmation" >&2
      exit 4
    fi

    RAW="$(${pkgs.coreutils}/bin/cat)"
    RAW="$(printf '%s' "$RAW" | ${pkgs.coreutils}/bin/tr -d '\r')"
    NLINES="$(printf '%s\n' "$RAW" | ${pkgs.gnugrep}/bin/grep -c . || true)"
    [ "$NLINES" = "1" ] || { echo "pair-accept: expected exactly one public key line" >&2; exit 2; }
    LINE="$(printf '%s\n' "$RAW" | ${pkgs.gnugrep}/bin/grep -m1 .)"

    TYPE="$(printf '%s' "$LINE" | ${pkgs.gawk}/bin/awk '{print $1}')"
    DATA="$(printf '%s' "$LINE" | ${pkgs.gawk}/bin/awk '{print $2}')"
    [ -n "$TYPE" ] && [ -n "$DATA" ] || { echo "pair-accept: malformed key" >&2; exit 2; }
    case "$TYPE" in
      ssh-ed25519) ;;
      *) echo "pair-accept: unsupported key type: $TYPE (pair keys are ed25519)" >&2; exit 2 ;;
    esac
    TMPK="$(${pkgs.coreutils}/bin/mktemp)"
    printf '%s %s\n' "$TYPE" "$DATA" > "$TMPK"
    if ! ${pkgs.openssh}/bin/ssh-keygen -l -f "$TMPK" >/dev/null 2>&1; then
      ${pkgs.coreutils}/bin/rm -f "$TMPK"
      echo "pair-accept: not a valid public key" >&2
      exit 2
    fi
    ${pkgs.coreutils}/bin/rm -f "$TMPK"

    # Ownership setup is FATAL on failure — never continue on a half-set-up
    # landing area. (P4: a failing chown was silently stepped over because this
    # script runs under `set -u` without `set -e`.)
    if ! ${pkgs.coreutils}/bin/mkdir -p ${landing} \
      || ! ${pkgs.coreutils}/bin/chmod 755 ${replDir} \
      || ! ${pkgs.coreutils}/bin/chown ${replUser}:${replUser} ${landing} \
      || ! ${pkgs.coreutils}/bin/chmod 750 ${landing}; then
      ${pkgs.util-linux}/bin/logger -t cloudunit-replication \
        "pair-accept: REFUSED - could not prepare ${landing} (ownership/mode); not authorizing"
      echo "pair-accept: could not prepare the backup storage area; refusing to pair" >&2
      exit 3
    fi

    # FAIL-CLOSED SELF-VERIFICATION (mirrors the support-grant's "no timer => no
    # key"): prove, AS kh-replica, that the landing area is actually usable BEFORE
    # authorizing anything. Root's CAP_DAC_OVERRIDE masks permission faults on
    # every path above — only the real identity can prove reachability. Phase 1
    # gate probe P4 failed exactly here (p4 root denied search to others), and it
    # presented as a mystery at first sync instead of an error at pairing time.
    # Exit 3 = "storage not ready" (settings maps it to a distinct message).
    if ! ${pkgs.util-linux}/bin/runuser -u ${replUser} -- \
         ${pkgs.bash}/bin/sh -c 'cd ${landing} && ${pkgs.coreutils}/bin/touch .pair-probe && ${pkgs.coreutils}/bin/rm -f .pair-probe' 2>/dev/null; then
      ${pkgs.util-linux}/bin/logger -t cloudunit-replication \
        "pair-accept: REFUSED - ${replUser} cannot use ${landing} (permissions); not authorizing"
      echo "pair-accept: the backup storage area is not usable by ${replUser}; refusing to pair" >&2
      exit 3
    fi

    NEW="$(${pkgs.coreutils}/bin/mktemp ${replDir}/.ak.XXXXXX)"
    printf 'restrict,from="%s",command="%s" %s %s keephaven-pair-%s\n' \
      "${fromCidr}" "${receiver}/bin/cloudunit-replication-receiver" "$TYPE" "$DATA" "$PEER" > "$NEW"
    ${pkgs.coreutils}/bin/chmod 644 "$NEW"
    ${pkgs.coreutils}/bin/chown root:root "$NEW"
    ${pkgs.coreutils}/bin/mv -f "$NEW" ${authKeys}

    TMP="$(${pkgs.coreutils}/bin/mktemp ${replDir}/.pair.XXXXXX)"
    printf 'ROLE=backup-target\nPEER_SUFFIX=%s\n' "$PEER" > "$TMP"
    ${pkgs.coreutils}/bin/chmod 600 "$TMP"
    ${pkgs.coreutils}/bin/mv -f "$TMP" ${pairEnv}

    ${pkgs.util-linux}/bin/logger -t cloudunit-replication "paired as backup-target for keephaven-$PEER (key authorized)"
    echo "OK: paired"
  '';

  # Both sides: "paired <role> <peer-suffix> <ok|pending|broken>" or "unpaired".
  #   pending = primary whose peer node ID is not recorded yet (paired over the
  #             LAN before both boxes were on the tailnet)
  #   broken  = the record claims a pairing this box CANNOT honour: a primary
  #             with no pair key, or a backup target with no authorized key.
  # The card must never claim "paired" on state it can't back up (Phase 1 gate:
  # box A showed a confident "paired" while its pair key was gone). No secrets.
  pairStatus = pkgs.writeShellScriptBin "cloudunit-pair-status" ''
    set -u
    if [ -f ${pairEnv} ]; then
      ROLE="$(${pkgs.gawk}/bin/awk -F= '/^ROLE=/{print $2; exit}' ${pairEnv})"
      PEER="$(${pkgs.gawk}/bin/awk -F= '/^PEER_SUFFIX=/{print $2; exit}' ${pairEnv})"
      NODEID="$(${pkgs.gawk}/bin/awk -F= '/^PEER_NODEID=/{print $2; exit}' ${pairEnv})"
      STATE=ok
      if [ "''${ROLE:-}" = "primary" ]; then
        if [ ! -s ${keyFile} ]; then
          STATE=broken
        elif [ -z "$NODEID" ]; then
          STATE=pending
        fi
      else
        [ -s ${authKeys} ] || STATE=broken
      fi
      echo "paired ''${ROLE:-unknown} ''${PEER:-unknown} $STATE"
    else
      echo "unpaired"
    fi
  '';

  # Both sides: remove whatever half of the pairing this box holds. Truncates
  # the authorized key (keeps the file — the support-access revoke idiom),
  # deletes the pair record and, on a primary, the pair keypair. Idempotent.
  pairUnpair = pkgs.writeShellScriptBin "cloudunit-pair-unpair" ''
    set -u
    # Truncate ONLY if the file already exists. `: > file` CREATES it otherwise —
    # which left an empty root:root authorized_keys on a PRIMARY (a file that box
    # has no business owning) and made the Phase 1 gate's post-reboot state look
    # like a boot-time gremlin.
    if [ -f ${authKeys} ]; then : > ${authKeys} 2>/dev/null || true; fi
    ${pkgs.coreutils}/bin/rm -f ${pairEnv} ${keyFile} ${keyFile}.pub
    ${pkgs.util-linux}/bin/logger -t cloudunit-replication "UNPAIRED (key revoked, pair record removed)"
    echo "OK: unpaired"
  '';

  # Peer discovery for the pairing UI: other keephaven-* nodes on the owner's
  # tailnet, from the SAME status JSON the remote-access wrappers already parse
  # (tailscale.nix) — here reading the Peer map. TSV: hostname, ip, id, online.
  tailnetPeers = pkgs.writeShellScriptBin "cloudunit-tailnet-peers" ''
    set -u
    ${pkgs.coreutils}/bin/timeout 8 ${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null | \
      ${pkgs.jq}/bin/jq -r '.Peer[]? | select(.HostName | startswith("keephaven-")) |
        [.HostName, (.TailscaleIPs[0] // ""), .ID, (.Online | tostring)] | @tsv'
  '';
in
{
  # ---- The customer-exposure gate for the WHOLE replication arc ----
  #
  # Phases 1-4 all land on `main` before any of it reaches a customer, and every
  # customer unit is fresh-flashed from an image built off `main` -- so without a
  # gate, a box shipped mid-arc would show a "Pair with another Keephaven" card
  # backed by a feature that cannot yet back anything up or restore it. This
  # option is that gate: it hides the owner-facing surface (the Settings card
  # now; the dashboard backup card and the sync timers as they land) while the
  # plumbing underneath stays present and inert.
  #
  # Default FALSE is the shipping posture for the entire arc. It flips to true in
  # ONE commit, together with the site copy, as the Phase 4 customer release --
  # that commit IS the launch. Internal gate images are built with it true.
  #
  # Twin-safe: identical in both twins for any given build, so it adds no third
  # `diff-closures` root; access-profile.nix remains the only branch.
  options.keephaven.replication.enable = lib.mkOption {
    type = lib.types.bool;
    # LAUNCH 2026-08-18: flipped from false to true. This is the single line
    # that exposes the box-to-box backup feature to customers - after all four
    # phases were hardware-gated and the site copy below it went live in the
    # same commit. Flip back to false only to pull the feature fleet-wide.
    default = true;
    description = "Expose box-to-box backup to the owner (pairing card, backup status, sync timers). FALSE on customer images until the Phase 4 restore path is hardware-gated.";
  };

  config = {
  # The receiving account. isNormalUser (not system) because sshd executes the
  # forced command through the account's login shell — a nologin shell would
  # silently break the receiver. The account's inertness comes from the forced
  # command + restrict + the Match block below, not from the shell. Password
  # login is locked (and PasswordAuthentication is off globally, base.nix).
  # NOTE the explicit `group` + `users.groups` pair. `isNormalUser = true` makes
  # NixOS default the primary group to "users" and declares NO per-user group, so
  # `chown kh-replica:kh-replica` fails with "invalid group" — which is precisely
  # how the Phase 1 gate's P4 failed: the chown errored, the script continued (no
  # `set -e`), the landing dir stayed root:root 0750, and kh-replica could not
  # enter its own directory. Declaring the group is the fix; the fail-closed probe
  # in pair-accept is the backstop. (Same shape settings.nix uses for
  # cloudunit-web.)
  users.groups.${replUser} = {};
  users.users.${replUser} = {
    isNormalUser = true;
    group = replUser;
    description = "Keephaven replication receiver (forced-command only)";
    hashedPassword = "!";
  };

  environment.systemPackages = [
    receiver pairInit pairRecord pairAccept pairStatus pairUnpair tailnetPeers
  ];

  # Expose the privileged wrappers to settings.nix (which owns the UI + sudo
  # grants) via the shared cloudunit.wrappers registry.
  cloudunit.wrappers.pairInit = "${pairInit}/bin/cloudunit-pair-init";
  cloudunit.wrappers.pairRecord = "${pairRecord}/bin/cloudunit-pair-record";
  cloudunit.wrappers.pairAccept = "${pairAccept}/bin/cloudunit-pair-accept";
  cloudunit.wrappers.pairStatus = "${pairStatus}/bin/cloudunit-pair-status";
  cloudunit.wrappers.pairUnpair = "${pairUnpair}/bin/cloudunit-pair-unpair";
  cloudunit.wrappers.tailnetPeers = "${tailnetPeers}/bin/cloudunit-tailnet-peers";

  # Config-level enforcement, independent of the key's own options: kh-replica
  # can ONLY run the receiver, gets no tty and no forwarding, and its ONLY key
  # source is the p4 pair file (so no other key can authorize this account and
  # this file can authorize no other account). Self-contained Match block ending
  # in "Match all" — order-independent of support-access.nix's block, which
  # contributes to the same option and follows the same convention.
  services.openssh.extraConfig = ''
    Match User ${replUser}
      AuthorizedKeysFile ${authKeys}
      ForceCommand ${receiver}/bin/cloudunit-replication-receiver
      PermitTTY no
      AllowAgentForwarding no
      AllowTcpForwarding no
      X11Forwarding no
      PermitTunnel no
    Match all
  '';
  };
}
