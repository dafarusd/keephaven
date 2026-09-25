{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  setupFlag = "${dataDir}/.setup-complete";
  dropinDir = "/run/cloudunit/dnsmasq.d";
in
{
  # dnsmasq drop-in dir. cloudunit-ap-dns (ap.nix) writes the
  # keephaven-<suffix>.local -> 192.168.50.1 record here, which is how the setup
  # phone (an AP client) resolves .local on the AP. This conf-dir setting is
  # required for that record to be read, so it stays even though the captive
  # hijack that used to also live here was removed.
  services.dnsmasq.settings.conf-dir = dropinDir;
  systemd.tmpfiles.rules = [ "d ${dropinDir} 0755 root root -" ];

  # REMOVED: the captive-portal DNS hijack (address=/#/192.168.50.1).
  # It resolved EVERY name to the wizard, including the OS connectivity-check
  # domains. On the AP that made Android's connectivity check fail -> Android
  # flagged the AP as captive/no-internet and routed normal traffic (browser
  # keephaven-<suffix>.local lookups) over cellular, where .local does not
  # resolve -> the proven "plug in Ethernet, open keephaven-<suffix>.local from
  # the phone" setup path broke. The hijack only ever powered captive auto-pop,
  # which was never relied on and did not work on Android anyway. The real setup
  # paths are the .local record above and the fixed AP IP http://192.168.50.1 on
  # the sticker. See docs/ledger/ideas-backlog.md.

  # Readiness gate: hold DHCP (dnsmasq) until the setup wizard is answering on
  # :80, PRE-SETUP ONLY -- so an AP client cannot get a lease and open the wizard
  # (via keephaven-<suffix>.local -> 192.168.50.1, or the fixed IP) before :80 is
  # live. The wizard is Type=simple, so ordering alone is not enough; we probe the
  # socket directly. Bounded ~30s then proceeds, so a wizard fault can never brick
  # the AP or DHCP.
  systemd.services.cloudunit-wizard-ready = {
    description = "Cloud Unit - wait for setup wizard :80 before serving DHCP";
    wantedBy = [ "multi-user.target" ];
    before = [ "dnsmasq.service" ];
    after = [ "cloudunit-wizard.service" ];
    wants = [ "cloudunit-wizard.service" ];
    unitConfig = {
      ConditionPathExists = "!${setupFlag}";
      RequiresMountsFor = dataDir;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "wizard-ready" ''
        i=0
        while [ "$i" -lt 30 ]; do
          if (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null; then
            exec 3>&- 3<&- || true
            echo "wizard-ready: :80 is answering"
            exit 0
          fi
          i=$((i + 1))
          ${pkgs.coreutils}/bin/sleep 1
        done
        echo "wizard-ready: timed out waiting for :80; starting DHCP anyway"
        exit 0
      '';
    };
  };

  # Order dnsmasq after the readiness gate (merged with ap.nix's dnsmasq
  # ordering; after/wants are lists). The gate is ConditionPathExists=!setup, so
  # post-setup it is skipped and this is a no-op.
  systemd.services.dnsmasq = {
    after = [ "cloudunit-wizard-ready.service" ];
    wants = [ "cloudunit-wizard-ready.service" ];
  };
}
