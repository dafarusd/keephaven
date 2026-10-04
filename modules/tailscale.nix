# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# TAILSCALE — daemon + customer-state-on-p4 + the dev-tailnet leak guard.
#
# State lives on the DATA partition (p4, /var/lib/cloudunit/tailscale) so a
# system-only reflash (recovery arc) leaves the customer's tailnet membership
# intact. That same property creates ONE risk: a DEV unit's p4 (joined to the
# operator's tailnet) ending up under a PROD system would silently re-join that
# tailnet = a leak. cloudunit-tailscale-state-guard is the mechanical control
# that closes it: on every PROD boot, BEFORE tailscaled can read anything, it
# keeps existing state ONLY on an unambiguous prod+this-unit provenance stamp,
# and WIPES on anything else (fail-closed).
#
# Oracle integrity: the guard's dev/prod oracle is `test -s
# /etc/ssh/authorized_keys.d/kh-admin`. access-profile.nix is the SOLE writer of
# that file; prod sets the key list to [] => the file is empty/absent => the
# guard reads "prod" and enforces. There is no code path that adds a kh-admin
# key on prod (verified: it is the only authorizedKeys.keys assignment in the
# tree, and diff-closures shows the file present on dev / absent on prod).
# ============================================================================

let
  dataDir = "/var/lib/cloudunit";
  stateDir = "${dataDir}/tailscale";
  stateFile = "${stateDir}/tailscaled.state";
  stampFile = "${stateDir}/established.stamp";
  # The owner turned remote access OFF. While this exists tailscaled never starts.
  # In the state dir on purpose: a factory reset or a guard wipe takes it too.
  offMarker = "${stateDir}/remote-access.off";
  # The owner pressed ON this boot. Lets tailscaled start for a FIRST sign-in,
  # before any stamp exists. In /run, so it never outlives a restart.
  requestedFlag = "/run/cloudunit-remote-access.requested";
  unitEnv = "${dataDir}/unit.env";
  # The dev/prod oracle. Non-empty => dev (admin key baked); absent/empty =>
  # prod. SOLE writer is access-profile.nix.
  oracle = "/etc/ssh/authorized_keys.d/kh-admin";
  guardUnit = "cloudunit-tailscale-state-guard.service";

  # Canonical provenance stamp. The guard keeps prod state ONLY when the stamp
  # file's content equals EXACTLY these two lines (established_by=prod + this
  # unit's suffix). Written atomically by cloudunit-tailscale-stamp (below),
  # invoked from the Settings "Remote Access" flow at the moment a unit joins a
  # tailnet through the official path. Any other way of bringing tailscale up on
  # prod leaves no/invalid stamp => the guard wipes on next boot (by design:
  # there is exactly one supported establish path).
  stampWriter = pkgs.writeShellScriptBin "cloudunit-tailscale-stamp" ''
    set -u
    SUFFIX="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_SUFFIX=/{print $2; exit}' ${unitEnv} 2>/dev/null)"
    if [ -z "$SUFFIX" ]; then
      echo "tailscale-stamp: no UNIT_SUFFIX in ${unitEnv}; refusing to stamp" >&2
      exit 1
    fi
    # established_by reflects the REAL profile via the same oracle the guard
    # uses, so a dev-originated stamp can never read as prod.
    if [ -s ${oracle} ]; then EB=dev; else EB=prod; fi
    ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
    ${pkgs.coreutils}/bin/chmod 700 ${stateDir}
    TMP="$(${pkgs.coreutils}/bin/mktemp ${stateDir}/.stamp.XXXXXX)"
    printf 'established_by=%s\nunit=%s\n' "$EB" "$SUFFIX" > "$TMP"
    ${pkgs.coreutils}/bin/mv -f "$TMP" ${stampFile}
    echo "tailscale-stamp: established_by=$EB unit=$SUFFIX"
  '';

  # Settings "Remote Access" enable: status-FIRST and idempotent so a page
  # revisit never clobbers an in-flight login (the bug that kept BackendState
  # from ever reaching Running). Three cases:
  #   Running                         -> already connected; touch nothing, exit.
  #   login unit active               -> a `tailscale up` is mid-flight holding a
  #                                      live AuthURL; leave it so the SAME link
  #                                      stays valid, exit.
  #   off / failed / dead             -> stamp provenance, clear any dead unit,
  #                                      start a fresh transient `tailscale up`.
  # The removed `systemctl stop` was the core defect: it killed the finalizing
  # login on every revisit and minted a new URL each time.
  remoteAccessEnable = pkgs.writeShellScriptBin "cloudunit-remote-access-enable" ''
    set -u
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    TS=${pkgs.tailscale}/bin/tailscale
    # Path ONLY -- see immich-dump.nix: baking "-t tag" in here breaks
    # silently the moment someone quotes the expansion.
    LOG=${pkgs.util-linux}/bin/logger

    # EVERY branch logs. The 2026-08-07 hcgq6 investigation burned a full
    # diagnostic cycle because this path was silent end to end: settings runs it
    # from a thread with capture_output and DISCARDS the result, and the script
    # itself never logged, so a failure was indistinguishable from "still
    # working" and the card span forever. Never again: if it fails, the journal
    # says so and the card says so.
    "$LOG" -t cloudunit-remote-access "enable: requested"

    # 0. tailscaled is not started at boot any more: it runs only once the owner
    #    has turned remote access on (unit conditions at the bottom of this file).
    #    Clear OFF and raise the this-boot flag BEFORE step 1 starts the daemon,
    #    or its start is skipped and step 1 times out.
    ${pkgs.coreutils}/bin/rm -f ${offMarker}
    if ! ${pkgs.coreutils}/bin/touch ${requestedFlag}; then
      "$LOG" -t cloudunit-remote-access "enable: FAILED - could not write ${requestedFlag}"
      echo "could not start the remote-access service" >&2
      exit 3
    fi

    # 1. The daemon must be up AND answering before `tailscale up` is worth
    #    trying. On a fresh flash tailscaled starts ~2s after boot, before the
    #    network is usable, and logs control-plane failures (hcgq6 journal:
    #    bootstrapDNS "network is unreachable", then "no DNS fallback candidates
    #    remain"). Rather than reordering the daemon at boot -- which would risk
    #    delaying an OFFLINE box's boot, and the box must work fully offline --
    #    the owner-initiated action makes sure the daemon is healthy right now.
    if ! $SYSTEMCTL is-active --quiet tailscaled.service; then
      "$LOG" -t cloudunit-remote-access "enable: tailscaled not active; starting it"
      if ! $SYSTEMCTL start tailscaled.service; then
        "$LOG" -t cloudunit-remote-access "enable: FAILED to start tailscaled"
        echo "could not start the remote-access service" >&2
        exit 3
      fi
    fi
    READY=0
    i=0
    while [ "$i" -lt 15 ]; do
      if [ -n "$(${pkgs.coreutils}/bin/timeout 5 $TS status --json 2>/dev/null)" ]; then
        READY=1; break
      fi
      ${pkgs.coreutils}/bin/sleep 1
      i=$((i + 1))
    done
    if [ "$READY" -ne 1 ]; then
      "$LOG" -t cloudunit-remote-access "enable: FAILED - tailscaled not answering after 15s"
      echo "the remote-access service is not responding" >&2
      exit 3
    fi

    JSON="$(${pkgs.coreutils}/bin/timeout 8 $TS status --json 2>/dev/null)"
    STATE="$(printf '%s' "$JSON" | ${pkgs.jq}/bin/jq -r '.BackendState // "Unknown"' 2>/dev/null || echo Unknown)"
    ONLINE="$(printf '%s' "$JSON" | ${pkgs.jq}/bin/jq -r '.Self.Online // false' 2>/dev/null || echo false)"
    # Skip the (re)connect ONLY when the session is genuinely established.
    # BackendState=Running is satisfied even by reflash-carried p4 state that is
    # registered-but-unreachable (the half-state, e.g. a control-plane 502 left a
    # half-finished registration), so we additionally require Self.Online=true.
    if [ "$STATE" = "Running" ] && [ "$ONLINE" = "true" ]; then
      "$LOG" -t cloudunit-remote-access "enable: already connected"
      echo "OK: already connected"
      exit 0
    fi
    if $SYSTEMCTL is-active --quiet cloudunit-tailscale-login.service; then
      # A login is genuinely mid-flight and holds a live AuthURL. Leave it alone
      # so the SAME link stays valid (removing the old unconditional `stop` was
      # the fix that stopped minting a new URL on every page revisit).
      "$LOG" -t cloudunit-remote-access "enable: login already in progress; leaving it"
      echo "OK: login already in progress"
      exit 0
    fi

    # 2. The unit is NOT active, so any leftover instance is dead or failed.
    #    Clear BOTH states: a transient unit that has exited but not been
    #    garbage-collected still holds its name, and `systemd-run --unit=` with a
    #    name in use FAILS. reset-failed alone does not release an inactive unit.
    $SYSTEMCTL reset-failed cloudunit-tailscale-login.service 2>/dev/null || true
    $SYSTEMCTL stop cloudunit-tailscale-login.service 2>/dev/null || true

    ${stampWriter}/bin/cloudunit-tailscale-stamp || "$LOG" -t cloudunit-remote-access "enable: WARNING stamp failed"

    # 3. NO --collect: a failed login unit must SURVIVE so `is-failed` can see it
    #    and the status wrapper can turn the spinner into a real error. --collect
    #    destroyed exactly the evidence we needed. The reset-failed/stop pair
    #    above is what keeps the name reusable.
    if ! ${pkgs.systemd}/bin/systemd-run --quiet --unit=cloudunit-tailscale-login \
           $TS up; then
      "$LOG" -t cloudunit-remote-access "enable: FAILED - could not start the login unit"
      echo "could not start the remote-access login" >&2
      exit 4
    fi
    "$LOG" -t cloudunit-remote-access "enable: login unit started"
    echo "OK: remote access starting"
  '';

  # Settings "Remote Access" disable: the real OFF switch (2026-10-03).
  #
  # Until this existed the card told owners to turn remote access off by starting
  # setup over. That only removes .setup-complete: run on the test unit, the box
  # went back to first-run setup and stayed connected. The one real off was a
  # factory reset, which also removes every app's data.
  #
  # OFF = tailscaled is NOT RUNNING, and stays that way across a restart. A plain
  # `tailscale down` was measured on the test unit and is not enough: the daemon
  # kept connections open to Tailscale's servers. The sign-in is kept on disk, so
  # ON again reconnects without a new link. OFF does not remove the box from the
  # owner's account; only they can do that, in their console.
  remoteAccessDisable = pkgs.writeShellScriptBin "cloudunit-remote-access-disable" ''
    set -u
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    TS=${pkgs.tailscale}/bin/tailscale
    # Path ONLY -- same rule as the enable wrapper above.
    LOG=${pkgs.util-linux}/bin/logger

    # EVERY branch logs, same as enable: settings shows the owner one line, the
    # journal has to carry the rest.
    "$LOG" -t cloudunit-remote-access "disable: requested"

    # A sign-in may be mid-flight (ON was clicked, the link never used). Its
    # `tailscale up` would bring the box straight back, so end it first.
    $SYSTEMCTL stop cloudunit-tailscale-login.service 2>/dev/null || true
    $SYSTEMCTL reset-failed cloudunit-tailscale-login.service 2>/dev/null || true

    # Mark OFF first. From this line on, nothing can start the daemon again: not
    # a restart of the box, not systemd's own Restart=on-failure.
    ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
    ${pkgs.coreutils}/bin/chmod 700 ${stateDir}
    ${pkgs.coreutils}/bin/rm -f ${requestedFlag}
    if ! ${pkgs.coreutils}/bin/touch ${offMarker}; then
      "$LOG" -t cloudunit-remote-access "disable: FAILED - could not write ${offMarker}"
      echo "could not turn remote access off" >&2
      exit 5
    fi

    if $SYSTEMCTL is-active --quiet tailscaled.service; then
      # Belt and braces: also tell tailscaled itself to stay disconnected, so a
      # daemon that somehow runs without the marker still does not connect.
      if ! ${pkgs.coreutils}/bin/timeout 20 $TS down; then
        "$LOG" -t cloudunit-remote-access "disable: WARNING - tailscale down returned an error; stopping the daemon anyway"
      fi
      if ! $SYSTEMCTL stop tailscaled.service; then
        "$LOG" -t cloudunit-remote-access "disable: FAILED - could not stop tailscaled"
        echo "could not turn remote access off" >&2
        exit 3
      fi
    else
      "$LOG" -t cloudunit-remote-access "disable: tailscaled was not running"
    fi

    # Self-verify. Never report "off" while the daemon is still there.
    if $SYSTEMCTL is-active --quiet tailscaled.service; then
      "$LOG" -t cloudunit-remote-access "disable: FAILED - tailscaled is still running"
      echo "remote access is still on" >&2
      exit 4
    fi
    "$LOG" -t cloudunit-remote-access "disable: off (tailscaled stopped, marker set)"
    echo "OK: remote access is off"
  '';

  # Settings "Remote Access" status: report connected / a login URL / starting /
  # a state. Mirrors the enable gate: "connected" ONLY when genuinely online
  # (Running + Self.Online), never merely Running, so the card can't claim
  # connected in the registered-but-unreachable half-state. "starting" is emitted
  # while a `tailscale up` is mid-flight but no AuthURL has surfaced yet — it lets
  # the Settings card show a spinner and auto-poll instead of momentarily reading
  # "off" (which would offer the button mid-flow). The login unit is Type=simple,
  # so it stays active for the WHOLE span between the click and the AuthURL
  # appearing (it blocks until login completes/fails) — verified — so this bracket
  # has no early-exit gap.
  remoteAccessStatus = pkgs.writeShellScriptBin "cloudunit-remote-access-status" ''
    set -u
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    JSON="$(${pkgs.coreutils}/bin/timeout 8 ${pkgs.tailscale}/bin/tailscale status --json 2>/dev/null)"
    STATE="$(printf '%s' "$JSON" | ${pkgs.jq}/bin/jq -r '.BackendState // "Unknown"')"
    ONLINE="$(printf '%s' "$JSON" | ${pkgs.jq}/bin/jq -r '.Self.Online // false')"
    URL="$(printf '%s' "$JSON" | ${pkgs.jq}/bin/jq -r '.AuthURL // ""')"
    if [ "$STATE" = "Running" ] && [ "$ONLINE" = "true" ]; then
      echo "connected"
    elif [ -n "$URL" ]; then
      echo "url $URL"
    elif $SYSTEMCTL is-active --quiet cloudunit-tailscale-login.service; then
      echo "starting"
    elif $SYSTEMCTL is-failed --quiet cloudunit-tailscale-login.service; then
      # The login unit ran and DIED. Without this the card treated "not
      # connected, no URL, not active" as "still starting" and span forever --
      # the exact symptom reported on hcgq6. Dropping --collect in the enable
      # wrapper is what makes this state observable at all.
      echo "error"
    else
      echo "$STATE"
    fi
  '';
