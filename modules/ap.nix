# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  apEnv = "${dataDir}/ap.env";
  hostapdConf = "/run/cloudunit/hostapd.conf";

  defaultSsid = "Keephaven-Setup";
  defaultPassword = "keephaven";

  renderScript = pkgs.writeShellScript "cloudunit-render-hostapd" ''
    set -e
    mkdir -p /run/cloudunit
    AP_SSID="${defaultSsid}"
    AP_PASSWORD="${defaultPassword}"
    if [ -f ${apEnv} ]; then
      . ${apEnv}
    fi
    cat > ${hostapdConf} <<EOF
channel=6
country_code=US
driver=nl80211
ht_capab=[HT20][SHORT-GI-20]
hw_mode=g
ieee80211ac=1
ieee80211d=1
ieee80211h=1
ieee80211n=1
noscan=0
require_ht=0
require_vht=0
interface=wlan0
ap_isolate=0
auth_algs=1
ctrl_interface=/run/hostapd
ctrl_interface_group=wheel
ieee80211w=1
ignore_broadcast_ssid=0
macaddr_acl=0
rsn_pairwise=CCMP
sae_require_mfp=1
ssid=$AP_SSID
utf8_ssid=1
wmm_enabled=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=CCMP
wpa_passphrase=$AP_PASSWORD
EOF
    chmod 600 ${hostapdConf}
  '';
in
{
  networking.interfaces.wlan0.ipv4.addresses = [
    { address = "192.168.50.1"; prefixLength = 24; }
  ];
  networking.networkmanager.unmanaged = [ "wlan0" ];

  systemd.services.cloudunit-ap-bootstrap = {
    description = "Cloud Unit - AP config bootstrap (seeds ap.env from unit.env)";
    wantedBy = [ "multi-user.target" ];
    before = [ "cloudunit-hostapd.service" ];
    after = [ "cloudunit-unit-bootstrap.service" ];
    wants = [ "cloudunit-unit-bootstrap.service" ];
    unitConfig = {
      ConditionPathExists = "!${apEnv}";
      RequiresMountsFor = dataDir;
    };
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    script = ''
      # Seed the AP live config from the unit factory identity (sticker creds
      # in unit.env). Fall back to dev defaults only if unit.env is somehow
      # absent, so the box always comes up with an AP.
      AP_SSID="${defaultSsid}"
      AP_PASSWORD="${defaultPassword}"
      if [ -f ${dataDir}/unit.env ]; then
        . ${dataDir}/unit.env
        AP_SSID="$UNIT_SSID"
        AP_PASSWORD="$UNIT_PASSWORD"
      fi
      cat > ${apEnv} <<EOF
AP_SSID=$AP_SSID
AP_PASSWORD=$AP_PASSWORD
EOF
      chmod 600 ${apEnv}
    '';
  };

  systemd.services.cloudunit-hostapd = {
    description = "Cloud Unit - WiFi AP (hostapd, self-managed)";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloudunit-ap-bootstrap.service" "network.target" ];
    wants = [ "cloudunit-ap-bootstrap.service" ];
    unitConfig.RequiresMountsFor = dataDir;
    serviceConfig = {
      Type = "simple";
      ExecStartPre = "${renderScript}";
      ExecStart = "${pkgs.hostapd}/bin/hostapd ${hostapdConf}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  services.dnsmasq = {
    enable = true;
    settings = {
      interface = "wlan0";
      bind-interfaces = true;
      dhcp-range = "192.168.50.50,192.168.50.150,255.255.255.0,24h";
      dhcp-option = [
        "3,192.168.50.1"
        "6,192.168.50.1"
      ];
      server = [ "1.1.1.1" "8.8.8.8" ];
    };
  };
  # AP-side name resolution for the box's OWN .local names. Phones on wlan0 get
  # dnsmasq (192.168.50.1) as their DNS server (DHCP option 6 above); a unicast
  # A query for keephaven-<suffix>.local would otherwise be forwarded upstream
  # (1.1.1.1/8.8.8.8) and come back NXDOMAIN. We answer it locally with the AP
  # IP. This is the phone's setup path: the AP client resolves .local here (Android
  # does not do reliable mDNS), so "open keephaven-<suffix>.local" reaches the
  # wizard, and the same record serves the post-setup dashboard.
  #
  # AP-scoped only: dnsmasq is interface=wlan0 + bind-interfaces, so this record
  # is served ONLY on the AP. LAN clients on end0 resolve .local via avahi mDNS,
  # which is untouched.
  #
  # The drop-in lives in the conf-dir set by captive.nix (/run/cloudunit/dnsmasq.d
  # on tmpfs). Rendered every boot because /run is tmpfs. (There is no longer a
  # captive DNS hijack sharing this dir -- it was removed because address=/#/
  # broke Android's connectivity check on the AP; see captive.nix.)
  systemd.services.cloudunit-ap-dns = {
    description = "Cloud Unit - AP-side DNS for keephaven-<suffix>.local";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloudunit-unit-bootstrap.service" "systemd-tmpfiles-setup.service" ];
    wants = [ "cloudunit-unit-bootstrap.service" ];
    before = [ "dnsmasq.service" ];
    unitConfig.RequiresMountsFor = dataDir;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cloudunit-ap-dns" ''
        set -u
        ${pkgs.coreutils}/bin/mkdir -p /run/cloudunit/dnsmasq.d
        OUT=/run/cloudunit/dnsmasq.d/kh-hostname.conf
        SUFFIX="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_SUFFIX=/{print $2; exit}' ${dataDir}/unit.env 2>/dev/null)"
        {
          echo 'address=/keephaven.local/192.168.50.1'
          [ -n "$SUFFIX" ] && echo "address=/keephaven-$SUFFIX.local/192.168.50.1"
        } > "$OUT"
        echo "ap-dns: wrote $OUT (suffix=''${SUFFIX:-none})"
      '';
    };
  };

  systemd.services.dnsmasq = {
    after = [ "cloudunit-hostapd.service" "network-online.target" "cloudunit-ap-dns.service" ];
    wants = [ "network-online.target" "cloudunit-ap-dns.service" ];
    unitConfig.RequiresMountsFor = dataDir;
  };

  networking.firewall.interfaces.wlan0.allowedUDPPorts = [ 53 67 ];
  networking.firewall.interfaces.wlan0.allowedTCPPorts = [ 53 ];

  boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
  networking.nat = {
    enable = true;
    externalInterface = "end0";
    internalInterfaces = [ "wlan0" ];
  };
}
