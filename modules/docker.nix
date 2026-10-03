# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

let
  dataDir = "/var/lib/cloudunit";
in
{
  # Enable Docker daemon
  virtualisation.docker = {
    enable = true;
    # Store images/containers/volumes on the data partition (a distinct path,
    # NOT under a service data dir). A reflash rewrites only the system
    # partition, so the pulled images survive and services come back without a
    # network re-pull. factory-reset's named-path wipe never reaches this dir.
    daemon.settings.data-root = "${dataDir}/docker";
    # Clean up dangling images/containers weekly
    autoPrune = {
      enable = true;
      dates = "weekly";
    };
  };

  # Per-container memory. The Pi firmware puts cgroup_disable=memory on the kernel
  # command line ahead of ours, so without this `docker stats` (and the health
  # report's "app memory:" lines) read 0B and Docker has no memory limits. Ours come
  # later on the line. Hardware-verified on a Pi 5 through a normal update, 2026-10-03.
  boot.kernelParams = [ "cgroup_enable=memory" "cgroup_memory=1" ];

  # dockerd's data-root lives on the data partition, so it must not start until
  # that partition is mounted (RequiresMountsFor adds both Requires and After on
  # the mount unit).
  systemd.services.docker.unitConfig.RequiresMountsFor = dataDir;

  # Add the admin user to the docker group so docker works without sudo
  users.users.kh-admin.extraGroups = [ "docker" ];

  # docker compose is included with recent Docker; add the CLI plugin explicitly
  environment.systemPackages = with pkgs; [
    docker-compose
  ];
}
