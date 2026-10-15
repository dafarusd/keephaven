#!/usr/bin/env bash
# Fail if anything writer/wincopy.go says it copied from the helper's main.go has drifted.
#
# wincopy.go carries eight functions, six ioctl numbers, a struct and four DLL entry points that
# the helper has been using to lock and dismount this drive on the HP since 2026-10-07. A comment
# saying "copied, do not edit" stops being true the first time somebody fixes a bug on one side
# only - so the build runs this, and the build fails instead. Editing EITHER side fails it; the
# fix is to make the same change in both.
#
#   usage: drift-check.sh <helper main.go> <writer/wincopy.go>
set -u
H=${1:?helper main.go}
C=${2:?wincopy.go}
[ -r "$H" ] || { echo "drift check: cannot read $H"; exit 2; }
[ -r "$C" ] || { echo "drift check: cannot read $C"; exit 2; }

FUNCS="utf16ptr isAdmin openDevice diskOf rereadPartitions lockVolume allVolumes relaunchAsAdmin"
CONSTS="fsctlLockVolume fsctlDismountVolume ioctlStorageGetDevNumber ioctlDiskUpdateProperties genericRead genericWrite"
PROCS="IsUserAnAdmin ShellExecuteW FindFirstVolumeW FindNextVolumeW FindVolumeClose"

bad=0

# A function is its signature line through the first line that is a lone closing brace. gofmt
# guarantees that shape, and both files are gofmt'd by the build before this runs.
fn() {
  awk -v n="$2" '
    $0 ~ "^func " n "\\(" { inside=1 }
    inside { print }
    inside && $0 == "}" { exit }
  ' "$1"
}

for f in $FUNCS; do
  a=$(fn "$H" "$f"); b=$(fn "$C" "$f")
  if [ -z "$a" ]; then echo "drift check: $f is GONE from the helper ($H)"; bad=1; continue; fi
  if [ -z "$b" ]; then echo "drift check: $f is missing from the copy ($C)"; bad=1; continue; fi
  if [ "$a" != "$b" ]; then
    echo "drift check: $f differs between the helper and the copy:"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/    /'
    bad=1
  fi
done

# Constants: compare the value, not the formatting, because the two const blocks are padded to
# different widths by gofmt.
val() { grep -E "^[[:space:]]*$2[[:space:]]*=" "$1" | head -1 | sed 's/.*=[[:space:]]*//;s/[[:space:]]*$//'; }
for k in $CONSTS; do
  a=$(val "$H" "$k"); b=$(val "$C" "$k")
  if [ -z "$a" ]; then echo "drift check: const $k is GONE from the helper"; bad=1; continue; fi
  if [ -z "$b" ]; then echo "drift check: const $k is missing from the copy"; bad=1; continue; fi
  [ "$a" = "$b" ] || { echo "drift check: const $k is $a in the helper and $b in the copy"; bad=1; }
done

# The struct the ioctl writes into. A reordered field would corrupt the disk number silently.
st() { awk '/^type storageDeviceNumber struct \{/{i=1} i{gsub(/[[:space:]]+/," ");print} i&&/^\}/{exit}' "$1"; }
a=$(st "$H"); b=$(st "$C")
if [ -z "$a" ] || [ -z "$b" ] || [ "$a" != "$b" ]; then
  echo "drift check: type storageDeviceNumber differs or is missing:"
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/    /'
  bad=1
fi

# And the Windows entry points themselves, by name, so a NewProc typo on one side is caught.
for p in $PROCS; do
  grep -q "NewProc(\"$p\")" "$H" || { echo "drift check: the helper no longer calls $p"; bad=1; }
  grep -q "NewProc(\"$p\")" "$C" || { echo "drift check: the copy does not call $p"; bad=1; }
done

if [ "$bad" != 0 ]; then
  echo
  echo "The writer's copied Windows glue no longer matches the helper's. Change both or neither."
  exit 1
fi
echo "drift check: the writer's copied glue matches the helper's, function for function"
