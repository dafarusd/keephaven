# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# What a buyer of the Keephaven Photos SSD downloads: the image, the program that writes it to
# a drive from Windows, and the two checksums that let each of them be judged separately.
#
# The image is recompressed from zstd to gzip here, and that is the whole reason this file
# exists. Go's standard library reads gzip and does not read zstd, and the writer has no
# dependencies on purpose - a tool that erases a stranger's disk should not pull in a decoder
# nobody in this tree has read. Measured on the 2026.10.16 image, 36,520,853,504 bytes raw:
# zstd 5,286,407,955 bytes, gzip -9n 5,431,640,923. That is 2.7% more download for a writer
# with no dependencies at all. (gzip -6 was 5,441,045,545, so -9 is worth its extra minutes.)
#
# Two checksums, not one, and they answer different questions:
#   <name>.img.sha256      the image INSIDE the download. The writer reads the drive back and
#                          judges it against this, so it is the one that decides PASS or FAIL.
#   <name>.img.gz.sha256   the download itself, so a damaged download says so by name instead
#                          of looking like a damaged drive.
# The build proves the pair agrees by decompressing what it just wrote - the same work the
# buyer's PC will do, done once here where a mismatch costs nothing.

{ nixpkgs
, image     # the prod sdImage derivation (holds sd-image/*.img.zst)
, writer    # the built Keephaven-Writer.exe derivation
, imageVersion
, # Which drive edition this bundle is. The defaults are the Photos SSD, so its bundle renders
  # exactly as before; the Agent Memory SSD passes its own (2026-10-24).
  fileBase ? "keephaven-photos-ssd"
, productName ? "Keephaven Photos SSD"
, # Two things in the how-to that differ by edition: its opening paragraph, and the download's size.
  howtoTried ? "Early release. Free while it's early. If you grab it now it stays free for you.\nLater versions will cost money. It's booted on one PC so far, so keep your\noriginals somewhere else too."
, howtoDownloadGb ? "5"
}:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
  base = "${fileBase}-${imageVersion}";

  # The image as gzip, on its own, depending on the image and nothing else. Split out because
  # recompressing 36.5 GB takes ten minutes and a one-line change to the writer must not pay
  # for it again.
  imageGz = pkgs.runCommand "${base}-img-gz"
    { nativeBuildInputs = [ pkgs.zstd pkgs.gzip pkgs.coreutils ]; } ''
    set -euo pipefail
    mkdir -p $out
    ZST=$(echo ${image}/sd-image/*.img.zst)
    [ -f "$ZST" ] || { echo "no .img.zst in ${image}/sd-image" >&2; exit 1; }

    # Separate passes, no process substitution: bash does not wait for a >(...) to finish, so
    # the next line can read a checksum file that is still being written. zstd decompresses
    # this image in well under a minute, so there is nothing to win by being clever here.
    echo "measuring the image"
    BYTES=$(zstd -dc "$ZST" | wc -c)
    RAW=$(zstd -dc "$ZST" | sha256sum | cut -d' ' -f1)

    # A size that is not a whole number of sectors would mean the image itself is malformed,
    # and the writer's read-back would never line up with it.
    [ $(( BYTES % 512 )) -eq 0 ] || { echo "the image is $BYTES bytes, not a whole number of sectors" >&2; exit 1; }
    [ "$BYTES" -ge 32000000000 ] || { echo "the image is only $BYTES bytes, which is not a Keephaven" >&2; exit 1; }

    # REFUSE a development build. The drive's QEMU-SOURCE.txt embeds the flake revision, and
    # when there is no revision - a dirty tree, or a flake referenced by bare path - it embeds
    # the words below instead, in the text that makes a legal offer under his name. On
    # 2026-10-14 that image was named as the ship artifact and written to the drive on the HP;
    # the drive said "its build id is UNCOMMITTED-DEVELOPMENT-BUILD-NOT-FOR-RELEASE" and
    # nothing in the build had objected. So the check is made here, over the bytes that would
    # go to a buyer, rather than over the derivation that produced them.
    #
    # grep -c and not grep -q: -q closes the pipe on the first match, zstd dies of SIGPIPE, and
    # under pipefail the pipeline then reports failure - so the `if` would take the else branch
    # and let the marker through. The inverted test is the dangerous one.
    echo "checking the image does not call itself a development build"
    MARK=$(zstd -dc "$ZST" | LC_ALL=C grep -ac 'UNCOMMITTED-DEVELOPMENT-BUILD-NOT-FOR' || true)
    if [ "$MARK" != 0 ]; then
      echo "this image carries the development-build marker in its own text ($MARK times)." >&2
      echo "It was built without a git revision - a dirty tree, or a flake referenced by bare" >&2
      echo "path. Commit, then build through git+file:///...?rev=<sha>. Nothing is published" >&2
      echo "from an image that cannot name the commit it came from." >&2
      exit 1
    fi

    echo "recompressing $BYTES bytes as gzip"
    # -n so no file name and no timestamp go into the gzip header: without it the same image
    # gives a different download on every build, and then no published checksum means anything.
    zstd -dc "$ZST" | gzip -9n > $out/${base}.img.gz

    # The buyer's own check, done here first: decompress what was just written and see that it
    # is the image. gzip -t would check the CRC; this checks the identity.
    echo "reading the download back to prove it decompresses to the image"
    BACK=$(gzip -dc $out/${base}.img.gz | sha256sum | cut -d' ' -f1)
    [ "$BACK" = "$RAW" ] || { echo "the download decompresses to $BACK, not $RAW" >&2; exit 1; }

    printf '%s  %s\n' "$RAW" "${base}.img" > $out/${base}.img.sha256
    ( cd $out && sha256sum ${base}.img.gz > ${base}.img.gz.sha256 )
    printf '%s\n' "$BYTES" > $out/${base}.img.bytes
    echo "image $BYTES bytes, sha256 $RAW"
  '';
in
pkgs.runCommand "${fileBase}-download-${imageVersion}"
  {
    nativeBuildInputs = [ pkgs.coreutils ];
    passthru = { inherit imageVersion base imageGz; };
  } ''
  set -euo pipefail
  mkdir -p $out
  cp ${imageGz}/${base}.img.gz ${imageGz}/${base}.img.sha256 ${imageGz}/${base}.img.gz.sha256 $out/
  cp ${writer}/Keephaven-Writer.exe ${writer}/Keephaven-Writer.exe.sha256 $out/
  chmod -R u+w $out

  cat > $out/HOW-TO-WRITE-THE-DRIVE.txt <<'TXT'
  ${productName} ${imageVersion} - putting it on a drive

  ${howtoTried}

  You need a USB SSD of 64 GB or more, in a USB enclosure. Everything on it will
  be erased. Thunderbolt and USB4 enclosures are not supported yet: Windows
  reports those as NVMe rather than USB, and the writer will not offer them.

  1. Plug in the drive. Unplug every other USB drive - the writer will not guess
     between two of them, and that is on purpose.
  2. Keep every file from the download in the same folder, including the small
     Keephaven-code.txt that came with your download. That file is how your drive
     finds its updates, and the writer puts it on the drive for you. It is not a
     password, it is not a licence, it does not identify you, and it does not
     unlock anything on the drive. If it is missing the drive still works, but it
     will not be able to fetch updates and it will tell you so on its own screen.
  3. Double-click Keephaven-Writer.exe. Windows will ask whether to allow it to
     make changes to your device; it needs that to write to a drive at all.
  4. It shows you the one drive it will erase, what is on it now, and asks you to
     type the drive's make and size. Nothing is touched until you do.
  5. It writes the image, then reads every byte back off the drive and checks it
     against the checksum in this folder. It prints PASS or FAIL in those words.
  6. On PASS it tells you which drive letter your Keephaven is on. Open it and
     double-click Keephaven.exe.

  Windows SmartScreen will warn you that the publisher is unknown, twice: once for
  this writer and once for Keephaven.exe. The programs are not signed with a
  certificate. Choose More info, then Run anyway. If you would rather check for
  yourself first, the two .sha256 files beside this one are the checksums of the
  two downloads; in PowerShell, Get-FileHash <file> -Algorithm SHA256.

  It checks the download before it touches the drive, then writes, then reads the
  whole drive back. Each of those three steps moves about ${howtoDownloadGb} GB, 36 GB and 36 GB,
  and it prints how fast it is going as it works. On the PC we measured - a Core i3
  laptop, USB 3 - the write took 2 minutes 19 seconds and the read-back a little
  over one.
  Yours will differ; a slow USB port can make it several times that. Do not unplug
  the drive while any of it is running. If the power goes out during the write, run
  the writer again - a half-written drive is simply unfinished, not broken.

  If it says the download is damaged, download it again. If it says the drive does
  not hold what was written, try another USB port, then another drive.

  You can write your drive as many times as you like with the same download and the
  same code. If you replace the drive, write the new one the same way.

  support@keephaven.co
  TXT
  sed -i 's/^  //' $out/HOW-TO-WRITE-THE-DRIVE.txt

  # Plain ASCII in anything a stranger reads first: Notepad on an older Windows turns a
  # UTF-8 dash into two wrong characters.
  if LC_ALL=C grep -qn '[^[:print:][:space:]]' $out/HOW-TO-WRITE-THE-DRIVE.txt; then
    echo "not plain ASCII: HOW-TO-WRITE-THE-DRIVE.txt" >&2; exit 1
  fi

  # Six files and no more: an extra one is a file a buyer has to wonder about, and a second
  # .img.gz in the folder is something the writer refuses outright rather than guessing about.
  n=$(ls -1 $out | wc -l)
  [ "$n" = 6 ] || { echo "the download has $n files, not the six it should" >&2; ls -l $out >&2; exit 1; }

  echo
  echo "download ready:"
  ( cd $out && ls -l && cat ${base}.img.sha256 ${base}.img.gz.sha256 Keephaven-Writer.exe.sha256 )
''
