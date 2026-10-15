# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ lib, ... }:

# The hardware target. One option, read by the few modules whose behaviour has
# to differ between the Raspberry Pi 5 (the shipped box) and a generic x86-64
# UEFI PC. It defaults to the Pi, and every use of it is written so that the
# Pi value renders exactly what the module rendered before the option existed:
# the shipped images must not move (docs/operations/no-regression-diff.sh).
{
  options.keephaven.platform = lib.mkOption {
    type = lib.types.enum [ "pi5" "pc" ];
    default = "pi5";
    description = ''
      Hardware target. "pi5" is the Raspberry Pi 5. "pc" is a generic x86-64
      UEFI PC (not released; see DEVLOG).
    '';
  };
}
