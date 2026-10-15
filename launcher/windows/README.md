<!--
SPDX-FileCopyrightText: 2026 Keephaven LLC
SPDX-License-Identifier: AGPL-3.0-only
-->
# Keephaven.exe (Windows helper) — TEST BUILD, not released

Runs the Keephaven that lives on a USB drive, on a Windows PC, by handing the whole
drive to QEMU. It sits on the drive's `KEEPHAVEN` partition next to a `qemu` folder.
`main.go` has the full description at the top.

Build, on Linux, standard library only:

    GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o Keephaven.exe .

Not yet built by the flake, and not yet baked into the drive image: the first test
drive got the files copied onto its partition 4 by hand (QEMU for Windows from
qemu.weilnetz.de, `qemu-w64-setup-20260811.exe`, checked against its published
SHA-512; `OVMF_CODE.fd` / `OVMF_VARS.fd` from nixpkgs' OVMF).

Never run on Windows at the time of this commit.
