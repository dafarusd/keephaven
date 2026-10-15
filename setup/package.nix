# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Keephaven-Setup.exe - the one file a buyer downloads. It fetches the image and the writer,
# checks them, and starts the writer. It never opens a disk; the writer never opens a socket.
#
# The buyer's update code is stamped into the built binary at download time, into a fixed
# 64-byte field. This build asserts the field is present and is the right length, because a
# binary without it is one every buyer would get with no code at all.
{ nixpkgs, imageVersion }:
let pkgs = import nixpkgs { system = "x86_64-linux"; };
in
pkgs.stdenv.mkDerivation {
  pname = "keephaven-ssd-setup";
  version = imageVersion;
  src = ./.;
  nativeBuildInputs = [ pkgs.go pkgs.python3 ];
  configurePhase = ''
    export HOME=$TMPDIR GOCACHE=$TMPDIR/go GOFLAGS=-mod=mod CGO_ENABLED=0
  '';
  preBuild = ''
    bad=$(gofmt -l . || true)
    [ -z "$bad" ] || { echo "gofmt would change: $bad" >&2; exit 1; }
  '';
  checkPhase = ''
    GOOS=windows GOARCH=amd64 go vet ./...
  '';
  doCheck = true;
  buildPhase = ''
    GOOS=windows GOARCH=amd64 go build -trimpath \
      -ldflags "-s -w -X main.version=${imageVersion}" -o Keephaven-Setup.exe .
  '';
  installPhase = ''
    mkdir -p $out
    cp Keephaven-Setup.exe $out/
    # The code field has to survive the linker. 21 bytes of marker + 64 of dots.
    python3 - "$out/Keephaven-Setup.exe" <<'PY'
import sys
b = open(sys.argv[1], "rb").read()
m = b"KEEPHAVEN-SETUP-CODE:"
i = b.find(m)
if i < 0:
    sys.exit("the built setup program has no code field in it")
field = b[i+len(m):i+len(m)+64]
if field != b"." * 64:
    sys.exit("the code field is not 64 dots: %r" % field[:16])
if b.find(m, i + 1) >= 0:
    sys.exit("the marker appears more than once, so a stamp would be ambiguous")
print("code field present at offset %d, 64 bytes" % (i + len(m)))
PY
    grep -q '${imageVersion}' $out/Keephaven-Setup.exe \
      || { echo "the built setup does not carry the version ${imageVersion}" >&2; exit 1; }
    ( cd $out && sha256sum Keephaven-Setup.exe > Keephaven-Setup.exe.sha256 )
  '';
  dontFixup = true;
}
