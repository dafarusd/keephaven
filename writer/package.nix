# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Keephaven-Writer.exe - the program that puts a Keephaven Photos SSD image on a drive from
# Windows. It ships in the download beside the image, and it never goes on a drive: the helper
# copies the drive's Windows partition onto a PC, and a disk-erasing tool has no business
# travelling with the product.
#
# Three things have to pass before this compiles, because each one has already gone wrong
# somewhere on this product:
#   1. the drift check, so the Windows glue copied out of the helper cannot quietly diverge;
#   2. gofmt, because the drift check compares source text and only holds if both sides are
#      formatted the same way;
#   3. the GPT codec's own tests, judged by sgdisk - the writer rewrites a partition table on
#      a stranger's drive and nothing but a real GPT tool can say the result is valid;
#   4. the code stamper's tests, judged by mtype - it overwrites a file's contents underneath a
#      FAT filesystem, so the only answer that counts is whether a real FAT reader still reads
#      the file afterwards. These tests SKIP if mtools is missing, which is why mtools is a
#      build input here: a skipped test in a release build proves nothing.

{ nixpkgs
, # The version this writer prints and the image it is built to go beside. Passed in from
  # flake.nix, which asserts it is the same string the image carries.
  imageVersion
}:
let
  pkgs = import nixpkgs { system = "x86_64-linux"; };
in
pkgs.stdenv.mkDerivation {
  pname = "keephaven-ssd-writer";
  version = imageVersion;
  src = ./.;
  nativeBuildInputs = [ pkgs.go pkgs.gptfdisk pkgs.mtools pkgs.dosfstools ];

  # The helper's source, by path, so the drift check reads the real file and not a copy of it
  # that could age. A second file in here would be a second thing to keep in step.
  helperMain = ../launcher/windows/main.go;

  configurePhase = ''
    export HOME=$TMPDIR GOCACHE=$TMPDIR/go GOFLAGS=-mod=mod CGO_ENABLED=0
  '';

  # Before anything is compiled, so a writer that has drifted from the helper never exists as a
  # file in this build at all.
  preBuild = ''
    bash drift-check.sh "$helperMain" wincopy.go
    bad=$(gofmt -l . || true)
    if [ -n "$bad" ]; then
      echo "gofmt would change these, and the drift check compares source text: $bad" >&2
      exit 1
    fi
  '';

  checkPhase = ''
    runHook preCheck
    GOOS=windows GOARCH=amd64 go vet ./...
    # Natively, on the build machine: the codec is platform-neutral on purpose so that it can
    # be tested here against sgdisk, which is the only judge that counts.
    go test ./gpt/ ./code/ -v > test.log 2>&1 || { cat test.log >&2; exit 1; }
    # A SKIP here means the tools are missing from the build inputs and the release would go out
    # with the stamper unproven. Fail on it rather than read the log and hope.
    if grep -q '^--- SKIP' test.log; then
      echo "a test skipped in a release build:" >&2
      grep -n '^--- SKIP' -A1 test.log >&2
      exit 1
    fi
    grep -c '^--- PASS' test.log | sed 's/^/tests passed: /'
    runHook postCheck
  '';
  doCheck = true;

  buildPhase = ''
    runHook preBuild
    GOOS=windows GOARCH=amd64 go build -trimpath \
      -ldflags "-s -w -X main.version=${imageVersion}" -o Keephaven-Writer.exe .
    runHook postBuild
  '';

  installPhase = ''
    mkdir -p $out
    cp Keephaven-Writer.exe $out/
    # The version has to be IN the binary, not just in this file's name: a writer that prints
    # "unset-build" to a customer is a writer nobody can place in a support e-mail.
    grep -q '${imageVersion}' $out/Keephaven-Writer.exe \
      || { echo "the built writer does not carry the version ${imageVersion}" >&2; exit 1; }
    ( cd $out && sha256sum Keephaven-Writer.exe > Keephaven-Writer.exe.sha256 )
  '';

  # Nothing to strip or patch: the binary is a Windows PE, and fixup would only look at it.
  dontFixup = true;
}
