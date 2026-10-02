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
        ./modules/editions.nix
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

      # profile = dev/prod; edition = the app payload (modules/editions.nix).
      # edition defaults to entertainment, so the two original outputs are unchanged.
      mkUnit = { profile, edition ? "entertainment" }: nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs;
        modules = sharedModules ++ [ { keephaven.profile = profile; keephaven.edition = edition; } ];
      };
    in
    {
      # Twin systems from one source tree. dev = keyed + SSH on LAN (testing);
      # prod = keyless + SSH only over tailscale0 (ships to customers).
      nixosConfigurations.cloudunit-dev = mkUnit { profile = "dev"; };
      nixosConfigurations.cloudunit-prod = mkUnit { profile = "prod"; };

      # Photos edition — Immich only, same shared base. Flashed fresh.
      nixosConfigurations.cloudunit-photos-dev = mkUnit { profile = "dev"; edition = "photos"; };
      nixosConfigurations.cloudunit-photos-prod = mkUnit { profile = "prod"; edition = "photos"; };

      # Complete bootable images to flash directly to the NVMe.
      packages.aarch64-linux.dev =
        self.nixosConfigurations.cloudunit-dev.config.system.build.sdImage;
      packages.aarch64-linux.prod =
        self.nixosConfigurations.cloudunit-prod.config.system.build.sdImage;
      packages.aarch64-linux.photos-prod =
        self.nixosConfigurations.cloudunit-photos-prod.config.system.build.sdImage;
      packages.aarch64-linux.photos-dev =
        self.nixosConfigurations.cloudunit-photos-dev.config.system.build.sdImage;
    };
}
