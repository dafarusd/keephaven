{ config, pkgs, lib, ... }:

# ============================================================================
# BREAK-GLASS SUPPORT ACCESS (Option E) — customer pastes SUPPORT's per-incident
# PUBLIC key into Settings; NOTHING secret ever travels. The key authorizes a
# time-boxed, tailnet-only login as kh-admin (the single break-glass account).
#
# Why this shape:
#   - PUBLIC key only: the support engineer keeps their private key; the customer
#     pastes the matching public key. No vendor secret on the box, ever.
#   - /run tmpfs landing: the authorized key lives ONLY in volatile memory
#     (/run/cloudunit/support_authorized_keys). A reboot wipes it = hard revoke.
#   - from="100.64.0.0/10": usable ONLY from the tailnet (CGNAT range). On prod
#     sshd is reachable only over tailscale0 anyway; this is belt + suspenders.
#   - expiry-time=: sshd itself refuses the key after the deadline (OpenSSH
#     10.3p1 supports it — verified). Primary, passive expiry.
#   - FAIL-CLOSED auto-revoke: grant schedules a transient revoke timer FIRST and
#     authorizes the key ONLY if that succeeded ("no timer => no key"). The timer
#     actively truncates the key file at expiry. Three independent expiry layers
#     (sshd expiry-time, the timer, reboot/tmpfs) — any one suffices.
#
# This module owns the MECHANISM (key file lifecycle, scoping, grant/revoke
# wrappers, boot clear). settings.nix owns the UI (Support Access card + POST
# route + the NOPASSWD rule that calls cloudunit-support-access-grant).
# ============================================================================

