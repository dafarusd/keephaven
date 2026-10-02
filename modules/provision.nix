# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  unitEnv = "${dataDir}/unit.env";
  setupFlag = "${dataDir}/.setup-complete";

  mkProvision = { name, after ? [], script }:
    {
      "cloudunit-${name}-provision" = {
        description = "Cloud Unit - ${name} pre-provisioning";
        wantedBy = [ "multi-user.target" ];
        after = [ "network-online.target" ] ++ after;
        wants = [ "network-online.target" ];
        unitConfig = {
          ConditionPathExists = setupFlag;
          RequiresMountsFor = dataDir;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = script;
        };
      };
    };

  curl = "${pkgs.curl}/bin/curl";
  grep = "${pkgs.gnugrep}/bin/grep";
  jq = "${pkgs.jq}/bin/jq";

  jellyfinProvision = pkgs.writeShellScript "cloudunit-jellyfin-provision" ''
    set -uo pipefail
    J="http://localhost:8096"
    USERNAME="keephaven"; PASSWORD="keephaven"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi

    jf_token() {
      ${curl} -s -X POST "$J/Users/AuthenticateByName" \
        -H 'Authorization: MediaBrowser Client="prov", Device="prov", DeviceId="prov1", Version="1"' \
        -H "Content-Type: application/json" \
        -d "{\"Username\":\"$USERNAME\",\"Pw\":\"$PASSWORD\"}" 2>/dev/null \
        | ${grep} -o '"AccessToken":"[^"]*"' | cut -d'"' -f4 || true
    }

    # Idempotent Movies library -- mirrors the Kavita/ABS fixes by checking the REAL
    # library list instead of trusting a startup proxy. The old code guarded on
    # StartupWizardCompleted (from /System/Info/Public), which Jellyfin serves 200 on
    # early in boot while still reporting false, so the guard raced and re-created the
    # library EVERY boot -> Movies, Movies2, Movies3 ... (reproduced on 6xf7f/d3p5s).
    # This: (1) deletes ONLY provably auto-created duplicates -- name "Movies"+digits
    # AND sole location exactly ["/media"] -- so a customer library (custom name, or a
    # customized path set) is NEVER touched; (2) ensures exactly one canonical
    # Movies -> /media. Runs on BOTH the already-set-up and fresh paths so boxes
    # provisioned before this fix self-heal. DELETE-by-name (204) + this GET shape
    # hardware-verified on d3p5s 2026-07-28.
    ensure_movies_library() {
      mtoken="$1"
      [ -z "$mtoken" ] && { echo "jellyfin: no token; skipping library ensure" >&2; return 0; }
      libs=$(${curl} -s "$J/Library/VirtualFolders" -H "Authorization: MediaBrowser Token=\"$mtoken\"" 2>/dev/null || true)
      for name in $(printf '%s' "$libs" | ${jq} -r '.[] | select(.Name|test("^Movies[0-9]+$")) | select(.Locations==["/media"]) | .Name' 2>/dev/null); do
        ${curl} -s -o /dev/null -X DELETE "$J/Library/VirtualFolders?name=$name" \
          -H "Authorization: MediaBrowser Token=\"$mtoken\"" 2>/dev/null || true
        echo "jellyfin: removed auto-created duplicate library $name"
      done
      # Canonical, untouched library = name "Movies" with sole location ["/media"].
      canon=$(${curl} -s "$J/Library/VirtualFolders" -H "Authorization: MediaBrowser Token=\"$mtoken\"" 2>/dev/null \
        | ${jq} -c '.[] | select(.Name=="Movies") | select(.Locations==["/media"])' 2>/dev/null || true)
      if [ -z "$canon" ]; then
        # Create it. EnableRealtimeMonitor:true so a movie dropped over SMB auto-ingests
        # (~1 min, Jellyfin's monitor debounce) with NO manual scan -- without it the
        # library needs a manual "Scan All". Hardware-verified on g7t6w 2026-07-28: the
        # monitor starts watching on create, no Jellyfin restart needed.
        ${curl} -s -X POST "$J/Library/VirtualFolders?name=Movies&collectionType=movies&refreshLibrary=false" \
          -H "Authorization: MediaBrowser Token=\"$mtoken\"" -H "Content-Type: application/json" \
          -d '{"LibraryOptions":{"EnableRealtimeMonitor":true,"PathInfos":[{"Path":"/media"}]}}' >/dev/null 2>&1 || true
        echo "jellyfin: Movies library -> /media created (realtime monitor on)"
      elif [ "$(printf '%s' "$canon" | ${jq} -r '.LibraryOptions.EnableRealtimeMonitor')" != "true" ]; then
        # Self-heal a box provisioned before this fix: turn the monitor on. Only the
        # untouched sole-/media config is touched -- a customer-customized library (extra
        # paths) is left alone. The flag persists, so it takes effect now or next restart.
        ${curl} -s -o /dev/null -X POST "$J/Library/VirtualFolders/LibraryOptions" \
          -H "Authorization: MediaBrowser Token=\"$mtoken\"" -H "Content-Type: application/json" \
          -d "$(printf '%s' "$canon" | ${jq} -c '{Id: .ItemId, LibraryOptions: (.LibraryOptions | .EnableRealtimeMonitor=true)}')" 2>/dev/null || true
        echo "jellyfin: enabled realtime monitor on Movies"
      fi
    }

    ready=""
    for i in $(seq 1 60); do
      code=$(${curl} -s -o /dev/null -w "%{http_code}" "$J/System/Info/Public" 2>/dev/null || true)
      [ "$code" = "200" ] && { ready=1; break; }
      sleep 5
    done
    [ -z "$ready" ] && { echo "jellyfin HTTP never came up" >&2; exit 1; }

    info=$(${curl} -s "$J/System/Info/Public" 2>/dev/null || true)
    case "$info" in *'"StartupWizardCompleted":true'*)
      # Already set up. Still converge the library to exactly one (self-heals boxes
      # that accumulated duplicates before this fix), then exit.
      ensure_movies_library "$(jf_token)"
      echo "jellyfin already provisioned"; exit 0 ;;
    esac

    token=""
    for attempt in $(seq 1 10); do
      ${curl} -s -X POST "$J/Startup/Configuration" -H "Content-Type: application/json" \
        -d '{"UICulture":"en-US","MetadataCountryCode":"US","PreferredMetadataLanguage":"en"}' >/dev/null 2>&1 || true
      ${curl} -s "$J/Startup/User" >/dev/null 2>&1 || true
      ${curl} -s -X POST "$J/Startup/User" -H "Content-Type: application/json" \
        -d "{\"Name\":\"$USERNAME\",\"Password\":\"$PASSWORD\"}" >/dev/null 2>&1 || true
      ${curl} -s -X POST "$J/Startup/RemoteAccess" -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' >/dev/null 2>&1 || true
      ${curl} -s -X POST "$J/Startup/Complete" >/dev/null 2>&1 || true
      token=$(jf_token)
      [ -n "$token" ] && break
      sleep 5
    done
    [ -z "$token" ] && { echo "jellyfin provisioning failed" >&2; exit 1; }

    ensure_movies_library "$token"
    echo "jellyfin provisioned: admin=$USERNAME, Movies library -> /media"
  '';

  navidromeProvision = pkgs.writeShellScript "cloudunit-navidrome-provision" ''
    set -uo pipefail
    N="http://localhost:4533"
    USERNAME="keephaven"; PASSWORD="keephaven"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi

    ready=""
    for i in $(seq 1 60); do
      code=$(${curl} -s -o /dev/null -w "%{http_code}" "$N/ping" 2>/dev/null || true)
      [ "$code" = "200" ] && { ready=1; break; }
      sleep 5
    done
    [ -z "$ready" ] && { echo "navidrome HTTP never came up" >&2; exit 1; }

    code=$(${curl} -s -o /dev/null -w "%{http_code}" -X POST "$N/auth/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
    [ "$code" = "200" ] && { echo "navidrome already provisioned"; exit 0; }

    ok=""
    for attempt in $(seq 1 10); do
      code=$(${curl} -s -o /dev/null -w "%{http_code}" -X POST "$N/auth/createAdmin" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
      [ "$code" = "200" ] && { ok=1; break; }
      lc=$(${curl} -s -o /dev/null -w "%{http_code}" -X POST "$N/auth/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
      [ "$lc" = "200" ] && { ok=1; break; }
      sleep 5
    done
    [ -z "$ok" ] && { echo "navidrome provisioning failed" >&2; exit 1; }
    echo "navidrome provisioned: admin=$USERNAME"
  '';
  freshrssProvision = pkgs.writeShellScript "cloudunit-freshrss-provision" ''
    set -uo pipefail
    DOCKER="${pkgs.docker}/bin/docker"
    USERNAME="keephaven"; PASSWORD="keephaven"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi
    FR="/var/www/FreshRSS"

    ready=""
    for i in $(seq 1 60); do
      if $DOCKER exec freshrss true >/dev/null 2>&1; then ready=1; break; fi
      sleep 5
    done
    [ -z "$ready" ] && { echo "freshrss container never came up" >&2; exit 1; }

    if $DOCKER exec freshrss test -f "$FR/data/config.php" >/dev/null 2>&1; then
      echo "freshrss already provisioned"; exit 0
    fi

    ok=""
    for attempt in $(seq 1 10); do
      $DOCKER exec freshrss php "$FR/cli/do-install.php" \
        --default-user "$USERNAME" --auth-type form --db-type sqlite >/dev/null 2>&1 || true
      $DOCKER exec freshrss php "$FR/cli/create-user.php" \
        --user "$USERNAME" --password "$PASSWORD" --api_password "$PASSWORD" >/dev/null 2>&1 || true
      $DOCKER exec freshrss bash "$FR/cli/access-permissions.sh" >/dev/null 2>&1 || true
      if $DOCKER exec freshrss test -f "$FR/data/config.php" >/dev/null 2>&1 \
         && $DOCKER exec freshrss php "$FR/cli/list-users.php" 2>/dev/null | ${grep} -qx "$USERNAME"; then
        ok=1; break
      fi
      sleep 5
    done
    [ -z "$ok" ] && { echo "freshrss provisioning failed" >&2; exit 1; }
    echo "freshrss provisioned: user=$USERNAME"
  '';
  kavitaProvision = pkgs.writeShellScript "cloudunit-kavita-provision" ''
    set -uo pipefail
    K="http://localhost:5001"
    CONFIG="${dataDir}/kavita/config"
    MARKER="${dataDir}/kavita/.provisioned"
    RECOVERED="${dataDir}/kavita/.recovery-attempted"
    USERNAME="keephaven"; PASSWORD="keephaven"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi

    # TARGETED REPAIR: a broken appsettings.json, fixed BEFORE the 5-minute probe.
    #
    # Found on hardware 2026-08-14 (3vjmb, fresh flash): Kavita wrote its own
    # appsettings.json as ZERO BYTES on the box's very first boot, then restart-
    # looped forever. Deleting the file and restarting fixed it completely - the
    # config regenerated at 607 bytes, provisioning ran, the Books library was
    # created. SMART was clean, so this is a truncated write, not failing storage.
    #
    # The generic recovery below WOULD have triggered (its condition is only "HTTP
    # never came up"), but it is ONE-SHOT: it sets .recovery-attempted, and if the
    # retry does not work, every later boot takes the "already retried" branch and
    # refuses. A transient bad write therefore becomes a PERMANENT failure, and the
    # customer sees Books dead on a brand-new box with no way to fix it.
    #
    # So this repair is deliberately separate and runs first:
    #   - it costs seconds instead of five minutes,
    #   - it does NOT consume the one-shot budget, leaving the generic recovery
    #     available for the SQLite wedge it was written for,
    #   - and it is NOT gated on .provisioned, because it is safe on a box with a
    #     library: appsettings.json is regenerated config, not user data, and the
    #     DB, the reading progress and the books on /manga are untouched. That
    #     turns the same permanent failure into a self-heal for existing boxes too.
    #
    # Only PROVABLY broken files qualify - empty, or not valid JSON. Both are
    # states Kavita itself cannot load, so nothing is lost by moving them aside;
    # a merely unexpected-but-valid file might hold a customer's setting and is
    # left alone. Move-aside, not delete, per the existing convention.
    APPSETTINGS="$CONFIG/appsettings.json"
    if [ -e "$APPSETTINGS" ]; then
      BROKEN=""
      if [ ! -s "$APPSETTINGS" ]; then
        BROKEN="empty"
      elif ! ${pkgs.jq}/bin/jq empty "$APPSETTINGS" >/dev/null 2>&1; then
        BROKEN="not valid JSON"
      fi
      if [ -n "$BROKEN" ]; then
        echo "kavita: appsettings.json is $BROKEN -- moving it aside so Kavita regenerates it" >&2
        ${pkgs.systemd}/bin/systemctl stop cloudunit-kavita || true
        mv -f "$APPSETTINGS" "$APPSETTINGS.broken-$(date +%s)" || rm -f "$APPSETTINGS"
        ${pkgs.systemd}/bin/systemctl start cloudunit-kavita || true
      fi
    fi

    # Wait ~5 min for Kavita's HTTP to answer. 0 = came up, 1 = never did.
    probe_ready() {
      for i in $(seq 1 60); do
        code=$(${curl} -s -o /dev/null -w "%{http_code}" "$K/api/health" 2>/dev/null || true)
        [ "$code" = "200" ] && return 0
        sleep 5
      done
      return 1
    }

    if ! probe_ready; then
      # Kavita wedged: a .NET startup deadlock leaves a corrupted SQLite state that
      # re-wedges every boot with no recovery (gate 2026-07-26). Make that
      # unrecoverable state recoverable, but ONLY where safe:
      #   1. Never a populated DB. A MARKER means Kavita was provisioned before and
      #      may hold the owner's library + reading progress; a clear would destroy
      #      it. Surface as failed (health report shows unhealthy) instead.
      #   2. One attempt total. RECOVERED guards against re-clearing on later boots.
      #   3. MOVE-ASIDE, not delete — the wedged DB is kept for forensics; nothing
      #      is truly lost, and the actual books live on a separate mount (/manga).
      if [ -f "$MARKER" ] || [ -f "$RECOVERED" ]; then
        echo "kavita HTTP never came up; not auto-clearing (already provisioned or already retried) -- needs support" >&2
        exit 1
      fi
      touch "$RECOVERED"
      echo "kavita HTTP never came up on first boot -- moving aside corrupted config, retrying once" >&2
      ${pkgs.systemd}/bin/systemctl stop cloudunit-kavita || true
      ts=$(date +%s)
      [ -d "$CONFIG" ] && mv "$CONFIG" "$CONFIG.wedged-$ts" || true
      mkdir -p "$CONFIG"
      ${pkgs.systemd}/bin/systemctl start cloudunit-kavita || true
      if ! probe_ready; then
        echo "kavita HTTP never came up after recovery retry" >&2
        exit 1
      fi
    fi

    # Kavita, unlike Jellyfin, does NOT auto-create a library on registration, so a
    # book dropped into the Books share (kavita/media -> /manga in-container) is
    # invisible until a library points at it -- empty library list, scans no-op with
    # NO error anywhere (confirmed on n455y 2026-07-27: [] libraries on a box running
    # for weeks). Ensure a "Books" library on /manga. Idempotent: create ONLY when
    # none exists, so a customer who renamed or restructured their own libraries is
    # never fought. Called on BOTH the already-provisioned and fresh paths, so boxes
    # already shipped on <=.26 self-heal on their first boot carrying this fix.
    # HARDWARE-VERIFIED payload (n455y 2026-07-27): this Kavita's CreateLibraryDto
    # REQUIRES fileGroupTypes + excludePatterns (a create omitting them 400s). type 2
    # = Book; fileGroupTypes [1,2,3,4] = Archive/Epub/Pdf/Images. create auto-enqueues
    # the first scan.
    ensure_books_library() {
      etoken=$(${curl} -s -X POST "$K/api/account/login" -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null \
        | ${grep} -o '"token":"[^"]*"' | cut -d'"' -f4 || true)
      [ -z "$etoken" ] && { echo "kavita: no token; skipping library ensure" >&2; return 0; }
      libs=$(${curl} -s "$K/api/Library/libraries" -H "Authorization: Bearer $etoken" 2>/dev/null || true)
      case "$libs" in
        *'"id"'*) echo "kavita: library already present; not creating"; return 0 ;;
      esac
      ${curl} -s -X POST "$K/api/Library/create" -H "Authorization: Bearer $etoken" \
        -H "Content-Type: application/json" \
        -d '{"name":"Books","type":2,"folders":["/manga"],"fileGroupTypes":[1,2,3,4],"excludePatterns":[]}' \
        >/dev/null 2>&1 || true
      echo "kavita: Books library -> /manga created"
    }

    code=$(${curl} -s -o /dev/null -w "%{http_code}" -X POST "$K/api/account/login" \
      -H "Content-Type: application/json" \
      -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
    if [ "$code" = "200" ]; then
      touch "$MARKER"; echo "kavita already provisioned"
      ensure_books_library
      exit 0
    fi

    ok=""
    for attempt in $(seq 1 10); do
      ${curl} -s -X POST "$K/api/account/register" -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"email\":\"keephaven@local\"}" >/dev/null 2>&1 || true
      lc=$(${curl} -s -o /dev/null -w "%{http_code}" -X POST "$K/api/account/login" \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
      [ "$lc" = "200" ] && { ok=1; break; }
      sleep 5
    done
    [ -z "$ok" ] && { echo "kavita provisioning failed" >&2; exit 1; }
    touch "$MARKER"
    echo "kavita provisioned: admin=$USERNAME"
    ensure_books_library
  '';
  audiobookshelfProvision = pkgs.writeShellScript "cloudunit-audiobookshelf-provision" ''
    set -uo pipefail
    A="http://localhost:13378"
    USERNAME="keephaven"; PASSWORD="keephaven"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi

    ready=""
    for i in $(seq 1 60); do
      code=$(${curl} -s -o /dev/null -w "%{http_code}" "$A/healthcheck" 2>/dev/null || true)
      [ "$code" = "200" ] && { ready=1; break; }
      sleep 5
    done
    [ -z "$ready" ] && { echo "audiobookshelf HTTP never came up" >&2; exit 1; }

    # AudioBookshelf, like Kavita, does NOT auto-create a library on init, so an
    # audiobook dropped into the Audiobooks share (audiobookshelf/media ->
    # /audiobooks in-container) is invisible until a library points at it. Ensure an
    # "Audiobooks" library on /audiobooks. Idempotent: create ONLY when the server has
    # no library, so a customer who made their own is never fought. Called on BOTH the
    # already-init and fresh-init paths so boxes already shipped on <=.27 self-heal on
    # their first boot carrying this fix.
    # HARDWARE-VERIFIED on 6xf7f (ABS 2.35.1, 2026-07-28): POST /api/libraries with just
    # {name, folders:[{fullPath}], mediaType:"book"} succeeds (200) -- ABS fills the
    # provider/settings defaults itself (no hidden required fields, unlike Kavita).
    ensure_audiobooks_library() {
      atoken=$(${curl} -s -X POST "$A/login" -H "Content-Type: application/json" \
        -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}" 2>/dev/null \
        | ${grep} -o '"token":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
      [ -z "$atoken" ] && { echo "audiobookshelf: no token; skipping library ensure" >&2; return 0; }
      libs=$(${curl} -s "$A/api/libraries" -H "Authorization: Bearer $atoken" 2>/dev/null || true)
      case "$libs" in
        *'"id"'*) echo "audiobookshelf: library already present; not creating"; return 0 ;;
      esac
      ${curl} -s -X POST "$A/api/libraries" -H "Authorization: Bearer $atoken" \
        -H "Content-Type: application/json" \
        -d '{"name":"Audiobooks","folders":[{"fullPath":"/audiobooks"}],"mediaType":"book"}' \
        >/dev/null 2>&1 || true
      echo "audiobookshelf: Audiobooks library -> /audiobooks created"
    }

    st=$(${curl} -s "$A/status" 2>/dev/null || true)
    case "$st" in *'"isInit":true'*) echo "audiobookshelf already provisioned"; ensure_audiobooks_library; exit 0 ;; esac

    ok=""
    for attempt in $(seq 1 10); do
      ${curl} -s -X POST "$A/init" -H "Content-Type: application/json" \
        -d "{\"newRoot\":{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\"}}" >/dev/null 2>&1 || true
      st=$(${curl} -s "$A/status" 2>/dev/null || true)
      case "$st" in *'"isInit":true'*) ok=1; break ;; esac
      sleep 5
    done
    [ -z "$ok" ] && { echo "audiobookshelf provisioning failed" >&2; exit 1; }
    echo "audiobookshelf provisioned: root=$USERNAME"
    ensure_audiobooks_library
  '';
  # Container-side path of the Samba "Photos" drop-in share (see the :ro mount in
  # compose/immich/docker-compose.yml). Immich stores this as the library import
  # path and validates it exists inside the container at scan time.
  immichExternalPath = "/usr/src/app/external";

  immichProvision = pkgs.writeShellScript "cloudunit-immich-provision" ''
    set -uo pipefail
    I="http://localhost:2283"
    EMAIL="keephaven@local"; PASSWORD="keephaven"
    EXT="${immichExternalPath}"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi

    ready=""
    for i in $(seq 1 60); do
      code=$(${curl} -s -o /dev/null -w "%{http_code}" "$I/api/server/ping" 2>/dev/null || true)
      [ "$code" = "200" ] && { ready=1; break; }
      sleep 5
    done
    [ -z "$ready" ] && { echo "immich HTTP never came up" >&2; exit 1; }

    # Log in as the admin account, capturing accessToken + userId. Verified against
    # Immich v2.7.5 LoginResponseDto: fields are "accessToken" and "userId", used as
    # "Authorization: Bearer <accessToken>". POST /api/libraries and .../scan both
    # require admin:true on v2.7.5 -> the admin token created here is what we need.
    TOKEN=""; USERID=""
    login() {
      resp=$(${curl} -s -X POST "$I/api/auth/login" -H "Content-Type: application/json" \
        -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
      TOKEN=$(printf '%s' "$resp" | ${grep} -o '"accessToken":"[^"]*"' | cut -d'"' -f4 || true)
      USERID=$(printf '%s' "$resp" | ${grep} -o '"userId":"[^"]*"' | cut -d'"' -f4 || true)
      [ -n "$TOKEN" ] && [ -n "$USERID" ]
    }

    # If login already works the admin exists (2nd boot / OTA'd box) -> DON'T exit;
    # fall through to the idempotent library step. Otherwise decide by the
    # admin-sign-up status (verified against Immich v2.7.5 auth.service):
    #   2xx = no admin existed, we just created keephaven@local (fresh box);
    #   400 "server already has an admin" = an admin exists but it is NOT
    #        keephaven@local (e.g. a MIGRATED box). Do not touch it: log and
    #        exit 0 CLEANLY (no failed unit, no churn). Such a box uses the
    #        immich-external-library-manual runbook, not this auto-provisioner;
    #   anything else = Immich not ready yet -> retry, then fail loudly.
    if ! login; then
      sc=""
      for attempt in $(seq 1 10); do
        sc=$(${curl} -s -o /dev/null -w "%{http_code}" -X POST "$I/api/auth/admin-sign-up" \
          -H "Content-Type: application/json" \
          -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\",\"name\":\"Keephaven\"}" 2>/dev/null || true)
        case "$sc" in
          2*) break ;;
          400) echo "immich: server already has a different admin; skipping auto-provision (see immich-external-library-manual runbook)"; exit 0 ;;
          *) sleep 5 ;;
        esac
      done
      case "$sc" in 2*) : ;; *) echo "immich provisioning failed (admin-sign-up status=$sc)" >&2; exit 1 ;; esac
      # Admin now exists as keephaven@local; obtain a token (LOGIN only, never
      # re-signup -- a second signup would now return 400 and mislead us).
      ok=""
      for attempt in $(seq 1 10); do if login; then ok=1; break; fi; sleep 5; done
      [ -z "$ok" ] && { echo "immich provisioning failed (post-signup login)" >&2; exit 1; }
    fi
    echo "immich provisioned: admin=$EMAIL"

    # Idempotent: create the "Photos" External Library only if one pointing at our
    # container path does not already exist. GET returns a JSON array of libraries;
    # a substring match on the unique import path is a safe existence check.
    libs=$(${curl} -s -H "Authorization: Bearer $TOKEN" "$I/api/libraries" 2>/dev/null || true)
    # Only a well-formed JSON array is a trustworthy basis for create-or-skip. A
    # transient GET failure (empty/error body) must NOT fall through to CREATE:
    # Immich enforces no import-path uniqueness, so that would make a DUPLICATE
    # "Photos" library. On anything that isn't an array, back off and retry next boot.
    case "$libs" in
      '['*) : ;;
      *) echo "immich: could not list libraries (got: $libs); retrying next boot"; exit 0 ;;
    esac
    case "$libs" in
      *"$EXT"*) echo "immich external library already present"; exit 0 ;;
    esac

    created=$(${curl} -s -X POST "$I/api/libraries" \
      -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
      -d "{\"ownerId\":\"$USERID\",\"name\":\"Photos\",\"importPaths\":[\"$EXT\"],\"exclusionPatterns\":[\"**/@eaDir/**\"]}" 2>/dev/null || true)
    LIBID=$(printf '%s' "$created" | ${grep} -o '"id":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)
    [ -z "$LIBID" ] && { echo "immich external library creation failed: $created" >&2; exit 1; }
    echo "immich external library created: id=$LIBID path=$EXT"

    # Kick an initial scan (best-effort; cloudunit-immich-scan.timer retries anyway).
    ${curl} -s -o /dev/null -X POST "$I/api/libraries/$LIBID/scan" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null || true
    echo "immich external library initial scan queued"
  '';

  # Periodic scan trigger: newly dropped files get imported within the timer
  # interval. Uses ONLY the stable /scan endpoint (no experimental filesystem
  # watcher, no version-fragile system-config). Immich's own once-a-day scheduled
  # scan remains a fallback. Best-effort: on a box whose admin isn't keephaven@local
  # (e.g. a migrated box), login fails and it exits 0 quietly.
  immichScan = pkgs.writeShellScript "cloudunit-immich-scan" ''
    set -uo pipefail
    I="http://localhost:2283"
    EMAIL="keephaven@local"; PASSWORD="keephaven"
    EXT="${immichExternalPath}"
    if [ -f ${unitEnv} ]; then . ${unitEnv}; PASSWORD="$UNIT_PASSWORD"; fi

    resp=$(${curl} -s -X POST "$I/api/auth/login" -H "Content-Type: application/json" \
      -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" 2>/dev/null || true)
    TOKEN=$(printf '%s' "$resp" | ${grep} -o '"accessToken":"[^"]*"' | cut -d'"' -f4 || true)
    [ -z "$TOKEN" ] && { echo "immich-scan: login failed (skipping)"; exit 0; }

    libs=$(${curl} -s -H "Authorization: Bearer $TOKEN" "$I/api/libraries" 2>/dev/null || true)
    LIBID=$(printf '%s' "$libs" \
      | ${pkgs.jq}/bin/jq -r --arg p "$EXT" '.[] | select(.importPaths[]? == $p) | .id' 2>/dev/null \
      | head -n1 || true)
    [ -z "$LIBID" ] && { echo "immich-scan: Photos library not found yet (skipping)"; exit 0; }

    ${curl} -s -o /dev/null -X POST "$I/api/libraries/$LIBID/scan" \
      -H "Authorization: Bearer $TOKEN" 2>/dev/null || true
    echo "immich-scan: queued scan for library $LIBID"
  '';
in
{
  # Edition switch (modules/editions.nix): the five media provisioners run only
  # when the edition includes them. Immich's provisioner and its external-library
  # scan are always present. For entertainment all are active, so this is identical.
  systemd.services =
    lib.optionalAttrs (builtins.elem "jellyfin" config.keephaven.activeApps)
      (mkProvision { name = "jellyfin"; after = [ "cloudunit-jellyfin.service" ]; script = jellyfinProvision; })
    // lib.optionalAttrs (builtins.elem "navidrome" config.keephaven.activeApps)
      (mkProvision { name = "navidrome"; after = [ "cloudunit-navidrome.service" ]; script = navidromeProvision; })
    // lib.optionalAttrs (builtins.elem "freshrss" config.keephaven.activeApps)
      (mkProvision { name = "freshrss"; after = [ "cloudunit-freshrss.service" ]; script = freshrssProvision; })
    // lib.optionalAttrs (builtins.elem "kavita" config.keephaven.activeApps)
      (mkProvision { name = "kavita"; after = [ "cloudunit-kavita.service" ]; script = kavitaProvision; })
    // lib.optionalAttrs (builtins.elem "audiobookshelf" config.keephaven.activeApps)
      (mkProvision { name = "audiobookshelf"; after = [ "cloudunit-audiobookshelf.service" ]; script = audiobookshelfProvision; })
    // (mkProvision { name = "immich"; after = [ "cloudunit-immich.service" ]; script = immichProvision; })
    // {
      cloudunit-immich-scan = {
        description = "Cloud Unit - Immich external-library scan trigger";
        after = [ "cloudunit-immich.service" ];
        unitConfig = {
          ConditionPathExists = setupFlag;
          RequiresMountsFor = dataDir;
        };
        # Periodic oneshot: NO RemainAfterExit, so the timer can re-run it each fire.
        serviceConfig = {
          Type = "oneshot";
          ExecStart = immichScan;
        };
      };
    };

  systemd.timers.cloudunit-immich-scan = {
    description = "Cloud Unit - periodic Immich external-library scan";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "10min";
      Unit = "cloudunit-immich-scan.service";
    };
  };

  # Near-instant import: watch the Samba "Photos" drop-in dir and fire the SAME
  # scan the moment a file lands, so a fresh box imports the customer's very
  # first drop in seconds instead of waiting up to a full timer interval. Without
  # this, a pristine box (Immich ships watch DISABLED, and we deliberately do not
  # enable the experimental watcher -- see the immichScan comment above) has no
  # instant path at all: every drop waits for the 5min/10min timer. This uses
  # ONLY the stable /scan endpoint (via cloudunit-immich-scan.service, which
  # self-gates on .setup-complete) -- no Immich watcher, no version-fragile
  # system-config. The timer stays as the fallback and also covers drops into
  # nested subdirs, which a single-directory path watch does not see.
  systemd.paths.cloudunit-immich-watch = {
    description = "Cloud Unit - trigger Immich scan when a file lands in the Photos drop-in";
    wantedBy = [ "multi-user.target" ];
    pathConfig = {
      PathChanged = "${dataDir}/immich/external";
      Unit = "cloudunit-immich-scan.service";
    };
  };
}
