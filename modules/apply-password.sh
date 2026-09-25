#!/bin/sh
# cloudunit-apply-password NEW_PASSWORD
# Changes the account password across all 6 services + Samba.
# Idempotent / re-runnable: per service, if NEW already works -> skip; else
# authenticate with OLD and change. Per-service auto-retry (3x). Reports
# per-service result. unit.env is NEVER modified (sticker/factory record);
# the live password is tracked in current.env. AP password applied by caller.
set -u

DATADIR="/var/lib/cloudunit"
UNIT_ENV="$DATADIR/unit.env"
CURRENT_ENV="$DATADIR/current.env"
EMAIL="keephaven@local"
USERNAME="keephaven"

CURL="curl"
DOCKER="docker"
SMBPASSWD="smbpasswd"

NEW="${1-}"

if [ -z "$NEW" ]; then echo "ERROR: no password given" >&2; exit 2; fi
len=${#NEW}
if [ "$len" -lt 8 ] || [ "$len" -gt 63 ]; then echo "ERROR: password must be 8-63 characters" >&2; exit 2; fi
case "$NEW" in *" "*) echo "ERROR: password may not contain spaces" >&2; exit 2 ;; esac
case "$NEW" in *[!a-zA-Z0-9_.@!#%^*+=-]*) echo "ERROR: password contains disallowed characters" >&2; exit 2 ;; esac

OLD=""
if [ -f "$CURRENT_ENV" ]; then OLD=$(grep '^CURRENT_PASSWORD=' "$CURRENT_ENV" 2>/dev/null | cut -d= -f2-); fi
if [ -z "$OLD" ] && [ -f "$UNIT_ENV" ]; then OLD=$(grep '^UNIT_PASSWORD=' "$UNIT_ENV" 2>/dev/null | cut -d= -f2-); fi
if [ -z "$OLD" ]; then echo "ERROR: cannot determine current password" >&2; exit 3; fi

FAILED=""

immich_login_ok() { code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:2283/api/auth/login" -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"password\":\"$1\"}" 2>/dev/null); [ "$code" = "200" ] || [ "$code" = "201" ]; }
immich_set() { tok=$($CURL -s -X POST "http://localhost:2283/api/auth/login" -H "Content-Type: application/json" -d "{\"email\":\"$EMAIL\",\"password\":\"$1\"}" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4); [ -z "$tok" ] && return 1; code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:2283/api/auth/change-password" -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "{\"password\":\"$1\",\"newPassword\":\"$2\"}" 2>/dev/null); [ "$code" = "200" ] || [ "$code" = "201" ]; }

jelly_login_ok() { code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:8096/Users/AuthenticateByName" -H "Content-Type: application/json" -H 'Authorization: MediaBrowser Client="kh", Device="kh", DeviceId="kh", Version="1"' -d "{\"Username\":\"$USERNAME\",\"Pw\":\"$1\"}" 2>/dev/null); [ "$code" = "200" ]; }
jelly_set() { resp=$($CURL -s -X POST "http://localhost:8096/Users/AuthenticateByName" -H "Content-Type: application/json" -H 'Authorization: MediaBrowser Client="kh", Device="kh", DeviceId="kh", Version="1"' -d "{\"Username\":\"$USERNAME\",\"Pw\":\"$1\"}"); tok=$(printf '%s' "$resp" | grep -o '"AccessToken":"[^"]*"' | cut -d'"' -f4); uid=$(printf '%s' "$resp" | grep -o '"Id":"[^"]*"' | head -1 | cut -d'"' -f4); { [ -z "$tok" ] || [ -z "$uid" ]; } && return 1; code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:8096/Users/$uid/Password" -H "Authorization: MediaBrowser Token=\"$tok\"" -H "Content-Type: application/json" -d "{\"CurrentPw\":\"$1\",\"NewPw\":\"$2\"}" 2>/dev/null); [ "$code" = "204" ] || [ "$code" = "200" ]; }

