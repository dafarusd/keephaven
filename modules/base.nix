
{ config, pkgs, lib, ... }:

{

  # ----- Identity -----

  # Pre-identity fallback hostname. Each unit overrides this at runtime to
  # keephaven-<suffix> via cloudunit-set-hostname (below), which runs after the
  # per-unit identity is generated and BEFORE avahi publishes. Two units on one
  # LAN must never both claim keephaven.local.
  networking.hostName = "keephaven";

  # ----- Locale / Time (default; wizard overrides later) -----

  time.timeZone = "America/New_York";

  i18n.defaultLocale = "en_US.UTF-8";

  # ----- Networking -----

  # Ethernet via DHCP; WiFi added later.

  networking.useDHCP = lib.mkDefault true;

  # ----- Users -----

  # Single admin / break-glass landing account. Renamed from the old "dafarus"
  # (a shipping info-leak). authorizedKeys is NOT set here: access-profile.nix is
  # the SOLE writer of kh-admin's keys (dev key present / prod empty) — that file
  # owns diff root #1 and the dev/prod oracle keys on it. hashedPassword = "!"
  # locks password login (key-only); PasswordAuthentication is off regardless.
  users.users.kh-admin = {

    isNormalUser = true;

    description = "Admin";

    hashedPassword = "!";

    extraGroups = [ "wheel" "networkmanager" ];

  };

  # Allow wheel group sudo without password (dev convenience; revisit for production)

  security.sudo.wheelNeedsPassword = false;

  # ----- SSH -----

  services.openssh = {

    enable = true;

    settings = {

      PasswordAuthentication = false;

      PermitRootLogin = "no";

    };

  };

  # ----- mDNS (.local discovery) -----
  # Advertise keephaven.local on the LAN so customers reach the unit by name.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    # Empty => no host-name= line in avahi-daemon.conf => avahi follows the live
    # OS hostname (gethostname()) at the moment avahi-daemon.service starts. This
    # is what lets cloudunit-set-hostname's runtime keephaven-<suffix> get
    # published. A non-empty value would hardcode host-name= and avahi would
    # ignore the live hostname.
    hostName = "";
    # Disable IPv6 publish. nssmdns6 is off (v4-only resolver), and dual-stack
    # publish is a self-rename footgun in the same CLASS as the Docker-bridge
    # self-collision already pinned via allowInterfaces (different trigger:
    # dual-stack v4+v6 publish racing itself).
    ipv6 = false;
    # Only advertise on the real LAN (cable) and AP interfaces. Without this,
    # avahi also publishes keephaven.local on Docker's container interfaces
    # (br-*, veth*, docker0 with 169.254.x link-local IPs). When the service
    # containers start, those interfaces appear and avahi self-collides on the
    # name, withdraws "keephaven", and renames the host to "keephaven-2"
    # pointing at a useless link-local address - breaking keephaven.local.
    # Restricting to the real interfaces prevents the self-collision entirely.
    allowInterfaces = [ "end0" "wlan0" ];
    publish = {
      enable = true;
      addresses = true;
      domain = true;
    };
    # use-ipv6=no disables the v6 TRANSPORT (kills the dual-stack self-rename),
    # but avahi still advertises an AAAA record over v4 by default
    # (publish-aaaa-on-ipv4=yes). The resolver here is v4-only, so an advertised
    # AAAA serves nothing we use - it only lets a dual-stack client (e.g. macOS
    # getaddrinfo) prefer a link-local/unroutable GUA and intermittently fail to
    # reach the box. Suppress it for a fully v4-only advertisement.
    extraConfig = ''
      [publish]
      publish-aaaa-on-ipv4=no
    '';
  };

  # Set the per-unit mDNS hostname (keephaven-<suffix>) from the generated
  # identity, every boot, BEFORE avahi publishes. Ordering is the PRIMARY
  # mechanism: bootstrap (writes UNIT_SUFFIX) -> set-hostname -> avahi-daemon,
  # all in the boot transaction, so on the very first boot avahi comes up under
  # the unique name the first time - never keephaven.local-then-rename. The
  # avahi try-restart at the end is a FALLBACK for the pathological case where a
  # .local lookup socket-triggers avahi-daemon before this oneshot runs.
  systemd.services.cloudunit-set-hostname = {
    description = "Cloud Unit - set per-unit mDNS hostname from identity";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloudunit-unit-bootstrap.service" ];
    before = [ "avahi-daemon.service" ];
    unitConfig.RequiresMountsFor = "/var/lib/cloudunit";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "cloudunit-set-hostname" ''
        set -u
        ENVF=/var/lib/cloudunit/unit.env
        if [ ! -r "$ENVF" ]; then
          echo "set-hostname: $ENVF absent; keeping fallback hostname"
          exit 0
        fi
        SUFFIX="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_SUFFIX=/{print $2; exit}' "$ENVF")"
        if [ -z "$SUFFIX" ]; then
          echo "set-hostname: UNIT_SUFFIX empty/missing; keeping fallback hostname"
          exit 0
        fi
        NEW="keephaven-$SUFFIX"
        ${pkgs.systemd}/bin/hostnamectl set-hostname "$NEW" \
          || ${pkgs.nettools}/bin/hostname "$NEW"
        echo "set-hostname: hostname set to $NEW"
        # Fallback only: no-op if avahi-daemon has not started yet.
        ${pkgs.systemd}/bin/systemctl try-restart avahi-daemon.service || true
      '';
    };
  };

  # ----- Basic tooling -----

  environment.systemPackages = with pkgs; [

    vim

    git

    htop

    curl

    wget

    tmux

  ];

  # ----- Nix settings -----

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # ----- State version: do not change after first deploy -----

  networking.firewall.allowedTCPPorts = [ 80 ];
  networking.firewall.allowedUDPPorts = [ 5353 ];
  system.stateVersion = "25.05";

}

