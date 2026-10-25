# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# The Agent Memory SSD's Keephaven-Writer.exe: the Photos SSD's writer with its name patched.
# Separate for the same reason as setup.nix beside it.
{ nixpkgs, imageVersion }:
(import ../../writer/package.nix { inherit nixpkgs imageVersion; }).overrideAttrs (old: {
  pname = "keephaven-agent-memory-ssd-writer";
  patches = (old.patches or [ ]) ++ [ ./writer.patch ];
})
