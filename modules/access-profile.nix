{ config, pkgs, lib, ... }:

# ============================================================================
# ACCESS PROFILE — the ONLY module that branches on dev vs prod.
#
# Twin-image guarantee (design §B/§C): dev and prod are built from ONE shared
# module list; this file is the ENTIRE access-surface difference between them.
# It flips EXACTLY TWO things, and nothing else anywhere may flip on profile:
#
#   diff root #1 — the kh-admin admin SSH key (present on dev, ABSENT on prod)
#   diff root #2 — sshd LAN exposure via openssh.openFirewall (open on dev,
#                  closed on prod => 22 reachable only over tailscale0)
#
# `nix store diff-closures <dev> <prod>` must show ONLY these two roots and
# their pure dependents (firewall ruleset, etc/system-path activation). Any
# third differing store path voids the guarantee — STOP and investigate.
#
# This file is also the SOLE writer of kh-admin's authorizedKeys. The boot-time
# tailscale-state-guard keys its dev/prod oracle on the presence of that key
# file (`test -s /etc/ssh/authorized_keys.d/kh-admin`). The dangerous failure is
# a PROD box reading itself as DEV (skipping leak enforcement). That is
# impossible here because: prod sets the list to [] (=> empty/absent key file),
# this is the only writer, and there is no code path that adds a key on prod.
# ============================================================================

let
  cfg = config.keephaven;

  # Dev admin PUBLIC key — YOUR key, not the vendor's. The dev image bakes it so
  # you can SSH into your own bench box as kh-admin. Put a one-line public key
  # in keys/dev-admin.pub (gitignored) and `git add -f` it before building dev,
  # because flakes only see tracked files. Prod never reads this: it is keyless.
  devKeyFile = ../keys/dev-admin.pub;
  devAdminKey =
    if builtins.pathExists devKeyFile
    then lib.removeSuffix "\n" (builtins.readFile devKeyFile)
    else throw ''
      The dev image needs your own SSH public key and none was found.
      Put it in keys/dev-admin.pub, then run: git add -f keys/dev-admin.pub
      (The prod image is keyless and does not need this.)
    '';
in
{
  options.keephaven.profile = lib.mkOption {
    type = lib.types.enum [ "dev" "prod" ];
    # Fail-SAFE default: an unset/forgotten profile yields the KEYLESS image,
    # never an accidental keyed box. The dev image must be asked for explicitly.
    default = "prod";
    description = ''
      Access-surface profile selecting the dev/prod twin.
      "dev": bakes the kh-admin admin SSH key and opens sshd on the LAN for
      full-visibility testing.
      "prod": ships keyless (no vendor key); sshd reachable only over tailscale0.
      This is the ONLY option that differs between the twin images.
    '';
  };

  config = {
    # diff root #1 — admin authorized key. Empty list on prod => no key file
    # content => guard oracle reads "prod" and enforces leak protection.
    users.users.kh-admin.openssh.authorizedKeys.keys =
      lib.optional (cfg.profile == "dev") devAdminKey;

    # diff root #2 — sshd LAN exposure. prod => false => 22 only via the
    # already-trusted tailscale0 interface (tailscale.nix).
    services.openssh.openFirewall = (cfg.profile == "dev");
  };
}
