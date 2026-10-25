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
      # The Pi 5 hardware entry: kernel, firmware, boot loader, image builder.
      piHardware = {
        imports = with nixos-raspberrypi.nixosModules; [
          raspberry-pi-5.base
          raspberry-pi-5.bluetooth
          sd-image
        ];
      };

      sharedModules = [ piHardware ] ++ productModules;

      # The product itself. Hardware-neutral except where a module reads
      # keephaven.platform (modules/platform.nix).
      productModules = [
        ./modules/platform.nix
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
        ./modules/agent-memory.nix
      ];

      # profile = dev/prod (access-profile.nix); edition = the app payload
      # (modules/editions.nix). edition defaults to "entertainment", so the two
      # original outputs build exactly as before.
      mkUnit = { profile, edition ? "entertainment", extra ? [ ] }: nixos-raspberrypi.lib.nixosSystem {
        specialArgs = inputs;
        modules = sharedModules ++ [ { keephaven.profile = profile; keephaven.edition = edition; } ] ++ extra;
      };

      # The PC target (x86-64, UEFI): Keephaven Photos SSD. Same product modules, a
      # different hardware entry (modules/pc-hardware.nix).
      # extraModules exists for ONE caller: the bench drive, which is the customer build plus
      # keephaven.allowUpdateUrlOverride. Empty for dev and prod, so appending it leaves their
      # evaluated config - and their outPaths - untouched.
      mkPc = { profile, edition ? "photos", extraModules ? [ ] }:
        nixos-raspberrypi.inputs.nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        # keephavenLauncher: what goes on the drive's Windows-visible partition, built from
        # launcher/. Passed in rather than imported in the module, so nothing about Windows
        # is even looked at unless a PC image is being built.
        specialArgs = inputs // {
          keephavenLauncher = import ./launcher/qemu-windows/launcher.nix {
            nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
            # null on a dirty tree; the drive then says so in its AGPL notice and the flash
            # check refuses it as a customer drive.
            rev = self.rev or null;
            agentMemory = edition == "agent-memory";
            versionOverride = if edition == "agent-memory" then agentmemSsdVersion else null;
          };
        };
        modules = [ ./modules/pc-hardware.nix ] ++ productModules
          ++ [ { keephaven.profile = profile; keephaven.edition = edition; } ]
          ++ nixos-raspberrypi.inputs.nixpkgs.lib.optional (edition == "agent-memory")
               { keephaven.imageVersion = nixos-raspberrypi.inputs.nixpkgs.lib.mkForce agentmemSsdVersion; }
          ++ extraModules;
      };

      # Agent memory (modules/agent-memory.nix) switched on. A dedicated output, never an
      # edit to a tracked file: the shipped outputs above keep it off and stay unchanged.
      memoryOn = [ { keephaven.agentMemory.enable = true; } ];
      # The Agent Memory editions' own release line (Pi and drive); the first is 2026.10.24.
      agentmemVersion = "2026.10.24";
      # The drive's own line from 2026.10.25: the 2026.10.24 drive could not look up any name
      # (modules/ap.nix), and a fixed build never reuses a version string.
      agentmemSsdVersion = "2026.10.25";
    in
    {
      # Twin systems from one source tree. dev = keyed + SSH on LAN (testing);
      # prod = keyless + SSH only over tailscale0 (ships to customers).
      nixosConfigurations.cloudunit-dev = mkUnit { profile = "dev"; };
      nixosConfigurations.cloudunit-prod = mkUnit { profile = "prod"; };

      # Photos edition — Immich only, same shared base. Flashed fresh; never an
      # update to an Entertainment box.
      nixosConfigurations.cloudunit-photos-dev = mkUnit { profile = "dev"; edition = "photos"; };
      nixosConfigurations.cloudunit-photos-prod = mkUnit { profile = "prod"; edition = "photos"; };

      # Agent memory gate builds: the Entertainment image with agent memory on.
      nixosConfigurations.cloudunit-memory-dev = mkUnit { profile = "dev"; extra = memoryOn; };
      nixosConfigurations.cloudunit-memory-prod = mkUnit { profile = "prod"; extra = memoryOn; };
      # Agent Memory edition: no apps, agent memory on (modules/editions.nix). Named apart from
      # cloudunit-memory-*, which is the banked Home build with memory switched on.
      # Its own release line; the first is 2026.10.24.
      nixosConfigurations.cloudunit-agentmem-dev = mkUnit { profile = "dev"; edition = "agent-memory"; extra = [ { keephaven.imageVersion = agentmemVersion; } ]; };
      nixosConfigurations.cloudunit-agentmem-prod = mkUnit { profile = "prod"; edition = "agent-memory"; extra = [ { keephaven.imageVersion = agentmemVersion; } ]; };

      # Complete bootable images to flash directly to the NVMe.
      packages.aarch64-linux.dev =
        self.nixosConfigurations.cloudunit-dev.config.system.build.sdImage;
      packages.aarch64-linux.prod =
        self.nixosConfigurations.cloudunit-prod.config.system.build.sdImage;
      packages.aarch64-linux.photos-prod =
        self.nixosConfigurations.cloudunit-photos-prod.config.system.build.sdImage;
      packages.aarch64-linux.photos-dev =
        self.nixosConfigurations.cloudunit-photos-dev.config.system.build.sdImage;
      packages.aarch64-linux.memory-dev =
        self.nixosConfigurations.cloudunit-memory-dev.config.system.build.sdImage;
      packages.aarch64-linux.memory-prod =
        self.nixosConfigurations.cloudunit-memory-prod.config.system.build.sdImage;
      packages.aarch64-linux.agentmem-dev =
        self.nixosConfigurations.cloudunit-agentmem-dev.config.system.build.sdImage;
      packages.aarch64-linux.agentmem-prod =
        self.nixosConfigurations.cloudunit-agentmem-prod.config.system.build.sdImage;

      # The PC target's drive image (Photos edition, dev profile for gating).
      nixosConfigurations.keephaven-pc-photos-dev = mkPc { profile = "dev"; };
      packages.x86_64-linux.pc-photos-dev =
        self.nixosConfigurations.keephaven-pc-photos-dev.config.system.build.sdImage;
      # The customer PC build — the twin of the above, exactly as the Pi has twins.
      # Everything proven on hardware up to 2026-10-13 was proven on the DEV image, which
      # carries the kh-admin key and answers sshd on the LAN. Nothing a stranger gets may.
      # access-profile.nix is the only module that branches on this, and it flips exactly two
      # things, so `nix store diff-closures` between these two must show only those two roots.
      nixosConfigurations.keephaven-pc-photos-prod = mkPc { profile = "prod"; };
      packages.x86_64-linux.pc-photos-prod =
        self.nixosConfigurations.keephaven-pc-photos-prod.config.system.build.sdImage;

      # The bench drive: the CUSTOMER build plus exactly one option, so a hardware update test
      # is not a test of a different drive. A buyer's drive refuses the update.conf feed override
      # because p5 is writable from Windows with no privileges (gate section 4a, his call
      # 2026-10-14: off for buyers, kept for testing); this build takes it back so a drive can be
      # pointed at the laptop feed without a 36 GB rebuild. NEVER flash this for anyone else and
      # never name it as a ship artifact: it differs from pc-photos-prod by this one option, which
      # is the point - `nix store diff-closures` between them must show only the update scripts.
      # Agent Memory edition on a drive (and in a VM): no apps, agent memory on. Not released.
      nixosConfigurations.keephaven-pc-agentmem-dev = mkPc { profile = "dev"; edition = "agent-memory"; };
      packages.x86_64-linux.pc-agentmem-dev =
        self.nixosConfigurations.keephaven-pc-agentmem-dev.config.system.build.sdImage;
      nixosConfigurations.keephaven-pc-agentmem-prod = mkPc { profile = "prod"; edition = "agent-memory"; };
      packages.x86_64-linux.pc-agentmem-prod =
        self.nixosConfigurations.keephaven-pc-agentmem-prod.config.system.build.sdImage;
      # The Agent Memory SSD's download: its writer and setup (editions/agent-memory/*.nix patch the
      # Photos SSD's programs without touching their folders) and the bundle.
      packages.x86_64-linux.agentmem-ssd-writer = import ./editions/agent-memory/writer.nix {
        nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
        imageVersion = self.nixosConfigurations.keephaven-pc-agentmem-prod.config.keephaven.imageVersion;
      };
      packages.x86_64-linux.agentmem-ssd-setup = import ./editions/agent-memory/setup.nix {
        nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
        imageVersion = self.nixosConfigurations.keephaven-pc-agentmem-prod.config.keephaven.imageVersion;
      };
      packages.x86_64-linux.pc-agentmem-download = import ./download.nix {
        nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
        image = self.packages.x86_64-linux.pc-agentmem-prod;
        writer = self.packages.x86_64-linux.agentmem-ssd-writer;
        imageVersion = self.nixosConfigurations.keephaven-pc-agentmem-prod.config.keephaven.imageVersion;
        fileBase = "keephaven-agent-memory-ssd";
        productName = "Keephaven Agent Memory SSD";
        howtoTried = "So far it's only run in a virtual machine on one PC, so keep a copy of\nanything that matters somewhere else too.";
        howtoDownloadGb = "3";
      };

      nixosConfigurations.keephaven-pc-photos-bench =
        mkPc { profile = "prod"; extraModules = [ { keephaven.allowUpdateUrlOverride = true; } ]; };
      packages.x86_64-linux.pc-photos-bench =
        self.nixosConfigurations.keephaven-pc-photos-bench.config.system.build.sdImage;

      # The program a buyer runs on Windows to put the image on a drive. Not part of any
      # image and never on a drive - it ships in the download beside the image. The version it
      # prints is the image's, tied together here so a support e-mail naming one names both.
      packages.x86_64-linux.ssd-writer = import ./writer/package.nix {
        nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
        imageVersion =
          self.nixosConfigurations.keephaven-pc-photos-prod.config.keephaven.imageVersion;
      };

      # The ONE file a buyer downloads. It fetches the image and the writer and starts the
      # writer; it never opens a disk, and the writer never opens a socket.
      packages.x86_64-linux.ssd-setup = import ./setup/package.nix {
        nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
        imageVersion =
          self.nixosConfigurations.keephaven-pc-photos-prod.config.keephaven.imageVersion;
      };

      # Everything a buyer gets in one directory: the image as gzip, the writer, and a
      # checksum for each. Built from the prod image and the writer above, so the three can
      # never be a version apart.
      packages.x86_64-linux.pc-photos-download = import ./download.nix {
        nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
        image = self.packages.x86_64-linux.pc-photos-prod;
        writer = self.packages.x86_64-linux.ssd-writer;
        imageVersion =
          self.nixosConfigurations.keephaven-pc-photos-prod.config.keephaven.imageVersion;
      };

      # VM tests. They run on the build machine (x86_64, KVM) against the same
      # nixpkgs the images use, and are not part of any image.
      checks.x86_64-linux.setup-screen = import ./tests/setup-screen.nix {
        pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.x86_64-linux;
      };

      # The PC target (keephaven.platform = "pc"), Photos edition, taken through
      # setup in a VM with the amd64 app images. Not released; see the test's header.
      # The buyer's drive must not honour UPDATE_BASE_URL in update.conf, and the bench build
      # must still honour it - a flag that silently stops working would take the hardware update
      # test with it. Reads the generated scripts themselves, so it cannot be fooled by the
      # option being set and the text being spliced in anyway. Gate section 4a.
      checks.x86_64-linux.ssd-no-url-override =
        let
          np = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.x86_64-linux;
          scriptsOf = cfg: "${cfg.systemd.services.cloudunit-update-check.serviceConfig.ExecStart} "
            + "${cfg.systemd.services.cloudunit-update-stage.serviceConfig.ExecStart}";
          ship = scriptsOf self.nixosConfigurations.keephaven-pc-photos-prod.config;
          bench = scriptsOf self.nixosConfigurations.keephaven-pc-photos-bench.config;
        in
        np.runCommand "ssd-no-url-override" { } ''
          shipped=0
          for f in ${ship}; do
            case "$f" in *.py) ;; *) continue ;; esac
            shipped=$((shipped + 1))
            if grep -q "UPDATE_BASE_URL=" "$f"; then
              echo "FAIL: a buyer's drive still reads the update.conf feed override: $f" >&2
              exit 1
            fi
          done
          [ "$shipped" = 2 ] || { echo "FAIL: expected 2 shipped scripts, found $shipped" >&2; exit 1; }

          benched=0
          for f in ${bench}; do
            case "$f" in *.py) ;; *) continue ;; esac
            if grep -q "UPDATE_BASE_URL=" "$f"; then benched=$((benched + 1)); fi
          done
          [ "$benched" = 2 ] || {
            echo "FAIL: the bench drive lost the override too ($benched of 2) - the hardware" >&2
            echo "      update test has no way to reach a laptop feed without a rebuild." >&2
            exit 1; }

          echo "the buyer's drive ignores update.conf; the bench drive still honours it"
          touch $out
        '';

      # Two Agent Memory edition boxes and a private headscale: pairing, the nightly sync, promote
      # and factory reset, with the real wrappers. See the test's header for what it asserts.
      checks.x86_64-linux.agentmem-backup-pair = import ./tests/agentmem-backup-pair.nix {
        pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.x86_64-linux;
        inherit productModules;
      };

      checks.x86_64-linux.pc-photos = import ./tests/pc-photos.nix {
        pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.x86_64-linux;
        inherit productModules;
        # The eight files that go on the drive's Windows-visible partition. The test has no
        # partitions (it leaves disk-layout.nix out), so it reads them from the build that
        # produces them rather than from a disk - which is also the only way to check them
        # without a real drive in the room.
        launcherFiles =
          let
            l = import ./launcher/qemu-windows/launcher.nix {
              nixpkgs = nixos-raspberrypi.inputs.nixpkgs;
              rev = self.rev or null;
            };
            shipped = self.nixosConfigurations.keephaven-pc-photos-prod.config.keephaven.imageVersion;
          in
          # launcher.nix PARSES the version out of pc-hardware.nix's text to build the tag. That
          # catches nothing if the option it ships under ever stops matching what the file says,
          # so tie the two together here: eval-time, zero cost, and the drive text's tag can
          # never name a version the image does not carry. The verifier's line.
          assert nixos-raspberrypi.inputs.nixpkgs.lib.assertMsg (l.imageVersion == shipped)
            "the launcher's parsed version ${l.imageVersion} is not the drive's ${shipped}";
          l;
      };

      checks.x86_64-linux.agent-memory = import ./tests/agent-memory.nix {
        pkgs = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.x86_64-linux;
      };

      # The memory server on its own, for an agent to try the API on any machine with Nix:
      #   nix run github:dafarusd/keephaven#agent-memory -- serve --data ./mem --dev-token <token>
      apps = nixos-raspberrypi.inputs.nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
        let p = nixos-raspberrypi.inputs.nixpkgs.legacyPackages.${system}; in {
          agent-memory = {
            type = "app";
            program = "${p.writeShellScript "agent-memory" ''exec ${p.python3}/bin/python3 ${./modules/agent-memory.py} "$@"''}";
          };
        });
    };
}
