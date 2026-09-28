# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
{
  # ----- WiFi regulatory domain -----
  # The Pi 5 radio will not transmit (AP mode included) without a regulatory
  # domain set. On Pi OS this reverted every boot; on NixOS it is baked into
  # the image declaratively and applied identically on every boot.
  hardware.wirelessRegulatoryDatabase = true;
  boot.kernelParams = [ "cfg80211.ieee80211_regdom=US" ];

  # Wireless tooling for diagnostics + AP setup.
  environment.systemPackages = with pkgs; [
    iw
    wirelesstools
  ];
}
