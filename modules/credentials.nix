{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  unitEnv = "${dataDir}/unit.env";

  genScript = pkgs.writeShellScript "cloudunit-gen-identity" ''
    set -euo pipefail

    # Unambiguous charset (no 0/O/1/l/I) for sticker readability, within the
    # AP validator's allowed set (letters + digits).
    SAFE='ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'

    gen() {
      # Read a bounded chunk of randomness, filter to SAFE, take N chars.
      # Bounded input avoids the tr|head SIGPIPE that trips pipefail.
      LC_ALL=C tr -dc "$SAFE" < <(head -c 4096 /dev/urandom) | cut -c1-"$1"
    }

    # Suffix is the ONE shared token behind both the SSID (Keephaven-<suffix>)
    # and the mDNS hostname (keephaven-<suffix>.local). It must be:
    #   - lowercase only: hostnames are case-INSENSITIVE, so a mixed-case token
    #     would lie about its keyspace and could collide two units differing
    #     only by case. Lowercase keeps the SSID and hostname an identical,
    #     unambiguous token.
    #   - no vowels: so the visible name can't spell words/slurs.
    #   - no l/0/1: sticker readability.
    # Charset = 20 lowercase consonants + digits 2-9 = 28 chars; length 5 gives
    # 28^5 = 17,210,368 combos (> the old case-sensitive 48^4 = 5,308,416, so
    # SSID uniqueness is strengthened, not weakened). Password keeps full charset.
    SUFFIX_CHARSET='bcdfghjkmnpqrstvwxyz23456789'
    gen_suffix() {
      LC_ALL=C tr -dc "$SUFFIX_CHARSET" < <(head -c 4096 /dev/urandom) | cut -c1-"$1"
    }
    SUFFIX="$(gen_suffix 5)"
    PASSWORD="$(gen 14)"

    umask 077
    cat > ${unitEnv} <<EOF
UNIT_SSID=Keephaven-$SUFFIX
UNIT_SUFFIX=$SUFFIX
UNIT_PASSWORD=$PASSWORD
EOF
    chmod 600 ${unitEnv}
  '';

  # Factory/sticker-print output: emit this unit's identity as clean, parseable
  # KEY=VALUE lines (consumed by the mass-production sticker-print script - NOT a
  # copy of an SSH session). ADDRESS is derived from UNIT_SUFFIX, the same token
  # that sets the live hostname (keephaven-<suffix>), so the printed .local
  # address always matches what avahi publishes.
  printIdentity = pkgs.writeShellScriptBin "cloudunit-print-identity" ''
    set -eu
    ssid=$(${pkgs.gnugrep}/bin/grep '^UNIT_SSID=' ${unitEnv} | ${pkgs.coreutils}/bin/cut -d= -f2-)
    pw=$(${pkgs.gnugrep}/bin/grep '^UNIT_PASSWORD=' ${unitEnv} | ${pkgs.coreutils}/bin/cut -d= -f2-)
    suffix=$(${pkgs.gnugrep}/bin/grep '^UNIT_SUFFIX=' ${unitEnv} | ${pkgs.coreutils}/bin/cut -d= -f2-)
    ${pkgs.coreutils}/bin/printf 'SSID=%s\nPASSWORD=%s\nADDRESS=keephaven-%s.local\n' "$ssid" "$pw" "$suffix"
  '';
in
{
  environment.systemPackages = [ printIdentity ];

  systemd.services.cloudunit-unit-bootstrap = {
    description = "Cloud Unit - per-unit identity bootstrap (sticker creds)";
    wantedBy = [ "multi-user.target" ];
    before = [ "cloudunit-ap-bootstrap.service" ];
    unitConfig = {
      ConditionPathExists = "!${unitEnv}";
      RequiresMountsFor = dataDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = genScript;
    };
  };
}
