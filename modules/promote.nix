# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# PROMOTION — PHASE 4. "Make this my main Keephaven."
#
# This runs on the worst day the owner will ever have: the other box is dead,
# lost or burned, and this one holds the only copy. They may be doing it
# remotely, on a phone, while upset. Two consequences shape the whole design:
#
#   1. IT CANNOT BE UNDONE. It replays a database and copies files over the live
#      paths. So the UI names the source box and the backup's AGE in plain words
#      ("taken 3 days ago"), says plainly that it cannot be undone, and requires
#      typing to confirm.
#
#   2. NO AMBIGUOUS FAILURE STATES. If it stops partway the owner must be able to
#      tell whether they have their photos. Every exit says three things: what
#      happened, what state the box is now in, and whether it is safe to try
#      again. The answer to the third is ALWAYS yes, by construction — every step
#      is idempotent (rsync without --delete; pg_dump replayed with --clean
#      --if-exists; a password set that can be re-set) — and that is stated
#      rather than left to be inferred.
#
# Progress is written to promote-status.json after EVERY phase, so a box that
# lost power mid-promotion still reports where it stopped. [Dafarus, 2026-08-10]
#
# NOT done here, deliberately:
#   - no re-pairing: the peer is presumably gone, and guessing is worse than the
#     dashboard notice telling the owner to add a second box.
#   - no deleting of this box's own pre-existing files: same no-delete rule as
#     the replication itself. Same-named files are overwritten by the restore;
#     anything else survives. Said plainly in the UI rather than hidden.
# ============================================================================

