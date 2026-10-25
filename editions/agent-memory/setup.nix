# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# The Agent Memory SSD's Keephaven-Setup.exe: the Photos SSD's setup program with its download
# address and its name patched. A separate file on purpose: setup/package.nix builds from its own
# folder, so touching anything in it would move the Photos SSD's program (2026-10-24).
{ nixpkgs, imageVersion }:
(import ../../setup/package.nix { inherit nixpkgs imageVersion; }).overrideAttrs (old: {
  pname = "keephaven-agent-memory-ssd-setup";
  patches = (old.patches or [ ]) ++ [ ./setup.patch ];
})