in
{
  # ----- Tailscale -----
  # Enables the tailscaled daemon. The box joins a tailnet via the Settings
  # "Remote Access" flow (which also writes the provenance stamp). NO auth key
  # is ever baked into this repo or a shipped image.
  services.tailscale = {
    enable = true;
    # Allow the box to act as an exit node / accept routes later if wanted.
    useRoutingFeatures = "server";
    # Relocate state onto the DATA partition so it survives a system reflash.
    # The shipped tailscaled.service hardcodes --state=/var/lib/tailscale/... and
    # then appends $FLAGS (this list) LAST. tailscaled parses with Go's stdlib
    # flag package, where a repeated flag is deterministically last-wins, so this
    # path is the effective one (and --statedir derives from it -> certs/temp on
    # p4 too). Fail-safe even if that ever changed: state would fall back to the
    # system partition (lost on reflash) — a degradation, never a tailnet leak.
    # --no-logs-no-support: tailscaled doesn't send its own diagnostic logs to
    # Tailscale's log server. The cost is in the name: Tailscale will not help
    # debug a box that sends no logs.
    extraDaemonFlags = [ "--state=${stateFile}" "--no-logs-no-support" ];
  };

  # tailscaled handles its own firewall punching; this just ensures the
  # tailscale0 interface traffic is trusted (services reachable over tailnet).
  networking.firewall.trustedInterfaces = [ "tailscale0" ];

  # Make the CLI + the stamp writer + the Settings remote-access wrappers
  # available. All store paths are identical dev/prod.
  environment.systemPackages = [
    pkgs.tailscale stampWriter remoteAccessEnable remoteAccessDisable remoteAccessStatus
  ];

  # Expose the privileged remote-access wrappers to settings.nix (which owns the
  # UI + sudo grants) via the shared cloudunit.wrappers registry.
  cloudunit.wrappers.remoteAccessEnable =
    "${remoteAccessEnable}/bin/cloudunit-remote-access-enable";
  cloudunit.wrappers.remoteAccessDisable =
    "${remoteAccessDisable}/bin/cloudunit-remote-access-disable";
  cloudunit.wrappers.remoteAccessStatus =
    "${remoteAccessStatus}/bin/cloudunit-remote-access-status";

  # ----- Leak guard (security control) -----
  # Ordering IS the control. The guard must finish BEFORE tailscaled reads
  # state. We declare the dependency on BOTH sides (belt + suspenders):
  #   guard:      before = tailscaled  (here)
  #   tailscaled: after + requires = guard  (below)
  # tailscaled is a plain service (NOT socket-activated), so nothing pulls it up
  # ahead of this ordering. Chain: p4 mount -> unit-bootstrap -> guard ->
  # tailscaled. Any upstream failure (e.g. no UNIT_SUFFIX) resolves to WIPE.
  systemd.services.cloudunit-tailscale-state-guard = {
    description = "Cloud Unit - wipe foreign tailscale state on prod (leak guard)";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloudunit-unit-bootstrap.service" ];
    before = [ "tailscaled.service" ];
    unitConfig.RequiresMountsFor = dataDir;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cloudunit-tailscale-state-guard" ''
        set -u
        SYSTEMCTL=${pkgs.systemd}/bin/systemctl

        ensure_dir() {
          ${pkgs.coreutils}/bin/mkdir -p ${stateDir}
          ${pkgs.coreutils}/bin/chmod 700 ${stateDir}
        }

        # WIPE = stop tailscaled (defensive; it should not be running yet),
        # remove the whole state dir, recreate it empty so tailscaled starts
        # fresh = joined to NO tailnet. Always exits 0 (handled outcome).
        wipe() {
          echo "tailscale-guard: WIPING tailscale state ($1)"
          $SYSTEMCTL stop tailscaled.service 2>/dev/null || true
          ${pkgs.coreutils}/bin/rm -rf ${stateDir}
          ensure_dir
          exit 0
        }

        # DEV oracle: admin key present => dev box => leave state untouched.
        if [ -s ${oracle} ]; then
          ensure_dir
          echo "tailscale-guard: dev profile (admin key present); state untouched"
          exit 0
        fi

        # ---- PROD from here. Fail-closed: any doubt => wipe. ----

        # No existing state => nothing to protect; ensure a clean empty dir.
        if [ ! -e ${stateFile} ]; then
          ensure_dir
          echo "tailscale-guard: prod, no existing state; clean"
          exit 0
        fi

        # State exists on a PROD box. Keep ONLY on an exact prod+this-unit stamp.
        [ -r ${stampFile} ] || wipe "no stamp"
        SUFFIX="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_SUFFIX=/{print $2; exit}' ${unitEnv} 2>/dev/null)"
        [ -n "$SUFFIX" ] || wipe "no UNIT_SUFFIX (upstream bootstrap failure)"

        # Strict, whole-file match. A partial/garbled/extra-field/prefix stamp
        # never equals the canonical two-line form => wipe. Keep ONLY on exact.
        EXPECTED="$(printf 'established_by=prod\nunit=%s' "$SUFFIX")"
        ACTUAL="$(${pkgs.coreutils}/bin/cat ${stampFile})"
        [ "$ACTUAL" = "$EXPECTED" ] || wipe "stamp not canonical/mismatch"

        echo "tailscale-guard: prod stamp valid (unit=$SUFFIX); keeping state"
        exit 0
      '';
    };
  };

  # tailscaled waits for (and requires) the guard, and for the data mount.
  # requires = guard => if the guard somehow fails, tailscaled does NOT start
  # (fail-closed: no tailscale beats a leak).
  #
  # It also only starts for a box whose owner turned remote access on. The
  # conditions:
  #   stamp exists      -> remote access was turned on through Settings (the
  #                        stamp is written by that path and nowhere else), OR
  #   this-boot flag    -> ON was pressed just now, first sign-in, no stamp yet;
  #   and NOT the OFF marker.
  # "|" marks the either-or pair; the "!" line must hold as well. A box updated
  # from an older release with remote access on has its stamp, so it carries on.
  systemd.services.tailscaled = {
    after = [ guardUnit ];
    requires = [ guardUnit ];
    unitConfig.RequiresMountsFor = dataDir;
    unitConfig.ConditionPathExists = [
      "|${stampFile}"
      "|${requestedFlag}"
      "!${offMarker}"
    ];
  };
}