let
  cfg = config.keephaven.replication;
  dataDir = "/var/lib/cloudunit";
  replDir = "${dataDir}/replication";
  landing = "${replDir}/landing";
  dumpDir = "${landing}/dump";
  pairEnv = "${replDir}/pair.env";
  backupFlag = "${dataDir}/.backup-mode";
  promotedFlag = "${replDir}/.promoted";
  statusFile = "${replDir}/promote-status.json";
  immichEnv = "${dataDir}/immich/.env";
  unitEnv = "${dataDir}/unit.env";
  versionFile = "/etc/cloudunit/update/version";

  # Restore targets, in the order the G10 bench restore proved: files first, so
  # the database never references originals that are not on disk yet.
  # Edition switch: the active edition's backup folders, from the appBackup
  # authority in modules/editions.nix (keephaven.activeBackupPaths). For
  # entertainment this is the same six in the same order, so the rendered script
  # is unchanged. A Photos box restores only immich/library + immich/external.
  restorePaths = config.keephaven.activeBackupPaths;

  # Read-only: what the confirmation screen needs to name the source box and the
  # backup's age. Kept separate from the promote wrapper so the UI can call it
  # without any risk of starting anything.
  preflight = pkgs.writeShellScriptBin "cloudunit-promote-preflight" ''
    set -u
    co=${pkgs.coreutils}/bin
    [ -f ${pairEnv} ] || { echo "state=not-a-backup"; exit 0; }
    ROLE="$(${pkgs.gawk}/bin/awk -F= '/^ROLE=/{print $2; exit}' ${pairEnv})"
    [ "''${ROLE:-}" = "backup-target" ] || { echo "state=not-a-backup"; exit 0; }
    PEER="$(${pkgs.gawk}/bin/awk -F= '/^PEER_SUFFIX=/{print $2; exit}' ${pairEnv})"

    D="$(${pkgs.findutils}/bin/find ${dumpDir} -maxdepth 1 -type f -name 'immich-*.sql.zst' -printf '%f\n' 2>/dev/null \
         | $co/sort -r | $co/head -n1)"
    if [ -z "''${D:-}" ]; then
      $co/printf 'state=no-backup-yet\npeer=%s\n' "''${PEER:-unknown}"
      exit 0
    fi
    META="${dumpDir}/''${D%.sql.zst}.meta"
    SRCVER="$(${pkgs.gawk}/bin/awk -F= '/^source_version=/{print $2; exit}' "$META" 2>/dev/null)"
    TAKEN="$($co/date -u -r "${dumpDir}/$D" '+%Y-%m-%d' 2>/dev/null)"
    EPOCH="$($co/date -u -r "${dumpDir}/$D" '+%s' 2>/dev/null || echo 0)"
    NOW="$($co/date -u '+%s')"
    DAYS=$(( (NOW - EPOCH) / 86400 ))
    # Plain-language age. "3 days ago" lands; a bare date does not.
    if [ "$DAYS" -le 0 ]; then AGE="today";
    elif [ "$DAYS" -eq 1 ]; then AGE="yesterday";
    else AGE="$DAYS days ago"; fi
    MYVER="$($co/cat ${versionFile} 2>/dev/null || echo unknown)"
    # The interlock, evaluated HERE too so the UI can warn before the owner
    # commits rather than only failing afterwards.
    OK=yes
    if [ -n "''${SRCVER:-}" ] && [ "$SRCVER" != "unknown" ]; then
      NEWEST="$($co/printf '%s\n%s\n' "$SRCVER" "$MYVER" | $co/sort -r | $co/head -n1)"
      [ "$NEWEST" = "$MYVER" ] || OK=no
    fi
    $co/printf 'state=ready\npeer=%s\ndump=%s\ntaken=%s\nage=%s\nsource_version=%s\nmy_version=%s\nversion_ok=%s\n' \
      "''${PEER:-unknown}" "$D" "''${TAKEN:-unknown}" "$AGE" "''${SRCVER:-unknown}" "$MYVER" "$OK"
  '';

  # ---- PHOTOS SIGN-IN, after a promotion --------------------------------------
  # The Phase 4 gate settled it: `immich-admin reset-admin-password` is
  # INTERACTIVE and cannot run unattended, so the automatic fix never works and
  # the fallback is the NORMAL path, not an edge case. Every promoted box lands
  # with Photos wanting the SOURCE box's sticker password.
  #
  # That box is gone - that is the premise of promoting - so this cannot live in
  # a dashboard notice that scrolls past or clears. It needs a permanent home,
  # and better still a way to END it. [Dafarus, 2026-08-14]
  #
  # status: "ok" once THIS box's sticker password works (so the notice removes
  # itself the moment it stops being true - no dismiss button to mis-click),
  # "other-box" while it does not, "unknown" if Immich is not answering yet
  # (never show a scary message during startup), "n/a" if not promoted.
  photosStatus = pkgs.writeShellScriptBin "cloudunit-photos-signin-status" ''
    set -u
    [ -f ${promotedFlag} ] || { echo "n/a"; exit 0; }
    STICKER="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_PASSWORD=/{print $2; exit}' ${unitEnv} 2>/dev/null)"
    [ -n "''${STICKER:-}" ] || { echo "unknown"; exit 0; }
    PING="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
             http://localhost:2283/api/server/ping 2>/dev/null || true)"
    [ "$PING" = "200" ] || { echo "unknown"; exit 0; }
    CODE="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
             -X POST http://localhost:2283/api/auth/login \
             -H 'Content-Type: application/json' \
             -d "{\"email\":\"keephaven@local\",\"password\":\"$STICKER\"}" 2>/dev/null || true)"
    case "$CODE" in (200|201) echo "ok" ;; (*) echo "other-box" ;; esac
  '';

  # Ends it, rather than only explaining it. The owner has just proved they know
  # the old password by signing in with it, so we can use it as the "old" value
  # the change-password API requires - the exact thing the promotion itself could
  # not do. Password arrives on STDIN, never argv (the support-access discipline).
  photosFix = pkgs.writeShellScriptBin "cloudunit-photos-signin-fix" ''
    set -u
    OLD="$(${pkgs.coreutils}/bin/cat)"
    OLD="$(printf '%s' "$OLD" | ${pkgs.coreutils}/bin/tr -d '\r\n')"
    [ -n "$OLD" ] || { echo "no password given" >&2; exit 2; }
    STICKER="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_PASSWORD=/{print $2; exit}' ${unitEnv} 2>/dev/null)"
    [ -n "''${STICKER:-}" ] || { echo "could not read this box's password" >&2; exit 1; }
    TOK="$(${pkgs.curl}/bin/curl -s --max-time 10 -X POST http://localhost:2283/api/auth/login \
            -H 'Content-Type: application/json' \
            -d "{\"email\":\"keephaven@local\",\"password\":\"$OLD\"}" \
          | ${pkgs.gnugrep}/bin/grep -o '"accessToken":"[^"]*"' | ${pkgs.coreutils}/bin/cut -d'"' -f4 || true)"
    [ -n "''${TOK:-}" ] || { echo "that password did not work for Photos" >&2; exit 3; }
    CODE="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
             -X POST http://localhost:2283/api/auth/change-password \
             -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
             -d "{\"password\":\"$OLD\",\"newPassword\":\"$STICKER\"}" 2>/dev/null || true)"
    case "$CODE" in
      (200|201) echo "OK: Photos now uses this box's sticker password" ;;
      (*) echo "could not change the Photos password (code $CODE)" >&2; exit 4 ;;
    esac
  '';

  # Fire-and-forget starter: Settings must return instantly, because a restore
  # can run for hours and the owner has to be able to close the page.
  startPromote = pkgs.writeShellScriptBin "cloudunit-promote-start" ''
    set -u
    ${pkgs.systemd}/bin/systemctl start --no-block cloudunit-promote.service \
      || { echo "could not start the restore" >&2; exit 1; }
    echo "OK: restore started"
  '';

  promote = pkgs.writeShellScriptBin "cloudunit-promote" ''
    set -u
    set -o pipefail
    co=${pkgs.coreutils}/bin

    # Every message goes to stdout: this runs as a systemd ExecStart, so systemd
    # captures it and it shows under both `journalctl -u cloudunit-promote` and
    # `-t cloudunit-promote`. (CLAUDE.md: a log line nobody can find does not
    # exist. The Phase 3 gate lost an hour to exactly that.)
    log() { echo "$*"; }

    # say <state> <retry-safe> <message>
    # Written after EVERY phase, so a box that loses power mid-promotion still
    # reports where it stopped. The owner-facing text must always answer: what
    # happened, what state is the box in, is it safe to try again.
    say() {
      TMP="$($co/mktemp ${replDir}/.promote.XXXXXX)"
      $co/printf '{"state":"%s","retry_safe":%s,"message":"%s","at":"%s"}\n' \
        "$1" "$2" "$3" "$($co/date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$TMP"
      $co/chmod 644 "$TMP"
      $co/mv -f "$TMP" ${statusFile}
      log "promote[$1]: $3"
    }

    # ---- phase 0: is this even a backup box, and is there something to restore?
    if [ ! -f ${pairEnv} ]; then
      say refused true "This Keephaven is not set up as a backup, so there is nothing to restore. Nothing has been changed."
      exit 2
    fi
    ROLE="$(${pkgs.gawk}/bin/awk -F= '/^ROLE=/{print $2; exit}' ${pairEnv})"
    PEER="$(${pkgs.gawk}/bin/awk -F= '/^PEER_SUFFIX=/{print $2; exit}' ${pairEnv})"
    if [ "''${ROLE:-}" != "backup-target" ]; then
      say refused true "This Keephaven is not a backup box. Nothing has been changed."
      exit 2
    fi
    D="$(${pkgs.findutils}/bin/find ${dumpDir} -maxdepth 1 -type f -name 'immich-*.sql.zst' -printf '%f\n' 2>/dev/null \
         | $co/sort -r | $co/head -n1)"
    if [ -z "''${D:-}" ]; then
      say refused true "There is no backup on this Keephaven yet, so there is nothing to restore. Nothing has been changed."
      exit 3
    fi
    DUMP="${dumpDir}/$D"
    META="${dumpDir}/''${D%.sql.zst}.meta"

    # ---- phase 1: the VERSION INTERLOCK. Old dump into a newer Immich is
    # bench-proven safe (decisions.md 2026-07-27); the reverse is undefined, so
    # refuse rather than find out on the owner's worst day.
    SRCVER="$(${pkgs.gawk}/bin/awk -F= '/^source_version=/{print $2; exit}' "$META" 2>/dev/null)"
    MYVER="$($co/cat ${versionFile} 2>/dev/null || echo unknown)"
    if [ -n "''${SRCVER:-}" ] && [ "$SRCVER" != "unknown" ] && [ "$MYVER" != "unknown" ]; then
      NEWEST="$($co/printf '%s\n%s\n' "$SRCVER" "$MYVER" | $co/sort -r | $co/head -n1)"
      if [ "$NEWEST" != "$MYVER" ]; then
        say refused true "Your backup was made by a newer version of Keephaven ($SRCVER) than this box is running ($MYVER). Nothing has been changed. Update this Keephaven first, then try again."
        exit 4
      fi
    fi

    # ---- phase 2: is the backup itself trustworthy? Checked BEFORE anything is
    # touched, so a damaged dump costs the owner nothing.
    EXP="$(${pkgs.gawk}/bin/awk -F= '/^sha256=/{print $2; exit}' "$META" 2>/dev/null)"
    ACT="$($co/sha256sum "$DUMP" | $co/cut -d' ' -f1)"
    if [ -n "''${EXP:-}" ] && [ "$EXP" != "$ACT" ]; then
      say refused true "The backup file on this Keephaven is damaged and was not used. Nothing has been changed. Please contact support@keephaven.co."
      exit 5
    fi
    TAILTXT="$(${pkgs.zstd}/bin/zstd -dc "$DUMP" 2>/dev/null | $co/tail -c 4096 || true)"
    case "$TAILTXT" in
      (*"PostgreSQL database dump complete"*) ;;
      (*) say refused true "The backup on this Keephaven is incomplete and was not used. Nothing has been changed. Please contact support@keephaven.co."
          exit 5 ;;
    esac

    say starting true "Restoring from the backup. This can take a while; you can leave this page."

    # ---- phase 3: FILES FIRST. Immich's database points at originals, so they
    # must be on disk before it is replayed. -rlptD is -a WITHOUT owner/group:
    # the landing copies are kh-replica-owned because the receiver is not root,
    # and -a would stamp that onto the live media dirs. Never --delete: this
    # box's own pre-existing files are left alone (same rule as the replication).
    FAILED=""
    ${lib.concatMapStringsSep "\n    " (p: ''
      if [ -d "${landing}/${p}" ]; then
        ${pkgs.coreutils}/bin/mkdir -p "${dataDir}/${p}"
        ${pkgs.rsync}/bin/rsync -rlptD "${landing}/${p}/" "${dataDir}/${p}/" || FAILED="$FAILED ${p}"
      fi
    '') restorePaths}
    if [ -n "$FAILED" ]; then
      say files-failed true "Some of your files could not be copied into place ($FAILED ). Your backup is still safe on this box and nothing was deleted. It is safe to try again."
      exit 6
    fi
    ${pkgs.coreutils}/bin/chown -R keephaven:keephaven \
      ${dataDir}/jellyfin/media ${dataDir}/navidrome/media \
      ${dataDir}/audiobookshelf/media ${dataDir}/kavita/media \
      ${dataDir}/immich/external 2>/dev/null || true
    say files-restored true "Your files are in place. Restoring the photo library next."

    # ---- phase 3b: APP PICKER - adopt the main box's picks BEFORE phase 4 lets
    # the services start, so an app the owner had switched off stays off here.
    # The main box sends ONE snapshot file (apps-off.list) nightly; the receiver
    # refuses --delete, so a markers folder would carry stale markers forever.
    # No file (a main box from before the picker) = no markers = everything on,
    # which is what that box ran. Names are matched against this image's own
    # pickable list, so nothing from the other box becomes a path here.
    ${pkgs.coreutils}/bin/rm -rf ${config.keephaven.appsDir}
    ${pkgs.coreutils}/bin/mkdir -p ${config.keephaven.appsDir}
    if [ -f "${landing}/apps-off.list" ]; then
      # EXACT match per name (a substring test would accept a line such as
      # "jellyfin navidrome" from the other box).
      while read -r a; do
        for p in ${lib.concatStringsSep " " config.keephaven.pickableApps}; do
          if [ "$p" = "$a" ]; then
            ${pkgs.coreutils}/bin/touch "${config.keephaven.appsDir}/$p.off"
          fi
        done
      done < "${landing}/apps-off.list"
    fi
    ${pkgs.systemd}/bin/systemctl restart cloudunit-samba-apps.service || true

    # ---- phase 4: leave backup mode so the six services are no longer blocked.
    ${pkgs.coreutils}/bin/rm -f ${backupFlag}

    # ---- phase 5: the database.
    #
    # THE APP CONTAINERS MUST NOT RUN DURING THE RESTORE. Starting the whole
    # Immich stack and waiting for postgres gives immich_server up to two minutes
    # to run its OWN migrations first - which create VectorChord objects like
    # clip_index that `pg_dump --clean --if-exists` has no DROP for, so the
    # restore then collides with "relation clip_index already exists". Found on
    # hardware (vvqn6, 2026-08-15) on a completely clean run: no interruption,
    # a customer doing exactly the right thing. The bench could not catch it
    # because it used plain PostgreSQL, not the real VectorChord image.
    #
    # This is a divergence from our OWN proven procedure: replica-restore.md
    # says "leave immich_postgres running, stop the app containers" and passed
    # G10 doing exactly that. The script did not follow it.
    #
    # AND THE TARGET IS RECREATED, not replayed over. Replaying into a database
    # that already holds objects is what made the failure PERMANENT: clip_index
    # survived, so every retry failed identically - which broke the retry-safe
    # promise the status message makes. Dropping and recreating makes the restore
    # genuinely idempotent, so that promise is true rather than softened.
    ${pkgs.systemd}/bin/systemctl start --no-block cloudunit-immich.service || true
    i=0
    while [ "$i" -lt 60 ]; do
      # Stop them on every pass: compose may bring them up a moment after the
      # database. A container stopped explicitly is not revived by its restart
      # policy, so once caught it stays down.
      ${pkgs.docker}/bin/docker stop immich_server immich_machine_learning >/dev/null 2>&1 || true
      ${pkgs.docker}/bin/docker exec immich_postgres pg_isready >/dev/null 2>&1 && break
      ${pkgs.coreutils}/bin/sleep 2; i=$((i + 1))
    done
    # compose was started --no-block, so it can STILL be mid-`up` when postgres
    # first answers: it starts immich_server only after the database reports
    # healthy - potentially AFTER the stop above. Keep holding the app
    # containers down until the unit has finished activating, or the server can
    # begin migrating mid-restore and the clip_index collision returns
    # intermittently. Bounded; compose has its own timeouts.
    j=0
    while [ "$(${pkgs.systemd}/bin/systemctl show -p ActiveState --value cloudunit-immich.service 2>/dev/null)" = "activating" ] && [ "$j" -lt 60 ]; do
      ${pkgs.docker}/bin/docker stop immich_server immich_machine_learning >/dev/null 2>&1 || true
      ${pkgs.coreutils}/bin/sleep 2; j=$((j + 1))
    done
    ${pkgs.docker}/bin/docker stop immich_server immich_machine_learning >/dev/null 2>&1 || true
    DB_USER="$(${pkgs.gawk}/bin/awk -F= '/^DB_USERNAME=/{print $2; exit}' ${immichEnv} 2>/dev/null)"
    DB_NAME="$(${pkgs.gawk}/bin/awk -F= '/^DB_DATABASE_NAME=/{print $2; exit}' ${immichEnv} 2>/dev/null)"
    DB_PASS="$(${pkgs.gawk}/bin/awk -F= '/^DB_PASSWORD=/{print $2; exit}' ${immichEnv} 2>/dev/null)"
    if [ -z "''${DB_USER:-}" ] || [ -z "''${DB_NAME:-}" ]; then
      say db-failed true "Your files were restored, but the photo database could not be reached. Your photos are on this box; the Photos app may not open yet. It is safe to try again."
      exit 7
    fi
    # Recreate the target so the restore lands in an empty database every time.
    PSQL_ADMIN="${pkgs.docker}/bin/docker exec -i -e PGPASSWORD=$DB_PASS immich_postgres psql -U $DB_USER -d postgres -v ON_ERROR_STOP=1"
    if ! $PSQL_ADMIN -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" >/dev/null 2>&1 \
       || ! $PSQL_ADMIN -c "DROP DATABASE IF EXISTS \"$DB_NAME\";" >/dev/null 2>&1 \
       || ! $PSQL_ADMIN -c "CREATE DATABASE \"$DB_NAME\" OWNER \"$DB_USER\";" >/dev/null 2>&1; then
      say db-failed true "Your files were restored, but the photo database could not be prepared. Your photos are on this box; the Photos app may not open yet. It is safe to try again."
      exit 7
    fi
    if ! ${pkgs.zstd}/bin/zstd -dc "$DUMP" \
         | ${pkgs.docker}/bin/docker exec -i -e PGPASSWORD="$DB_PASS" immich_postgres \
             psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 >/dev/null; then
      say db-failed true "Your files were restored, but the photo database did not finish restoring. Your photos are on this box; the Photos app may not open yet. It is safe to try again - repeating this step is designed to be harmless."
      exit 7
    fi
    say db-restored true "Your photo library is restored. Starting your apps."

    # ---- phase 6: start everything, and mark the box promoted.
    # RESTART for immich, not start. Phase 5 started its oneshot unit
    # (RemainAfterExit=true) to get postgres up, then stopped the app containers
    # at the DOCKER layer. `start` on an already-active oneshot is a NO-OP, so
    # the containers this script stopped were never coming back - found on
    # hardware (37nzy, 2026-08-16): five services healthy, and exactly the two
    # held-down containers Exited(143). Every stop must be paired with a start
    # at the SAME layer or via a verb that re-executes; restart re-runs compose
    # down+up and revives them in every unit state, including on a retry.
    ${pkgs.systemd}/bin/systemctl restart --no-block cloudunit-immich.service || true
    ${lib.concatMapStringsSep "\n    " (s:
      "${pkgs.systemd}/bin/systemctl start --no-block cloudunit-${s}.service || true")
      (builtins.filter (s: s != "immich") config.keephaven.activeApps)}
    $co/printf 'promoted_from=%s\npromoted_at=%s\n' "''${PEER:-unknown}" \
      "$($co/date -u '+%Y-%m-%dT%H:%M:%SZ')" > ${promotedFlag}
    $co/chmod 644 ${promotedFlag}
    # The pairing is retired, not reused: the peer is presumably gone. No
    # automatic re-pairing - the dashboard tells the owner to add a second box.
    ${pkgs.coreutils}/bin/rm -f ${pairEnv}

    # ---- phase 6b: VERIFY ALL SIX SERVICES, and re-run their provisioners.
    #
    # Restarting a service is not the same as it coming up healthy, and each
    # service's provisioner/self-heal is a RemainAfterExit oneshot that ran once
    # at boot and will NOT re-run on its own - so a promotion that restarts a
    # service never re-fires its recovery. That is why Kavita wedged against the
    # restored database after promotion and its self-heal never fired (98yzs,
    # 2026-08-17): the recovery is inside cloudunit-kavita-provision, which was
    # already active-and-done from boot. Restarting the provisioners here both
    # re-runs every self-heal AND lets us report per-service truth instead of
    # assuming success (the generalized form of the Immich container bug).
    #
    # Health endpoints are the ones the dashboard already trusts (dashboard.nix).
    for svc in ${lib.concatStringsSep " " config.keephaven.activeApps}; do
      ${pkgs.systemd}/bin/systemctl start --no-block "cloudunit-$svc-provision.service" 2>/dev/null \
        || ${pkgs.systemd}/bin/systemctl restart --no-block "cloudunit-$svc-provision.service" 2>/dev/null || true
    done

    # Poll each service until healthy, up to ~4 min total (cold start after a
    # restore is slow; Immich and Kavita are the slow ones). A provisioner
    # restarted above may itself take a while, which is fine - we poll the
    # SERVICE health, not the provisioner.
    check_health() {
      case "$1" in
        immich)         P=2283;  H=/api/server/ping ;;
        jellyfin)       P=8096;  H=/System/Info/Public ;;
        navidrome)      P=4533;  H=/ping ;;
        audiobookshelf) P=13378; H=/healthcheck ;;
        kavita)         P=5001;  H=/api/health ;;
        freshrss)       P=8081;  H=/ ;;
      esac
      # Accept 2xx OR 3xx: a service that is SERVING is healthy, and FreshRSS
      # answers its root with a REDIRECT to its login, not a 200. The old
      # ==200 test timed out on FreshRSS for the full ~4 min and wrote a false
      # "News is down" on a box where News was fine (bp2py, 2026-08-18). This
      # matches what the dashboard already treats as ready (any resolved
      # response, dashboard.nix probe) while still rejecting a refused
      # connection (000) or a server error (5xx), which are genuinely not-up.
      C="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$P$H" 2>/dev/null)"
      case "$C" in (2[0-9][0-9]|3[0-9][0-9]) return 0 ;; (*) return 1 ;; esac
    }
    # APP PICKER: an app the owner switched off is not expected to come up, so it
    # is not waited on or reported as down.
    UNHEALTHY=""
    for svc in ${lib.concatStringsSep " " config.keephaven.activeApps}; do
      case " ${lib.concatStringsSep " " config.keephaven.pickableApps} " in
        (*" $svc "*) [ -e "${config.keephaven.appsDir}/$svc.off" ] && continue ;;
      esac
      UNHEALTHY="$UNHEALTHY $svc"
    done
    UNHEALTHY="$(echo $UNHEALTHY)"
    k=0
    while [ -n "$UNHEALTHY" ] && [ "$k" -lt 48 ]; do
      STILL=""
      for svc in $UNHEALTHY; do
        check_health "$svc" || STILL="$STILL $svc"
      done
      UNHEALTHY="$(echo $STILL)"
      [ -n "$UNHEALTHY" ] || break
      ${pkgs.coreutils}/bin/sleep 5; k=$((k + 1))
    done

    if [ -n "$UNHEALTHY" ]; then
      # Map the internal names to what the owner sees on the dashboard.
      NICE=""
      for svc in $UNHEALTHY; do
        case "$svc" in
          immich) NICE="$NICE Photos" ;; jellyfin) NICE="$NICE Movies" ;;
          navidrome) NICE="$NICE Music" ;; audiobookshelf) NICE="$NICE Audiobooks" ;;
          kavita) NICE="$NICE Books" ;; freshrss) NICE="$NICE News" ;;
        esac
      done
      NICE="$(echo $NICE | ${pkgs.gnused}/bin/sed 's/ /, /g')"
      # NOT a failure of the restore: the DATA is all here. Say exactly that, and
      # that a restart usually clears it, and where to go if not.
      say restored-app-down true "Your photos and files are all restored and this is now your main Keephaven. One or more apps did not finish starting: $NICE. Your data is safe. Try restarting from Settings; if an app is still not ready after that, contact support@keephaven.co. You no longer have a backup - add a second Keephaven to protect your photos again."
      log "promote: restore complete but these apps did not come up healthy:$UNHEALTHY"
    fi

    # ---- phase 7: the Photos credential.
    # The restored database carries the SOURCE box's admin account, so Photos
    # currently wants that box's sticker password - not this one's. The existing
    # password mechanism (apply-password.sh) cannot fix it: every service there
    # authenticates with the OLD password before setting a new one, and this box
    # has no way to know the other box's password (and it must never travel in a
    # replica). So: reset the Immich admin password to a fresh random one via
    # immich-admin, capture what it prints, then use that as the "old" password
    # to set THIS box's sticker password through the normal API.
    # BEST EFFORT ONLY - never fails the promotion. The data is what matters, and
    # if this cannot be done the owner is told exactly which password to use.
    STICKER="$(${pkgs.gawk}/bin/awk -F= '/^UNIT_PASSWORD=/{print $2; exit}' ${unitEnv} 2>/dev/null)"
    CREDS=unknown
    if [ -n "''${STICKER:-}" ]; then
      # Wait for the API only while its container is actually coming up. The
      # first version polled an API belonging to a container this script had
      # itself stopped (37nzy): five minutes burned, then the fallback fired for
      # the wrong reason. Bail out once the restart has had time to land (60s)
      # if the container is not running; keep the generous total only while it
      # IS running, because Immich's cold start after a restore is slow.
      i=0
      while [ "$i" -lt 60 ]; do
        [ "$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' http://localhost:2283/api/server/ping 2>/dev/null)" = "200" ] && break
        RUNNING="$(${pkgs.docker}/bin/docker inspect -f '{{.State.Running}}' immich_server 2>/dev/null || echo false)"
        if [ "$i" -ge 12 ] && [ "$RUNNING" != "true" ]; then
          log "photos credential: immich_server is not running; skipping the wait"
          break
        fi
        ${pkgs.coreutils}/bin/sleep 5; i=$((i + 1))
      done
      RESET="$(${pkgs.docker}/bin/docker exec immich_server immich-admin reset-admin-password 2>/dev/null \
               | ${pkgs.gnugrep}/bin/grep -oE '[A-Za-z0-9._@!#%^*+=-]{8,}' | ${pkgs.coreutils}/bin/tail -n1 || true)"
      if [ -n "''${RESET:-}" ]; then
        EMAIL="keephaven@local"
        TOK="$(${pkgs.curl}/bin/curl -s -X POST http://localhost:2283/api/auth/login \
                -H 'Content-Type: application/json' \
                -d "{\"email\":\"$EMAIL\",\"password\":\"$RESET\"}" \
              | ${pkgs.gnugrep}/bin/grep -o '"accessToken":"[^"]*"' | ${pkgs.coreutils}/bin/cut -d'"' -f4 || true)"
        if [ -n "''${TOK:-}" ]; then
          CODE="$(${pkgs.curl}/bin/curl -s -o /dev/null -w '%{http_code}' -X POST http://localhost:2283/api/auth/change-password \
                   -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
                   -d "{\"password\":\"$RESET\",\"newPassword\":\"$STICKER\"}" || true)"
          case "$CODE" in (200|201) CREDS=ok ;; esac
        fi
      fi
    fi

    # The wording matters more here than anywhere else in the arc: this is read
    # by someone who has just lost a Keephaven. Say what works, what to do, and
    # WHY - and on the failure path, give them a way out if they no longer have
    # the other box's sticker, which is likely if the box was lost in a fire or
    # a theft. [Dafarus, 2026-08-10]
    # If a service failed to come up, phase 6b already told the owner the honest
    # story (data safe, an app is down, try a restart). Do not paper over it with
    # a "done" message that implies everything is running.
    if [ -n "''${UNHEALTHY:-}" ]; then
      exit 0
    fi
    if [ "$CREDS" = "ok" ]; then
      # Confirm the change rather than letting them discover it: their Photos
      # password is not what it was on the box the library came from.
      say done true "This is now your main Keephaven. All of your photos and files are here, and every app - including Photos - now uses THIS box's sticker password. You no longer have a backup: your photos are on this box only. Add a second Keephaven and pair it to protect them again."
    else
      say done-check-password true "This is now your main Keephaven and all of your photos and files are here. One thing about signing in: your photo library came from keephaven-''${PEER:-your other box}, and it kept that box's sign-in. So for Photos, use the password printed on THAT box's sticker. Everything else - Movies, Music, Books and file sharing - uses this box's own sticker password as usual. Nothing is missing; it is only that one sign-in travelled with the library. If you no longer have that sticker, email support@keephaven.co and we can reset it for you. You no longer have a backup: your photos are on this box only. Add a second Keephaven and pair it to protect them again."
    fi
    exit 0
  '';
in
{
  config = lib.mkMerge [
    {
      cloudunit.wrappers.promote = "${promote}/bin/cloudunit-promote";
      cloudunit.wrappers.promoteStart = "${startPromote}/bin/cloudunit-promote-start";
      cloudunit.wrappers.photosSigninStatus = "${photosStatus}/bin/cloudunit-photos-signin-status";
      cloudunit.wrappers.photosSigninFix = "${photosFix}/bin/cloudunit-photos-signin-fix";
      cloudunit.wrappers.promotePreflight = "${preflight}/bin/cloudunit-promote-preflight";
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ promote preflight startPromote photosStatus photosFix ];

      # Run as a unit rather than inline from Settings: it can take a long time,
      # and the owner must be able to close the page, lose Wi-Fi, or reload
      # without killing a restore in progress.
      systemd.services.cloudunit-promote = {
        description = "Cloud Unit - restore this box from its backup and make it the main Keephaven";
        unitConfig.RequiresMountsFor = dataDir;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${promote}/bin/cloudunit-promote";
          TimeoutStartSec = "6h";
        };
      };
    })
  ];
}
