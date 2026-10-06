#!/bin/sh
# cloudunit-factory-reset
# DESTRUCTIVE: wipes ALL user data and returns the box to first-boot state,
# preserving only unit.env (the printed sticker identity).
#
# Order matters: stop all service containers FIRST (their DBs are open), then
# delete explicit named paths (never a wildcard on the parent dir), then clear
# the setup flags and reboot into the wizard. On next boot the provisioners
# recreate fresh accounts using the sticker password, and ap.env/credentials
# regenerate from unit.env, so the box returns to the printed sticker state.
set -u

DATADIR="/var/lib/cloudunit"
DOCKER="docker"
SYSTEMCTL="systemctl"

if [ ! -f "$DATADIR/unit.env" ]; then
  echo "ERROR: unit.env missing; refusing to factory reset" >&2
  exit 3
fi

echo "Factory reset: stopping services..."
for s in immich jellyfin navidrome kavita audiobookshelf freshrss; do
  $SYSTEMCTL stop "cloudunit-$s" 2>/dev/null || true
done
$SYSTEMCTL stop cloudunit-samba-bootstrap 2>/dev/null || true
# Drop tailnet membership too: a factory reset hands the box to a new owner, so
# the previous owner's tailscale state/identity must not persist.
$SYSTEMCTL stop tailscaled 2>/dev/null || true

sleep 3

for c in immich_server immich_machine_learning immich_redis immich_postgres \
         jellyfin navidrome kavita audiobookshelf freshrss; do
  $DOCKER stop "$c" 2>/dev/null || true
done

echo "Factory reset: erasing user data..."
# EXPLICIT named paths only. NEVER "rm -rf $DATADIR" or "$DATADIR/*".
#
# `replication` carries the box-to-box pairing: the per-pair private key, the
# partner's AUTHORIZED key (a standing SSH credential for kh-replica), the pair
# record, the was-primary marker, and the landing area holding the partner's
# replicated files. A factory reset hands the box to a new owner, so all of it
# must go -- otherwise the new owner inherits a credential from, and a copy of,
# the previous owner's other Keephaven. Same rationale as tailscale above.
#
# `ssh` holds this box's SSH host keys (base.nix keeps them on the data
# partition so an update does not change them). A reset box gets new ones at
# its next start, so it is not recognisable as the previous owner's box.
for d in immich jellyfin navidrome kavita audiobookshelf freshrss tailscale replication ssh; do
  rm -rf "$DATADIR/$d"
done
rm -f "$DATADIR/current.env"
rm -f "$DATADIR/ap.env"
rm -f "$DATADIR/.setup-complete"
rm -f "$DATADIR/.samba-bootstrapped"

# unit.env is intentionally preserved (the printed sticker must still work).

echo "OK: factory reset complete; rebooting into setup"
$SYSTEMCTL reboot
