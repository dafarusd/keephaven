# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{
  description = "cloud-image: self-hosted private cloud appliance for Raspberry Pi 5";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixos-raspberrypi.url = "github:nvmd/nixos-raspberrypi/main";
  };

  nixConfig = {
    extra-substituters = [ "https://nixos-raspberrypi.cachix.org" ];
    extra-trusted-public-keys = [
      "nixos-raspberrypi.cachix.org-1:4iMO9LXa8BqhU+Rpg6LQKiGa2lsNh/j2oiYLNOQ5sPI="
    ];
  };

  outputs = { self, nixpkgs, nixos-raspberrypi, ... }@inputs:
    let
      # ONE shared module list, consumed twice. There is no second hand-
      # maintained image definition to drift: dev and prod are the SAME
      # evaluated code, differing ONLY by the keephaven.profile value injected
      # below (which access-profile.nix turns into the two-root access diff).
      sharedModules = [
        {
          imports = with nixos-raspberrypi.nixosModules; [
            raspberry-pi-5.base
            raspberry-pi-5.bluetooth
            sd-image
          ];
        }
        ./modules/access-profile.nix
        ./modules/support-access.nix
        ./modules/base.nix
        ./modules/disk-layout.nix
        ./modules/docker.nix
        ./modules/images.nix
        ./modules/services.nix
        ./modules/wizard.nix
        ./modules/dashboard.nix
        ./modules/samba.nix
        ./modules/tailscale.nix
        ./modules/immich-dump.nix
        ./modules/replication.nix
        ./modules/replication-sender.nix
        ./modules/replication-target.nix
        ./modules/backup-mode.nix
        ./modules/promote.nix
        ./modules/wireless.nix
        ./modules/ap.nix
        ./modules/settings.nix
        ./modules/captive.nix
        ./modules/credentials.nix
        ./modules/setup-screen.nix
        ./modules/provision.nix
        ./modules/finalize.nix
        ./modules/update.nix
      ];

      mkUnit = profile: nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs;
        modules = sharedModules ++ [ { keephaven.profile = profile; } ];
      };
    in
    {
      # Twin systems from one source tree. dev = keyed + SSH on LAN (testing);
      # prod = keyless + SSH only over tailscale0 (ships to customers).
      nixosConfigurations.cloudunit-dev = mkUnit "dev";
      nixosConfigurations.cloudunit-prod = mkUnit "prod";

      # Complete bootable images to flash directly to the NVMe.
      packages.aarch64-linux.dev =
        self.nixosConfigurations.cloudunit-dev.config.system.build.sdImage;
      packages.aarch64-linux.prod =
        self.nixosConfigurations.cloudunit-prod.config.system.build.sdImage;
    };
}