let
  runDir = "/run/cloudunit";
  keyFile = "${runDir}/support_authorized_keys";
  dataDir = "/var/lib/cloudunit";
  auditLog = "${dataDir}/support-access.log";
  fromCidr = "100.64.0.0/10"; # tailscale CGNAT range
  maxHours = 72;
  revokeUnit = "cloudunit-support-revoke";

  # Revoke = truncate the volatile key file so NO new support login can start.
  # Existing sessions are intentionally left to finish (yanking a key mid-repair
  # is worse than letting the session end). Idempotent.
  revoke = pkgs.writeShellScriptBin "cloudunit-support-access-revoke" ''
    set -u
    : > ${keyFile} 2>/dev/null || true
    ${pkgs.util-linux}/bin/logger -t cloudunit-support "support access REVOKED (key file truncated)"
    if [ -w ${dataDir} ] || [ -w ${auditLog} ]; then
      echo "$(${pkgs.coreutils}/bin/date -Is) revoke" >> ${auditLog} 2>/dev/null || true
    fi
  '';

  # Status for the UI: prints "active <expiry>" or "inactive". No secrets.
  status = pkgs.writeShellScriptBin "cloudunit-support-access-status" ''
    set -u
    if [ -s ${keyFile} ]; then
      EXP="$(${pkgs.gnused}/bin/sed -n 's/.*expiry-time="\([0-9]*\)".*/\1/p' ${keyFile} | ${pkgs.coreutils}/bin/head -n1)"
      echo "active $EXP"
    else
      echo "inactive"
    fi
  '';

  # Grant: validate a pasted PUBLIC key (untrusted input), then atomically
  # schedule auto-revoke and authorize. The key line is RECONSTRUCTED from the
  # validated type+base64 only — the pasted text can never inject authorized_keys
  # options. Reads the key from stdin (never argv) so it stays out of the process
  # list and logs. Arg 1 = duration in hours (1..72, default 24).
  grant = pkgs.writeShellScriptBin "cloudunit-support-access-grant" ''
    set -u
    HOURS="''${1:-24}"
    case "$HOURS" in (*[!0-9]*|"") echo "bad duration (want integer hours)" >&2; exit 2;; esac
    if [ "$HOURS" -lt 1 ] || [ "$HOURS" -gt ${toString maxHours} ]; then
      echo "duration out of range (1-${toString maxHours}h)" >&2; exit 2
    fi

    RAW="$(${pkgs.coreutils}/bin/cat)"
    RAW="$(printf '%s' "$RAW" | ${pkgs.coreutils}/bin/tr -d '\r')"
    NLINES="$(printf '%s\n' "$RAW" | ${pkgs.gnugrep}/bin/grep -c . || true)"
    [ "$NLINES" = "1" ] || { echo "expected exactly one public key line" >&2; exit 2; }
    LINE="$(printf '%s\n' "$RAW" | ${pkgs.gnugrep}/bin/grep -m1 .)"

    TYPE="$(printf '%s' "$LINE" | ${pkgs.gawk}/bin/awk '{print $1}')"
    DATA="$(printf '%s' "$LINE" | ${pkgs.gawk}/bin/awk '{print $2}')"
    [ -n "$TYPE" ] && [ -n "$DATA" ] || { echo "malformed key" >&2; exit 2; }
    case "$TYPE" in
      ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
      *) echo "unsupported key type: $TYPE" >&2; exit 2;;
    esac

    TMP="$(${pkgs.coreutils}/bin/mktemp)"
    printf '%s %s\n' "$TYPE" "$DATA" > "$TMP"
    if ! ${pkgs.openssh}/bin/ssh-keygen -l -f "$TMP" >/dev/null 2>&1; then
      ${pkgs.coreutils}/bin/rm -f "$TMP"; echo "not a valid public key" >&2; exit 2
    fi
    ${pkgs.coreutils}/bin/rm -f "$TMP"

    EXPIRY="$(${pkgs.coreutils}/bin/date -d "+$HOURS hours" +%Y%m%d%H%M%S)"
    TAG="support-$(${pkgs.coreutils}/bin/date +%Y%m%dT%H%M%S)"

    ${pkgs.coreutils}/bin/mkdir -p ${runDir}
    ${pkgs.coreutils}/bin/chmod 755 ${runDir}

    # FAIL-CLOSED ATOMICITY: schedule the auto-revoke timer FIRST. Clear any
    # prior transient unit, then create the new one. If scheduling fails, do NOT
    # authorize the key — a key without an expiry timer must never exist.
    SYSTEMCTL=${pkgs.systemd}/bin/systemctl
    $SYSTEMCTL stop ${revokeUnit}.timer ${revokeUnit}.service 2>/dev/null || true
    $SYSTEMCTL reset-failed ${revokeUnit}.timer ${revokeUnit}.service 2>/dev/null || true
    if ! ${pkgs.systemd}/bin/systemd-run --quiet \
          --on-active="''${HOURS}h" \
          --unit=${revokeUnit} \
          --timer-property=AccuracySec=1min \
          ${revoke}/bin/cloudunit-support-access-revoke ; then
      echo "failed to schedule auto-revoke; refusing to grant" >&2
      exit 1
    fi

    # Authorize: reconstruct the line with OUR options; fixed tag as comment.
    NEW="$(${pkgs.coreutils}/bin/mktemp ${runDir}/.sk.XXXXXX)"
    printf 'from="%s",expiry-time="%s" %s %s %s\n' "${fromCidr}" "$EXPIRY" "$TYPE" "$DATA" "$TAG" > "$NEW"
    ${pkgs.coreutils}/bin/chmod 644 "$NEW"
    ${pkgs.coreutils}/bin/chown root:root "$NEW"
    ${pkgs.coreutils}/bin/mv -f "$NEW" ${keyFile}

    ${pkgs.util-linux}/bin/logger -t cloudunit-support "support access GRANTED for ''${HOURS}h (expiry $EXPIRY)"
    echo "$(${pkgs.coreutils}/bin/date -Is) grant ''${HOURS}h expiry=$EXPIRY type=$TYPE" >> ${auditLog} 2>/dev/null || true
    echo "granted until $EXPIRY"
  '';
in
{
  environment.systemPackages = [ grant revoke status ];

  # Expose the privileged support wrappers to settings.nix (UI + sudo grants)
  # via the shared cloudunit.wrappers registry.
  cloudunit.wrappers.supportGrant = "${grant}/bin/cloudunit-support-access-grant";
  cloudunit.wrappers.supportRevoke = "${revoke}/bin/cloudunit-support-access-revoke";
  cloudunit.wrappers.supportStatus = "${status}/bin/cloudunit-support-access-status";

  # Boot clear: ensure the run dir + an EMPTY key file exist on every boot.
  # /run is tmpfs (wiped on reboot) so this is the hard-revoke-on-reboot made
  # explicit; f+ truncates if anything somehow survived.
  systemd.tmpfiles.rules = [
    "d ${runDir} 0755 root root -"
    "f+ ${keyFile} 0644 root root -"
  ];

  # Scope the volatile support key to kh-admin ONLY (not a global
  # AuthorizedKeysFile entry that every account would consult). Preserve the
  # default key sources and append the /run file. StrictModes is satisfied: the
  # file is root-owned and not group/world writable.
  services.openssh.extraConfig = ''
    Match User kh-admin
      AuthorizedKeysFile %h/.ssh/authorized_keys /etc/ssh/authorized_keys.d/%u ${keyFile}
    Match all
  '';
}
