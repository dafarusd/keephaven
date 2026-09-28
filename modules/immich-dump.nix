# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# IMMICH DATABASE DUMP — the shared producer.
#
# ALWAYS PRESENT, deliberately: this module is NOT behind
# keephaven.replication.enable. Two callers need it and they have different
# lifetimes:
#   1. replication (Phase 2)  — the nightly dump pushed to the paired box.
#      Only exists when the replication feature is on.
#   2. THE UPDATE ARC         — the pre-update dump that satisfies the standing
#      HARD PREREQUISITE (decisions.md: no release that changes a service-image
#      digest may reach customers via OTA without a pre-update pg_dump). That
#      one must work on EVERY box, including customer boxes with replication
#      switched off — which is exactly why the producer cannot live inside the
#      replication module's mkIf.
#
# Parameterised by output directory and retention so each caller keeps its own
# set: replication's staging is transient (the receiver holds the real copies),
# while the pre-update dumps are a box's own last line of defence against an
# irreversible service migration.
#
# Emits <name>.sql.zst plus a .meta sidecar. The sidecar's source_version is
# load-bearing for the Phase 4 restore interlock and for support: it says which
# image the schema came from.
# ============================================================================

let
  dataDir = "/var/lib/cloudunit";
  immichEnv = "${dataDir}/immich/.env";
  versionFile = "/etc/cloudunit/update/version";

  dump = pkgs.writeShellScriptBin "cloudunit-immich-dump" ''
    set -u
    # PIPEFAIL IS LOAD-BEARING. Without it a pipeline reports only its LAST
    # command, so `pg_dump | zstd` returned 0 when pg_dump had failed outright --
    # zstd cheerfully compresses an empty stream. The result was a 13-byte file
    # with a full .meta sidecar beside it, which the system then believed was a
    # valid restore point (found on hardware 2026-08-08). That is worse than
    # having no pre-update dump at all: it manufactures false confidence, and
    # retention would have kept it.
    set -o pipefail
    co=${pkgs.coreutils}/bin
    # Path ONLY. Never bake "-t tag" into this variable: a quoted expansion
    # (LOGGER="path -t tag" used as "$LOGGER" "msg") then becomes a single
    # command name and every log line silently vanishes -- exactly how this
    # script lost its own logging
    # (found on hardware 2026-08-08, in the code whose job is making failures
    # visible). Always: "$LOGGER" -t <tag> "message".
    LOGGER=${pkgs.util-linux}/bin/logger

    # $1 = output directory, $2 = how many dumps to keep there.
    OUTDIR="''${1:-${dataDir}/update/pre-update-dumps}"
    KEEP="''${2:-2}"

    # Exit codes are load-bearing for the update arc's decision (see update.nix):
    #   0  dump written
    #   2  NOTHING TO PROTECT (no Immich env / no container) - caller may proceed
    #   1  a real failure with a database present - caller should NOT proceed
    #      silently past an irreversible migration
    if [ ! -r ${immichEnv} ]; then
      "$LOGGER" -t cloudunit-immich-dump "no immich .env - nothing to dump"
      echo "no immich environment; nothing to dump" >&2
      exit 2
    fi
    DB_USER="$(${pkgs.gawk}/bin/awk -F= '/^DB_USERNAME=/{print $2; exit}' ${immichEnv})"
    DB_NAME="$(${pkgs.gawk}/bin/awk -F= '/^DB_DATABASE_NAME=/{print $2; exit}' ${immichEnv})"
    DB_PASS="$(${pkgs.gawk}/bin/awk -F= '/^DB_PASSWORD=/{print $2; exit}' ${immichEnv})"
    if [ -z "$DB_USER" ] || [ -z "$DB_NAME" ]; then
      "$LOGGER" -t cloudunit-immich-dump "FAILED - immich .env has no DB_USERNAME/DB_DATABASE_NAME"
      echo "immich environment is incomplete" >&2
      exit 1
    fi
    if ! ${pkgs.docker}/bin/docker inspect immich_postgres >/dev/null 2>&1; then
      "$LOGGER" -t cloudunit-immich-dump "immich_postgres container absent - nothing to dump"
      echo "no immich database container; nothing to dump" >&2
      exit 2
    fi

    $co/mkdir -p "$OUTDIR"
    $co/chmod 700 "$OUTDIR"
    VER="$($co/cat ${versionFile} 2>/dev/null || echo unknown)"
    TS="$($co/date -u '+%Y%m%dT%H%M%SZ')"
    BASE="immich-$TS"
    TMP="$OUTDIR/.$BASE.sql.zst.part"
    OUT="$OUTDIR/$BASE.sql.zst"

    # --clean --if-exists so the dump can be replayed over an existing database
    # (the restore path). Streamed into zstd; never lands uncompressed. The
    # password goes through the environment, never argv.
    if ! ${pkgs.docker}/bin/docker exec -e PGPASSWORD="$DB_PASS" immich_postgres \
           pg_dump -U "$DB_USER" -d "$DB_NAME" --clean --if-exists \
         | ${pkgs.zstd}/bin/zstd -q -T0 -o "$TMP"; then
      $co/rm -f "$TMP"
      "$LOGGER" -t cloudunit-immich-dump "FAILED - pg_dump errored (database IS present)"
      echo "pg_dump failed" >&2
      exit 1
    fi
    if [ ! -s "$TMP" ]; then
      $co/rm -f "$TMP"
      "$LOGGER" -t cloudunit-immich-dump "FAILED - pg_dump produced an empty file"
      echo "pg_dump produced an empty file" >&2
      exit 1
    fi

    # STRUCTURAL VERIFICATION before this is called a backup. A byte-count floor
    # cannot tell a small valid dump from a truncated one, so check what pg_dump
    # itself guarantees: a completed dump carries its "PostgreSQL database dump
    # complete" marker near the end. That single check rejects an empty stream, a
    # stream truncated mid-write, and anything that is not a pg_dump at all.
    # Read into a variable rather than piping into grep -q: with pipefail on, a
    # grep that exits early can SIGPIPE its producer and fail the pipeline even
    # on success. A generous tail window absorbs version differences in trailing
    # content (PG18, for instance, emits a \unrestrict line after the marker).
    TAILTXT="$(${pkgs.zstd}/bin/zstd -dc "$TMP" 2>/dev/null | $co/tail -c 4096 || true)"
    case "$TAILTXT" in
      (*"PostgreSQL database dump complete"*) ;;
      (*)
        $co/rm -f "$TMP"
        "$LOGGER" -t cloudunit-immich-dump "FAILED - dump is not a complete pg_dump (empty or truncated); refusing to write it"
        echo "the database backup was incomplete and has been discarded" >&2
        exit 1
        ;;
    esac

    # Only now is it a backup. Nothing above this line writes $OUT or the
    # sidecar, so a rejected dump leaves NOTHING behind that could be mistaken
    # for a restore point.
    $co/mv -f "$TMP" "$OUT"

    SHA="$($co/sha256sum "$OUT" | $co/cut -d' ' -f1)"
    SIZE="$($co/stat -c %s "$OUT")"
    # Immich RENAMES this table across majors (v3 `asset`, v2 `assets`), so try
    # both. A failure must not fail the dump, but it must not be silent either.
    ASSETS=""
    for tbl in asset assets; do
      ASSETS="$(${pkgs.docker}/bin/docker exec -e PGPASSWORD="$DB_PASS" immich_postgres \
        psql -U "$DB_USER" -d "$DB_NAME" -tAc "select count(*) from $tbl" 2>/dev/null \
        | ${pkgs.gnugrep}/bin/grep -E '^[0-9]+$' || echo "")"
      [ -n "$ASSETS" ] && break
    done
    [ -n "$ASSETS" ] || "$LOGGER" -t cloudunit-immich-dump "WARNING could not read an asset count (tried: asset, assets)"

    $co/printf 'source_version=%s\ntaken_utc=%s\nsha256=%s\nbytes=%s\nassets=%s\n' \
      "$VER" "$TS" "$SHA" "$SIZE" "$ASSETS" > "$OUTDIR/$BASE.meta"

    # Retention, ordered by the timestamp in the FILENAME. Never mtime: mtime is
    # reordered by copies, restores and stray touches, and ordering on it once
    # made rotation delete every real backup (Phase 2 gate G7, 2026-08-07).
    cd "$OUTDIR" || exit 0
    ${pkgs.findutils}/bin/find . -maxdepth 1 -type f -name 'immich-*.sql.zst' -printf '%f\n' 2>/dev/null \
      | $co/sort -r | $co/tail -n +$((KEEP + 1)) \
      | while read -r f; do
          $co/rm -f "$f" "''${f%.sql.zst}.meta"
          "$LOGGER" -t cloudunit-immich-dump "retention: removed $f"
        done

    "$LOGGER" -t cloudunit-immich-dump "dump ok: $BASE.sql.zst ($SIZE bytes, version $VER, assets ''${ASSETS:-unknown}) -> $OUTDIR"
    echo "$OUT"
  '';
in
{
  environment.systemPackages = [ dump ];
  cloudunit.wrappers.immichDump = "${dump}/bin/cloudunit-immich-dump";
}
