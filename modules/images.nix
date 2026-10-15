# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

let
  dataDir = "/var/lib/cloudunit";

  # ----- Single source of truth: frozen arm64 image pins -----
  #
  # Each entry pins ONE image to its **linux/arm64 manifest digest** (NOT the
  # multi-arch manifest-list digest) plus the nix fixed-output hash of the
  # pulled docker-archive. This attrset is the ONLY place a digest is written:
  # it renders into BOTH the `pullImage` (imageDigest) AND the compose `image:`
  # ref (via the generated image-env below), so the baked image and the runtime
  # reference are derived from the same value and cannot drift.
  #
  # The loaded image is tagged `<name>:kh-<digest12>` (an owned tag carrying the
  # digest, never an upstream mutable tag like :latest/:release). compose uses
  # that exact tag with `pull_policy: never`, so at runtime docker either finds
  # the pinned local image or fails loudly.
  #
  # MAINTENANCE: updating an image is a deliberate act — re-resolve its arm64
  # digest + nix hash (nix-prefetch-docker --arch arm64 --image-digest …) and
  # bump it HERE, then rebuild. There is intentionally no auto-update path; the
  # whole point of pre-baking is a fixed, offline, ship-forever image set.
  # PC target (keephaven.platform = "pc"): an image may also carry amd64Digest +
  # amd64NixHash, the linux/amd64 manifest from the SAME upstream index as its
  # arm64 pin (checked against the registry 2026-10-06: immich v3.0.3 for the two
  # immich images, the postgres index immich v3.0.3 pins, and for valkey 8.1.3 the
  # 8-bookworm index immich v2.0.0 pinned, which is where the arm64 pin sits).
  # Only the four Photos images have one so far.
  images = {
    # Immich v3.0.3 (bumped from v2.7.5, 2026.07.26 release). Unmodified upstream,
    # arm64 digests resolved via skopeo + nix-prefetch-docker. Postgres image
    # unchanged v2->v3 (same ghcr.io/immich-app/postgres, PG14/VectorChord) — the
    # pgvecto.rs->VectorChord migration was already done pre-v2.7.5, so v3 is a plain
    # image bump for us. See docs/shipped-versions.json + decisions.md.
    immich-server = {
      name = "ghcr.io/immich-app/immich-server";
      arm64Digest = "sha256:b0db439867e1765b785dc0d3fc425fe9d0e8fcd135dba7b2f010151d54af26f7";
      nixHash = "sha256-6Zv55LC66r4xUDW808qt0NrwEbPdq0b3jAEMml1VIvo=";
      amd64Digest = "sha256:118946756b2274f741be9d301428401be8716024c407b019cd424fa1e6f518e6";
      amd64NixHash = "sha256-ggIRQ7/H7ROL2f2ruOZK0JCPrZaHHBMRbTFEZUor8p4=";
    };
    immich-machine-learning = {
      name = "ghcr.io/immich-app/immich-machine-learning";
      arm64Digest = "sha256:6b81a6951db55a466de30f0aeb56854b79fdf7adcf943f4d9407a3f26513947c";
      nixHash = "sha256-NpEWNCp4m5BMKUMIA+V14fe6h8sbynFkk0F4+dBTn+I=";
      amd64Digest = "sha256:fbb2485a6ec1877697d003a7d81d445bd8aea3248a866aa1c3d75b9e134787d0";
      amd64NixHash = "sha256-AtTrJ1/eWpzrLp4YJC9iQWNirKNevmIW4xYILxHZZIY=";
    };
    valkey = {
      name = "valkey/valkey";
      arm64Digest = "sha256:0e28101f7e5acb939f4e5152b09760b49ba61f278fbf10f6f1d9c45fbbd3f3c7";
      nixHash = "sha256-LCUiOaaGXBA8/enOPW+rYmljjrRMWtefRasFEd8bqb8=";
      amd64Digest = "sha256:4a7d243f2890e13198440dcfc8d24c9adf9d4fc4092389c89c12a6fda43d3704";
      amd64NixHash = "sha256-jg3UjUVl58EXlLEngaIGPAlrkfGZiuTwdLu/DmMV40E=";
    };
    immich-postgres = {
      name = "ghcr.io/immich-app/postgres";
      arm64Digest = "sha256:6244e923bfde05b58bc4fc26b21025415c166c6239b6b9886fb0e806dcc99001";
      nixHash = "sha256-c0gk1O2zWRVnnPcIbiIY6G8ELzz6F85wC+CrpovVd68=";
      amd64Digest = "sha256:b1d33572a9a0634aa6d344077467ad32847812a37fa3859f702952cba22a2f55";
      amd64NixHash = "sha256-SijCUCqSKJRvPcLHdh9L46OiCrs2Z4tPEI6iW5Gxszw=";
    };
    jellyfin = {
      name = "ghcr.io/jellyfin/jellyfin";
      arm64Digest = "sha256:2961aa1e97515b4e3bca9149ad3fce1599bdd67df970e50bb28aaff1731def01";
      nixHash = "sha256-1O2xm3uFrFXA7CDe4vwr2twZ7xvCwPev4Fz7VlDFSOA=";
    };
    navidrome = {
      name = "deluan/navidrome";
      arm64Digest = "sha256:1140169248df4b89709861b19eb3a0f2feb77343c7dc89c0de5c203299f37665";
      nixHash = "sha256-8JPSCrq7C2j/Qnrx0vRYJcPJB4g1CK4dQb0vm+wKiN8=";
    };
    audiobookshelf = {
      name = "ghcr.io/advplyr/audiobookshelf";
      arm64Digest = "sha256:3484d1fd10fa61a89bb2b5f4747daba91c950122cecf7104d11e14c5091d5117";
      nixHash = "sha256-LVEVR4/7+74zvIqpxBs3XWTK116Oo9vGovIVTfmtB4w=";
    };
    kavita = {
      name = "jvmilazz0/kavita";
      arm64Digest = "sha256:5a8becf2837e8e8a6138f363cb559275ef513730ef9391e2fb4f2ce8e333ef5f";
      nixHash = "sha256-cuU4v0bvkgevXBwho2k376sVTuegkH8x1tnkWoK9Flw=";
    };
    freshrss = {
      name = "freshrss/freshrss";
      arm64Digest = "sha256:0821649c78527e14ed73018e5122001b1c58f98a4c9b0c8ad1b9277d15769d54";
      nixHash = "sha256-5pC9Q1XIwY2rfY2gYun28Ut76SHZ4zbEHGWjjDX3PgI=";
    };
  };

  # ----- Derive everything from the pin (one value, rendered everywhere) -----
  # "sha256:" is 7 chars; take the next 12 hex of the digest for the owned tag.
  # Which architecture this build bakes: arm64 on the Pi, amd64 on the PC target.
  # An image without an amd64 pin stops a PC build at evaluation, by name.
  arch = if pkgs.stdenv.hostPlatform.isx86_64 then "amd64" else "arm64";
  digestOf = img:
    if arch == "amd64"
    then img.amd64Digest or (throw "images.nix: ${img.name} has no amd64 pin yet")
    else img.arm64Digest;
  hashOf = img: if arch == "amd64" then img.amd64NixHash else img.nixHash;
  digest12 = img: builtins.substring 7 12 (digestOf img);
  # The images that have a pin for this architecture. On arm64 that is all of
  # them. On amd64 it is the ones pinned so far; an edition that bakes one of the
  # others still stops at evaluation (digestOf above).
  pinnedHere = lib.filterAttrs (_: img: arch != "amd64" || img ? amd64Digest) images;
  pinnedTag = img: "kh-${digest12 img}";
  pinnedRef = img: "${img.name}:${pinnedTag img}";

  # docker-archive (uncompressed) for one image: content-addressed by the arm64
  # manifest digest, tagged with our owned pinned tag. arch is pinned too so the
  # bake is unambiguously the arm64 image regardless of the build host.
  pullArchive = img: pkgs.dockerTools.pullImage {
    imageName = img.name;
    imageDigest = digestOf img;
    sha256 = hashOf img;
    inherit arch;
    os = "linux";
    finalImageName = img.name;
    finalImageTag = pinnedTag img;
  };

  # zstd each archive. Measured on the Pi 5 (immich-server, 1.3 GiB raw): zstd
  # decompresses in ~3.5s vs gzip's ~7.2s (~2.1x), and -19 ships ~26% smaller
  # than gzip. We decompress explicitly (`zstd -dc | docker load`) rather than
  # relying on docker's auto-detect, so the load is fed by a fast codec. The
  # decode is single-threaded (a -19 single-frame stream does not parallelize on
  # decompress — -T0 and -T1 wall-time identically, confirmed on the tarballs),
  # so the runtime loader pins -T1: six parallel loaders each requesting all-core
  # zstd pools bought nothing but thrash on a 4-core box.
  zstdImages = lib.mapAttrs
    (key: img: pkgs.runCommand "cloudunit-img-${key}.tar.zst"
      { nativeBuildInputs = [ pkgs.zstd ]; }
      ''zstd -q -19 -T0 -o $out ${pullArchive img}'')
    images;

  # image-env: VAR=<pinned ref>, rendered from the SAME `images` attrset. Loaded
  # into each service unit's environment (see services.nix) so compose's
  # `image: ${…}` substitution resolves to the frozen pinned ref.
  envVar = key: "${lib.toUpper (builtins.replaceStrings ["-"] ["_"] key)}_IMAGE";
  imageEnv = pkgs.writeText "cloudunit-images.env"
    (lib.concatStrings
      (lib.mapAttrsToList (key: img: "${envVar key}=${pinnedRef img}\n") pinnedHere));

  # Service -> the image keys its compose stack needs. Drives ONE loader unit per
  # service so each cloudunit-<svc> starts as soon as ITS images are in the docker
  # store, instead of all six waiting for the whole 1.93 GiB batch. The six
  # loaders have no ordering between them, so systemd runs them in parallel across
  # the idle cores; the five light services come up in seconds while Immich's
  # heavy stack finishes in the background.
  # Edition switch (modules/editions.nix): keep only the active edition's apps.
  # Dropping an app here drops BOTH its loader unit AND its baked image tarballs
  # from the closure (the tarballs are referenced only by the loader scripts), so
  # a Photos box bakes just Immich's images. filterAttrs preserves attr order, so
  # for entertainment (all six active) the result is identical to before.
  serviceImages = lib.filterAttrs (name: _: builtins.elem name config.keephaven.activeApps) {
    immich = [ "immich-server" "immich-machine-learning" "immich-postgres" "valkey" ];
    jellyfin = [ "jellyfin" ];
    navidrome = [ "navidrome" ];
    audiobookshelf = [ "audiobookshelf" ];
    kavita = [ "kavita" ];
    freshrss = [ "freshrss" ];
  };

  mkLoadScript = svc: keys: pkgs.writeShellScript "cloudunit-image-load-${svc}" ''
    set -euo pipefail
    load_one() {
      ref="$1"; tar="$2"
      if ${pkgs.docker}/bin/docker image inspect "$ref" >/dev/null 2>&1; then
        echo "cloudunit-image-load(${svc}): present  $ref"
      else
        echo "cloudunit-image-load(${svc}): loading  $ref"
        ${pkgs.zstd}/bin/zstd -dc -T1 "$tar" | ${pkgs.docker}/bin/docker load
      fi
    }
    ${lib.concatMapStrings
        (key: "    load_one ${lib.escapeShellArg (pinnedRef images.${key})} ${zstdImages.${key}}\n")
        keys}
    echo "cloudunit-image-load(${svc}): done"
  '';

  mkLoadService = svc: keys: {
    "cloudunit-image-load-${svc}" = {
      description = "Cloud Unit - load ${svc} Docker images (offline)";
      after = [ "docker.service" ];
      requires = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];
      unitConfig.RequiresMountsFor = dataDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "10s";
        # First-boot contention control. The six loaders fire in parallel (no
        # ordering between them — that's the light-service speed win), but the
        # docker-load pipelines must not starve tailscaled or the Settings UI.
        # Soft caps below the default weight (100): under contention the load
        # work yields CPU/IO to interactive/network services, while an otherwise
        # idle box still gets used fully — so the parallel win is preserved.
        CPUWeight = 20;
        IOWeight = 20;
        Nice = 10;
        ExecStart = mkLoadScript svc keys;
      };
    };
  };
in
{
  # Expose the pinned refs to compose. Consumed via EnvironmentFile in
  # services.nix so `${…}` substitution in each compose file resolves.
  environment.etc."cloudunit/compose/images.env".source = imageEnv;

  # ----- Pre-baked image loaders (userspace, offline, idempotent, per-service) --
  #
  # One loader unit per service loads the baked zstd tarballs into the docker
  # store on the data partition, decompressing with `zstd -dc -T0 | docker load`.
  # Each is wired into the Phase-2 mount rail: after docker.service + the data
  # mount, before its own cloudunit-<svc> unit (that ordering is added in
  # services.nix). The per-image `docker image inspect` guard makes a warm reboot
  # (store already populated on the persistent data partition) skip the reload; a
  # cold or wiped store re-seeds entirely from the tarballs with no network — the
  # Phase-3 Model-A "self-heal offline" property. The split touches ONLY the
  # docker + data-mount branch; it has no edge to tailscaled, the leak guard, or
  # unit-bootstrap, so the security ordering hardened in tailscale.nix is intact.
  systemd.services = lib.mkMerge (lib.mapAttrsToList mkLoadService serviceImages);
}