navi_login_ok() { code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:4533/auth/login" -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$1\"}" 2>/dev/null); [ "$code" = "200" ]; }
navi_set() { resp=$($CURL -s -X POST "http://localhost:4533/auth/login" -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$1\"}"); tok=$(printf '%s' "$resp" | grep -o '"token":"[^"]*"' | cut -d'"' -f4); nid=$(printf '%s' "$resp" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4); { [ -z "$tok" ] || [ -z "$nid" ]; } && return 1; code=$($CURL -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:4533/api/user/$nid" -H "x-nd-authorization: Bearer $tok" -H "Content-Type: application/json" -d "{\"id\":\"$nid\",\"userName\":\"$USERNAME\",\"name\":\"Keephaven\",\"email\":\"\",\"isAdmin\":true,\"currentPassword\":\"$1\",\"password\":\"$2\"}" 2>/dev/null); [ "$code" = "200" ]; }

kavita_login_ok() { code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:5001/api/account/login" -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$1\"}" 2>/dev/null); [ "$code" = "200" ]; }
kavita_set() { tok=$($CURL -s -X POST "http://localhost:5001/api/account/login" -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$1\"}" | grep -o '"token":"[^"]*"' | cut -d'"' -f4); [ -z "$tok" ] && return 1; code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:5001/api/account/reset-password" -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "{\"userName\":\"$USERNAME\",\"password\":\"$2\",\"oldPassword\":\"$1\"}" 2>/dev/null); [ "$code" = "200" ]; }

abs_login_ok() { code=$($CURL -s -o /dev/null -w "%{http_code}" -X POST "http://localhost:13378/login" -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$1\"}" 2>/dev/null); [ "$code" = "200" ]; }
abs_set() { tok=$($CURL -s -X POST "http://localhost:13378/login" -H "Content-Type: application/json" -d "{\"username\":\"$USERNAME\",\"password\":\"$1\"}" | grep -o '"accessToken":"[^"]*"' | cut -d'"' -f4); [ -z "$tok" ] && return 1; code=$($CURL -s -o /dev/null -w "%{http_code}" -X PATCH "http://localhost:13378/api/me/password" -H "Authorization: Bearer $tok" -H "Content-Type: application/json" -d "{\"password\":\"$1\",\"newPassword\":\"$2\"}" 2>/dev/null); [ "$code" = "200" ]; }

freshrss_set() { $DOCKER exec freshrss php /var/www/FreshRSS/cli/update-user.php --user "$USERNAME" --password "$2" >/dev/null 2>&1 || return 1; $DOCKER exec freshrss bash /var/www/FreshRSS/cli/access-permissions.sh >/dev/null 2>&1 || true; return 0; }

change_service() { name="$1"; login_ok="$2"; setfn="$3"; if "$login_ok" "$NEW"; then echo "  $name: already updated"; return 0; fi; i=1; while [ "$i" -le 3 ]; do if "$setfn" "$OLD" "$NEW"; then echo "  $name: updated"; return 0; fi; i=$((i+1)); sleep 3; done; echo "  $name: FAILED"; FAILED="$FAILED $name"; return 1; }

echo "Applying new password across services..."
change_service "Immich" immich_login_ok immich_set
change_service "Jellyfin" jelly_login_ok jelly_set
change_service "Navidrome" navi_login_ok navi_set
change_service "Kavita" kavita_login_ok kavita_set
change_service "Audiobookshelf" abs_login_ok abs_set
if freshrss_set "$OLD" "$NEW"; then echo "  FreshRSS: updated"; else echo "  FreshRSS: FAILED"; FAILED="$FAILED FreshRSS"; fi

if printf '%s\n%s\n' "$NEW" "$NEW" | $SMBPASSWD -s "$USERNAME" >/dev/null 2>&1; then echo "  Samba: updated"; else echo "  Samba: FAILED"; FAILED="$FAILED Samba"; fi

if [ -n "$FAILED" ]; then
  echo "RESULT: some services failed:$FAILED" >&2
  echo "(current password unchanged in records; re-run to fix the above)" >&2
  exit 10
fi

umask 077
printf 'CURRENT_PASSWORD=%s\n' "$NEW" > "$CURRENT_ENV"
chmod 600 "$CURRENT_ENV"
echo "RESULT: all services updated"
exit 0
