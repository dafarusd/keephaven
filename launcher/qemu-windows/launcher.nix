# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# What goes on the drive's Windows-visible partition: the helper a Windows PC runs Keephaven
# with, and the QEMU it runs it in. Built here so a drive is made by writing one image, not by
# copying files on by hand.
#
# The order matters. QEMU is stripped first, then every file in it is hashed, then the helper
# is built with that list inside it, so a released helper runs only the QEMU it was built
# against and refuses anything else. The helper's own hash then sits inside the image, and the
# image's hash is what a release publishes — that is the whole chain.
#
# Nothing here uses `|| true` or "copy it if it happens to be there". A step that does not do
# its job has to stop the build: the first version of this file lost the stripping that way,
# and a missing file would otherwise reach a drive and stop a stranger's PC at its first start.
#
# Referenced only when keephaven.platform = "pc".

{ nixpkgs
, # The git revision this image is built from. The drive's AGPL notice names it, so an owner
  # can fetch the source of the version actually running rather than whatever main holds today.
  # Absent on a dirty tree, and then the drive says so and verify-written-drive.sh refuses it
  # as a customer drive.
  rev ? null
, # The Agent Memory edition's drive also passes the agent API's port, 8790, through to the
  # guest and opens it in the firewall. A patch applied only for that edition, so the Photos
  # drive's helper is built from exactly the same source as before (2026-10-24).
  agentMemory ? false
, # The drive edition's own version when it isn't the Photos SSD's (which is read out of
  # pc-hardware.nix below). flake.nix passes the Agent Memory SSD's.
  versionOverride ? null
}:
let
  agplRev = if rev == null then "UNCOMMITTED-DEVELOPMENT-BUILD-NOT-FOR-RELEASE" else rev;
  # The public repository is built by hand from an allow-list of this tree, so it has its own
  # commits: a revision from here means nothing there, and a stranger fetching it gets a 404
  # (measured 2026-10-13). What an owner can actually fetch is a TAG in the public repository,
  # so that is what the drive prints. The version is read out of pc-hardware.nix rather than
  # typed here, so the two can never disagree, and the build stops if it cannot find it.
  lib = nixpkgs.lib;
  pcHwText = builtins.readFile ../../modules/pc-hardware.nix;
  verLine = lib.findFirst (l: lib.hasInfix ''keephaven.imageVersion = "'' l) null
              (lib.splitString "\n" pcHwText);
  verMatch = if verLine == null then null else builtins.match ''.*"([0-9.]+)".*'' verLine;
  imageVersion = if versionOverride != null then versionOverride else if verMatch == null
    then throw "launcher.nix: cannot read keephaven.imageVersion out of modules/pc-hardware.nix"
    else builtins.head verMatch;
  # Still exposed through passthru for the tests, but no longer printed on the drive: his own
  # code is proprietary for this edition, so there is no public tag for an owner to fetch.
  publicTag = "drive-${imageVersion}";
  host = import nixpkgs { system = "x86_64-linux"; };
  cross = import nixpkgs {
    system = "x86_64-linux";
    crossSystem = host.lib.systems.examples.mingwW64;
    config.allowUnsupportedSystem = true;
  };

  qemuFull = import ./keephaven-qemu.nix { inherit nixpkgs; patched = true; };

  # The version, the URL and the hash come from the build, never from a person typing them
  # a second time. Hand-typed, the first QEMU bump leaves the text on the drive — the text
  # that is our GPL source offer — naming a tarball that is not the one inside the binary.
  qemuVersion = qemuFull.version;
  qemuUrl = qemuFull.src.url;
  qemuSha256 = builtins.convertHash { hash = qemuFull.src.outputHash; toHashFormat = "base16"; };

  # GPL version 2 section 1: a copy of the licence has to travel with the binary.
  # Taken out of the same tarball the binary was built from — qemuFull.src, not a
  # second fetch of the same URL — so the text cannot drift from the code it covers.
  qemuLicence = host.runCommand "qemu-${qemuFull.version}-COPYING"
    { nativeBuildInputs = [ host.gnutar host.xz ]; } ''
    set -euo pipefail
    tar -xJf ${qemuFull.src} -O qemu-${qemuFull.version}/COPYING > $out
    # A tarball whose top folder is named differently would make an empty file, and
    # an empty licence on the drive is worse than a build that stops here.
    [ -s $out ] || { echo "COPYING came out empty" >&2; exit 1; }
    grep -q "GNU GENERAL PUBLIC LICENSE" $out
  '';

  # By full path: a bare name would be looked for on PATH, which this build has none of.
  strip = "${cross.stdenv.cc.bintools.bintools}/bin/${cross.stdenv.cc.targetPrefix}strip";

  # Only the files a PC needs, stripped. The other architectures' firmware and the debug
  # symbols are several hundred megabytes we would otherwise carry on every drive.
  qemu = host.runCommand "keephaven-qemu-windows-stripped" { } ''
    set -euo pipefail
    mkdir -p $out/share
    cp ${qemuFull}/qemu-system-x86_64.exe $out/
    cp ${qemuFull}/*.dll $out/
    # The firmware the PC boots from: the helper opens OVMF_CODE.fd read-only and takes a
    # fresh copy of OVMF_VARS.fd for each run. Without these two nothing starts at all.
    cp ${host.OVMF.fd}/FV/OVMF_CODE.fd ${host.OVMF.fd}/FV/OVMF_VARS.fd $out/
    # What a q35 PC with a virtio drive and a virtio network card actually loads. QEMU 11.1
    # no longer ships linuxboot.bin or multiboot.bin, only the _dma versions; the list is
    # copied without a "skip it if missing", so a version that drops one stops the build here
    # rather than stopping a stranger's PC.
    for f in bios.bin bios-256k.bin bios-microvm.bin vgabios.bin vgabios-stdvga.bin \
             vgabios-virtio.bin kvmvapic.bin linuxboot_dma.bin multiboot_dma.bin \
             pvh.bin qboot.rom efi-virtio.rom efi-e1000.rom efi-e1000e.rom; do
      cp ${qemuFull}/share/$f $out/share/
    done
    cp -r ${qemuFull}/share/keymaps $out/share/
    chmod -R u+w $out
    for f in $out/*.exe $out/*.dll; do ${strip} "$f"; done
    cat > $out/KEEPHAVEN-BUILD.txt <<'TXT'
    QEMU ${qemuVersion} for 64-bit Windows, built from source by Keephaven.
    Source: ${qemuUrl}
    sha256 ${qemuSha256}
    With one change of our own: launcher/qemu-windows/win32-hdev-fixed-length.patch
    QEMU is free software under the GNU GPL version 2.
    TXT
    sed -i 's/^    //' $out/KEEPHAVEN-BUILD.txt
  '';

  # The list the helper is built with: every file under qemu\, by the name the helper sees.
  digests = host.runCommand "keephaven-qemu-digests" { } ''
    set -euo pipefail
    cd ${qemu}
    # A name carrying a comma, a colon or a space would run two entries together, and the
    # helper would then refuse a drive that was in fact correct.
    find . -type f | sed 's#^\./##' | sort | while read -r f; do
      case "$f" in *[,:[:space:]]*) echo "a file name this list cannot carry: $f" >&2; exit 1 ;; esac
      printf 'qemu/%s:%s,' "$f" "$(${host.coreutils}/bin/sha256sum "$f" | cut -d' ' -f1)"
    done | sed 's/,$//' > $out
    [ -s $out ] || { echo "the list came out empty" >&2; exit 1; }
  '';

  helper = host.stdenv.mkDerivation ({
    pname = "keephaven-windows-helper";
    version = "1";
    src = ../windows;
    nativeBuildInputs = [ host.go ];
    buildPhase = ''
      export HOME=$TMPDIR GOCACHE=$TMPDIR/go GOFLAGS=-mod=mod GOOS=windows GOARCH=amd64 CGO_ENABLED=0
      go build -tags release -trimpath \
        -ldflags "-s -w -X main.qemuDigests=$(cat ${digests}) -X main.version=${imageVersion}" -o Keephaven.exe .
    '';
    installPhase = ''mkdir -p $out && cp Keephaven.exe $out/'';
  } // host.lib.optionalAttrs agentMemory { patches = [ ./agent-memory-port.patch ]; });

  # Read the list back out of the helper that was just built and check it against the files
  # that are actually going on the drive. If those ever drift apart the helper refuses the
  # drive on the owner's PC, with nothing they can do about it — so it fails here instead.
  readBack = host.writeText "check-digests.py" ''
    import hashlib, os, sys
    root, listfile = sys.argv[1], sys.argv[2]
    want = dict(e.split(":", 1) for e in open(listfile).read().split(",") if ":" in e)
    blob = open(os.path.join(root, "Keephaven.exe"), "rb").read()
    for name, h in want.items():
        if (name + ":" + h).encode() not in blob:
            sys.exit("the helper does not carry the entry for " + name)
    have = {}
    for dirpath, _, files in os.walk(os.path.join(root, "qemu")):
        for f in files:
            p = os.path.join(dirpath, f)
            rel = "qemu/" + os.path.relpath(p, os.path.join(root, "qemu")).replace(os.sep, "/")
            have[rel] = hashlib.sha256(open(p, "rb").read()).hexdigest()
    if have != want:
        sys.exit("the helper's list and the files beside it do not agree: %d listed, %d here" % (len(want), len(have)))
    print("the helper carries the hash of each of the %d files beside it" % len(have))
    # The sealed list covers qemu\ only. These eight sit at the root on purpose, and a
    # drive that reached someone without them would be a licence breach, so check here.
    for f in ("README.txt", "QEMU-SOURCE.txt", "QEMU-LICENCE.txt",
              "qemu-win32-hdev-fixed-length.patch", "LICENCE.txt", "THIRD-PARTY.txt",
              "qemu-build-recipe.nix", "qemu-build-flake.lock"):
        if os.path.getsize(os.path.join(root, f)) == 0:
            sys.exit("missing or empty at the drive root: " + f)
  '';
in
host.runCommand "keephaven-launcher-files"
  {
    # Exposed so anything checking the drive's text can name the SAME version this build put in
    # it, rather than reading pc-hardware.nix a second time and drifting. passthru never reaches
    # the derivation, so the files do not move.
    passthru = { inherit imageVersion publicTag; };
  } ''
  set -euo pipefail
  mkdir -p $out/qemu
  cp -r ${qemu}/. $out/qemu/
  cp ${helper}/Keephaven.exe $out/
  chmod -R u+w $out
  cp ${qemuLicence} $out/QEMU-LICENCE.txt
  cp ${./win32-hdev-fixed-length.patch} $out/qemu-win32-hdev-fixed-length.patch
  cp ${../../LICENSE} $out/LICENCE.txt
  cp ${../../THIRD-PARTY.md} $out/THIRD-PARTY.txt
  cp ${./keephaven-qemu.nix} $out/qemu-build-recipe.nix
  cp ${../../flake.lock} $out/qemu-build-flake.lock
  # At the ROOT, not under qemu\: the helper refuses the drive if the qemu folder holds
  # one file more than the list it was built with, and these are not QEMU's files.
  cat > $out/QEMU-SOURCE.txt <<'TXT'
  QEMU, and how to get its source

  Keephaven runs on a Windows PC inside QEMU, which is free software under the GNU
  General Public License version 2. The licence is in QEMU-LICENCE.txt beside this
  file. The copy in the qemu folder was built by Keephaven from the upstream release:

      ${qemuUrl}
      sha256 ${qemuSha256}

  with one change to its source, and that change is beside this file in full:
  qemu-win32-hdev-fixed-length.patch. It stops QEMU asking a USB drive for its
  geometry three times for every read on Windows - the difference between a
  149-second check at start-up and a 15.6-second one on the PC we measured.

  How it was built is beside this file, so nothing has to be fetched to rebuild it:

      qemu-build-recipe.nix   the script that compiles it, GPL-2.0 like QEMU itself
      qemu-build-flake.lock   the exact set of packages that script was given

  If you would rather have the complete source on a drive than fetch it, write to
  support@keephaven.co and we will send it to you on physical media for no more than
  what the media and the postage cost us. That offer stands for three years from the
  day you received this one.

  KEEPHAVEN'S OWN CODE, AND WHERE TO GET IT

  Keephaven is free software. Every edition - Keephaven Home, Keephaven Photos,
  and this one, the Keephaven Photos SSD that runs on a Windows PC from this
  drive - is published under the GNU Affero General Public License version 3,
  version 3 only. The licence is in LICENCE.txt beside this file. The source,
  including the Windows program on this drive, the drive's layout and its
  update path, is at

      https://github.com/dafarusd/keephaven

  The exact source this drive was built from is tagged there:

      ${publicTag}

  Its build id, if you write to us about this drive, is
  ${agplRev}.

  The apps and the operating system inside it are other people's free software,
  several of them under the GNU Affero or GNU General Public Licences, and they
  are used unmodified exactly as their makers publish them. THIRD-PARTY.txt
  beside this file names every one and where its source is.

  Keephaven(TM) and the Keephaven logo are trademarks of Keephaven LLC; no
  licence here grants any right to use them. Write to
  partnerships@keephaven.co to license Keephaven's own code on other terms.

  TXT
  sed -i 's/^  //' $out/QEMU-SOURCE.txt
  cat > $out/README.txt <<'TXT'
  Keephaven
  This drive is a Keephaven. On a Windows PC, open Keephaven.exe on this drive and your
  Keephaven runs here, from this drive. Nothing of yours is moved or changed.
  It isn't installed, but it doesn't run on nothing either. What it leaves on the PC:
  one folder, C:\ProgramData\Keephaven, holding a copy of this program and of QEMU, and
  a log. Delete it whenever you like. While Keephaven is running it also opens ports 80,
  8888 and 2283 in the firewall for itself, and closes them again when you stop it.
  Opening your Keephaven as a shared folder, the way you would a drive on your network,
  does not work while it runs on a PC: Windows itself uses the one network door that sharing needs,
  and there is no second one. Photos and everything else on the web page work normally. A
  Keephaven box rather than a drive has no such limit.
  Your password is on the last setup page, and it is also in Keephaven-password.txt on
  this drive. Windows cannot read that file while Keephaven is running: to read it, type
  q in the Keephaven window, wait for "safe to unplug", and open the file. Starting
  Keephaven again does not change it.
  The other parts of this drive are not readable from Windows. That's expected. Don't format them.
  Who owns what is on this drive: all of it is free software. Keephaven's own program is
  under the GNU Affero General Public License version 3, the text of which is in
  LICENCE.txt, and its source is at https://github.com/dafarusd/keephaven . The QEMU in
  the qemu folder is free software too. QEMU-SOURCE.txt says where all of that source is
  and how to ask for it on a drive, and QEMU-LICENCE.txt is QEMU's licence.
  TXT
  sed -i 's/^  //' $out/README.txt
  # Plain ASCII in every text file on the drive: Notepad on an older Windows shows a
  # UTF-8 dash as two wrong characters, and these files are the first thing a stranger reads.
  for f in $out/*.txt $out/*.patch; do
    if LC_ALL=C grep -qn '[^[:print:][:space:]]' "$f"; then
      echo "not plain ASCII, and Windows will show it wrong: $f" >&2; exit 1
    fi
  done
  ${host.python3}/bin/python3 ${readBack} "$out" "${digests}"
''
