# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  setupFlag = "${dataDir}/.setup-complete";
  webUser = "cloudunit-web";

  # Privileged wrappers contributed by domain modules (tailscale.nix,
  # support-access.nix). Settings owns the UI + the sudo grants; the wrappers
  # live with their domain. Values are absolute /nix/store bin paths.
  wrappers = config.cloudunit.wrappers;

  applyApConfig = pkgs.writeShellScriptBin "cloudunit-apply-ap-config" ''
    set -euo pipefail
    AP_ENV="${dataDir}/ap.env"
    ssid="''${1-}"
    password="''${2-}"

    # Read current values (root can read ap.env) to preserve whichever field
    # is left blank ("leave blank to keep current").
    cur_ssid=""
    cur_pw=""
    if [ -f "$AP_ENV" ]; then
      cur_ssid="$(${pkgs.gnugrep}/bin/grep '^AP_SSID=' "$AP_ENV" | ${pkgs.coreutils}/bin/cut -d= -f2-)"
      cur_pw="$(${pkgs.gnugrep}/bin/grep '^AP_PASSWORD=' "$AP_ENV" | ${pkgs.coreutils}/bin/cut -d= -f2-)"
    fi

    if [ -z "$ssid" ] && [ -z "$password" ]; then
      echo "ERROR: nothing to change" >&2; exit 2
    fi

    # Fill blanks from current.
    [ -z "$ssid" ] && ssid="$cur_ssid"
    [ -z "$password" ] && password="$cur_pw"

    if [ -z "$ssid" ] || [ "''${#ssid}" -gt 32 ]; then
      echo "ERROR: SSID must be 1-32 characters" >&2; exit 2
    fi
    case "$ssid" in
      *[!a-zA-Z0-9\ _-]*)
        echo "ERROR: SSID may contain only letters, numbers, space, underscore, hyphen" >&2; exit 2 ;;
    esac

    if [ "''${#password}" -lt 8 ] || [ "''${#password}" -gt 63 ]; then
      echo "ERROR: password must be 8-63 characters" >&2; exit 2
    fi
    case "$password" in
      *[!a-zA-Z0-9\ _.@!#%^*+=-]*)
        echo "ERROR: password contains disallowed characters" >&2; exit 2 ;;
    esac

    umask 077
    tmp="$(${pkgs.coreutils}/bin/mktemp ${dataDir}/.ap.env.XXXXXX)"
    {
      ${pkgs.coreutils}/bin/printf 'AP_SSID=%s\n' "$ssid"
      ${pkgs.coreutils}/bin/printf 'AP_PASSWORD=%s\n' "$password"
    } > "$tmp"
    ${pkgs.coreutils}/bin/mv -f "$tmp" "$AP_ENV"
    ${pkgs.coreutils}/bin/chmod 600 "$AP_ENV"
    ${pkgs.systemd}/bin/systemctl restart cloudunit-hostapd
    echo "OK: AP config applied"
  '';

  applyPassword = pkgs.writeShellScriptBin "cloudunit-apply-password"
    (builtins.readFile ./apply-password.sh);

  factoryReset = pkgs.writeShellScriptBin "cloudunit-factory-reset"
    (builtins.readFile ./factory-reset.sh);

  readSticker = pkgs.writeShellScriptBin "cloudunit-read-sticker" ''
    ${pkgs.gnugrep}/bin/grep '^UNIT_PASSWORD=' ${dataDir}/unit.env | ${pkgs.coreutils}/bin/cut -d= -f2-
  '';

  # Read-only support diagnostics. Emits ONLY a compact technical summary: image
  # version, update state, uptime, data-partition space, per-container run state,
  # and error/failed-unit COUNTS. NEVER touches unit.env/ap.env, file names, media,
  # or any user data — see the privacy page. Runs as root (docker/journalctl need
  # it) via the same NOPASSWD-wrapper pattern as readSticker; the customer sees the
  # full output on screen and chooses whether to send it (a pre-filled mailto).
  healthReport = pkgs.writeShellScriptBin "cloudunit-health-report" ''
    set -u
    co=${pkgs.coreutils}/bin
    echo "KEEPHAVEN HEALTH REPORT"
    echo "generated: $($co/date -u '+%Y-%m-%d %H:%M UTC')"
    echo "version:   $($co/cat /etc/cloudunit/update/version 2>/dev/null || echo unknown)"
    st=$(${pkgs.gnugrep}/bin/grep -o '"state"[^,}]*' ${dataDir}/update/status.json 2>/dev/null | $co/head -1 | ${pkgs.gnugrep}/bin/grep -o '[^":]*$')
    echo "update:    ''${st:-none}"
    echo "uptime:    $(${pkgs.procps}/bin/uptime -p 2>/dev/null || echo unknown)"
    # -P forces one line per filesystem (df wraps long device names onto two
    # lines otherwise, which shifted the awk fields to empty). NR==2 = the data row.
    echo "data disk: $($co/df -hP ${dataDir} 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2{print $3" used, "$4" free ("$5")"}')"
    echo "failed units: $(${pkgs.systemd}/bin/systemctl --failed --no-legend 2>/dev/null | $co/wc -l)"
    # APP PICKER: apps the owner switched off show as "Exited" in the list below
    # (or are absent); name them here so support does not read them as broken.
    off=""
    for a in ${lib.concatStringsSep " " config.keephaven.pickableApps}; do
      if [ -e ${config.keephaven.appsDir}/$a.off ]; then off="$off $a"; fi
    done
    echo "apps off (owner's choice):''${off:- none}"
    # Memory, box-wide and per container. Feeds the app picker's "will it fit"
    # numbers (P3, measured on the test unit) and tells support whether a box is
    # short of memory. Sizes only -- no personal data.
    echo "memory:    $(${pkgs.procps}/bin/free -m 2>/dev/null | ${pkgs.gawk}/bin/awk 'NR==2{print $3" MB used of "$2" MB ("$7" MB available)"}')"
    echo "app memory:"
    ${pkgs.docker}/bin/docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}}' 2>/dev/null | $co/sort || echo "  (docker unavailable)"
    echo "errors this boot: $(${pkgs.systemd}/bin/journalctl -p err -b --no-pager -q 2>/dev/null | $co/wc -l)"
    echo "services:"
    # {{.Status}} (not {{.State}}) so HEALTH shows: "Up 3h (unhealthy)" — a service
    # that is running-but-unhealthy (e.g. not provisioned) must not read as fine.
    ${pkgs.docker}/bin/docker ps -a --format '  {{.Names}}: {{.Status}}' 2>/dev/null | $co/sort || echo "  (docker unavailable)"
  '';

  # Root reader for the CURRENT password (ap.env is root:root 600, ap.nix:84 --
  # the web user cannot read it directly; same pattern as readSticker above).
  readApPassword = pkgs.writeShellScriptBin "cloudunit-read-ap-password" ''
    ${pkgs.gnugrep}/bin/grep '^AP_PASSWORD=' ${dataDir}/ap.env | ${pkgs.coreutils}/bin/cut -d= -f2-
  '';

  restartBox = pkgs.writeShellScriptBin "cloudunit-restart" ''
    echo "OK: restarting"
    ${pkgs.systemd}/bin/systemctl reboot
  '';

  softReset = pkgs.writeShellScriptBin "cloudunit-soft-reset" ''
    set -euo pipefail
    ${pkgs.coreutils}/bin/rm -f ${setupFlag}
    echo "OK: soft reset armed; rebooting"
    ${pkgs.systemd}/bin/systemctl reboot
  '';

  settingsApp = pkgs.writeText "cloudunit-settings.py" ''
    import http.server, socketserver, subprocess, urllib.parse, urllib.request, urllib.error, html, threading, time, json, hmac, socket, secrets, os

    PORT = 8888
    SETUP_FLAG = "${dataDir}/.setup-complete"
    # PRE-SETUP ALLOWLIST. Settings is reachable before the wizard has ever run
    # (the service is not gated on .setup-complete, unlike wizard/dashboard), so
    # a never-set-up box exposed its whole settings surface to anyone on the AP
    # or LAN. Closed here by allowlist rather than by gating the service, because
    # two flows legitimately need it BEFORE setup completes:
    #   /pair/accept  - bench pre-pairing, how a boxed pair ships pre-paired
    #   /remote-access - a backup box must join the tailnet during setup so its
    #                    primary can reach it
    # Everything else is refused until setup is finished. Both allowed routes
    # carry the danger-zone password check, so this is an allowlist of ROUTES,
    # not of unauthenticated access.
    # /done is allowlisted too: it is the RESULT page every POST redirects to, so
    # blocking it made an allowlisted route's own refusal message unreachable --
    # a pre-setup owner got "Finish setting up first" instead of "that password
    # isn't right", which explains nothing. It is read-only and keyed by an
    # unguessable in-memory token, so it exposes nothing. (Found during the
    # Phase 3 gate, 2026-08-10.)
    PRE_SETUP_ALLOWED = ("/pair/accept", "/remote-access", "/remote-access/status", "/done")

    def setup_done():
        try:
            return os.path.exists(SETUP_FLAG)
        except Exception:
            # Fail CLOSED: if we cannot tell, behave as though setup is done so a
            # box already in service is never locked out of its own settings.
            return True

    def pre_setup_blocked(path):
        return (not setup_done()) and (path.split("?", 1)[0] not in PRE_SETUP_ALLOWED)

    NOT_YET_PAGE = ("<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
                    "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                    "<title>Keephaven</title></head><body style=\"font-family:system-ui,sans-serif;"
                    "max-width:600px;margin:40px auto;padding:0 20px;line-height:1.5\">"
                    "<h1>Finish setting up first</h1><p>Settings become available once you have "
                    "completed the short setup on your Keephaven. Open the address printed on the "
                    "sticker on the bottom of the box.</p></body></html>")
    # Customer-exposure gate for the whole replication arc (replication.nix).
    # False on customer images until the Phase 4 restore path is gated: the
    # pairing card is not rendered at all, so a mid-arc box shows no backup UI.
    REPLICATION_UI = ${if config.keephaven.replication.enable then "True" else "False"}
    AP_ENV = "${dataDir}/ap.env"

    def current_ssid():
        try:
            with open(AP_ENV) as f:
                for line in f:
                    if line.startswith("AP_SSID="):
                        return line.split("=", 1)[1].strip()
        except Exception:
            pass
        return ""

    def current_ap_password():
        try:
            with open(AP_ENV) as f:
                for line in f:
                    if line.startswith("AP_PASSWORD="):
                        return line.split("=", 1)[1].strip()
        except Exception:
            pass
        return ""

    def auth_check(data):
        # Danger-zone gate: destructive/credential POSTs must carry the CURRENT
        # password (ap.env) OR the sticker password (unit.env) -- the sticker is
        # the permanent fallback. :8888 is open to the whole LAN/AP, so without
        # this any device on the network could wipe the box.
        # Both env files are root:root 600 (credentials.nix:43, ap.nix:84) and
        # this service runs as cloudunit-web -- they MUST be read via the sudo
        # wrappers (same pattern as /reset-password's readSticker), never
        # directly. Returns "ok", "wrong", or "error" (no source readable, so
        # the password could not be checked at all -- fail closed but say so).
        given = data.get("auth", [""])[0].strip()
        sources = []
        for wrapper in ("${readApPassword}/bin/cloudunit-read-ap-password",
                        "${readSticker}/bin/cloudunit-read-sticker"):
            r = run(["sudo", "-n", wrapper], timeout=10)
            if r is not None and r.returncode == 0 and (r.stdout or "").strip():
                sources.append(r.stdout.strip())
        if not sources:
            return "error"
        if not given:
            return "wrong"
        for pw in sources:
            if hmac.compare_digest(given, pw):
                return "ok"
        return "wrong"

    def auth_check_sticker(data):
        # /reset-password gate: the reset TARGET is the sticker password, so require
        # the sticker specifically (not the AP-or-sticker auth_check above). This
        # proves physical access to the box -- a network attacker on :8888 without it
        # is blocked -- while creating NO lockout loop: the sticker is permanent and
        # always works, even if the owner forgot a password they changed. unit.env is
        # root:root 600, so it MUST be read via the sudo wrapper (as readSticker does).
        given = data.get("auth", [""])[0].strip()
        r = run(["sudo", "-n", "${readSticker}/bin/cloudunit-read-sticker"], timeout=10)
        if r is None or r.returncode != 0 or not (r.stdout or "").strip():
            return "error"
        if not given:
            return "wrong"
        return "ok" if hmac.compare_digest(given, r.stdout.strip()) else "wrong"

    AUTH_WRONG = ("That password isn't right -- use your current password, or the "
                  "one printed on the sticker on the bottom of your Keephaven.")
    AUTH_ERROR = ("We couldn't verify your password -- internal error. Restart "
                  "your Keephaven and try again.")

    def auth_deny_msg(verdict, prefix):
        return prefix + " " + (AUTH_WRONG if verdict == "wrong" else AUTH_ERROR)

    def current_ssid_safe():
        return ""

    def kh_host():
        # Per-unit mDNS name (keephaven-<suffix>.local), from the same UNIT_SUFFIX
        # that backs the SSID. unit.env survives factory reset, so this always
        # matches the printed sticker. Falls back to the generic name if unread.
        try:
            with open("${dataDir}/unit.env") as f:
                for line in f:
                    if line.startswith("UNIT_SUFFIX="):
                        s = line.split("=", 1)[1].strip()
                        if s:
                            return "keephaven-" + s + ".local"
        except Exception:
            pass
        return "keephaven.local"

    def _fmt_exp(s):
        if len(s) == 14 and s.isdigit():
            return "%s-%s-%s %s:%s" % (s[0:4], s[4:6], s[6:8], s[8:10], s[10:12])
        return s

    def support_status_line():
        try:
            r = subprocess.run(["sudo", "-n", "${wrappers.supportStatus}"],
                               capture_output=True, text=True)
            out = r.stdout.strip()
            if out.startswith("active"):
                parts = out.split()
                exp = _fmt_exp(parts[1]) if len(parts) > 1 else ""
                return ("Support access is currently ON" +
                        ((" until " + exp) if exp else "") + ".")
        except Exception:
            pass
        return "Support access is off."

    # Client poller embedded in the Remote access card. It advances the card
    # off -> starting -> url -> connected on its own by polling the read-only
    # /remote-access/status endpoint every 3s, so a click during a busy first-boot
    # moment resolves a few seconds later instead of dead-ending. On the off-state
    # button it intercepts the submit (fetch POST, then spinner+poll) so the page
    # never navigates away; with JS disabled the plain form POST still works via
    # the server 303. Once polling starts it never reverts to the button (any
    # non-url/non-connected reading is treated as "still starting"); it stops only
    # on "connected". JS uses double quotes throughout so the script contains
    # neither sequence the enclosing Nix indented string treats specially.
    ra_script = """<script>
    (function(){
      var card=document.getElementById("ra-card");
      if(!card) return;
      var body=document.getElementById("ra-body");
      var timer=null;
      // What is on screen now. The poll runs every 3s; re-drawing an unchanged state
      // would wipe a password being typed into the cancel form.
      var shown="";
      // Cancel while a sign-in is pending: the same OFF route as the connected card.
      function cancelForm(){
        var f=document.createElement("form"); f.method="POST"; f.action="/remote-access/off";
        var l=document.createElement("label"); l.textContent="Changed your mind? Enter your password to cancel."; f.appendChild(l);
        var w=document.createElement("div"); w.className="pwrow";
        var i=document.createElement("input"); i.name="auth"; i.type="password"; i.autocomplete="off"; w.appendChild(i); f.appendChild(w);
        var b=document.createElement("button"); b.type="submit"; b.className="neutral"; b.textContent="Cancel and turn off"; f.appendChild(b);
        return f;
      }
      function clear(){ while(body.firstChild) body.removeChild(body.firstChild); }
      function para(t){ var p=document.createElement("p"); p.className="sub"; p.textContent=t; return p; }
      function showConnected(){ shown="connected"; clear(); body.appendChild(para("Remote access is on and connected. You can reach your Keephaven from outside your home using your account.")); }
      function showStarting(){ if(shown==="starting") return; shown="starting"; clear(); body.appendChild(para("Turning on… the sign-in link will appear here in a moment.")); var s=document.createElement("div"); s.className="ra-spin"; body.appendChild(s); body.appendChild(cancelForm()); }
      function showUrl(u){ if(shown==="url "+u) return; shown="url "+u; clear(); body.appendChild(para("Remote access is turning on. Open this link and sign in with your account to finish — you can leave this page:")); var d=document.createElement("div"); d.className="pw"; var a=document.createElement("a"); a.href=u; a.textContent=u; d.appendChild(a); body.appendChild(d); body.appendChild(cancelForm()); }
      function showError(){
        shown="error";
        clear();
        body.appendChild(para("Remote access could not be turned on. Restart your Keephaven and try again; if it keeps failing, contact support@keephaven.co."));
        var f=document.createElement("form"); f.method="POST"; f.action="/remote-access";
        var b=document.createElement("button"); b.type="submit"; b.textContent="Try again";
        f.appendChild(b); body.appendChild(f);
      }
      function apply(out){
        // Reload once connected: the OFF form is rendered by the server only.
        if(out==="connected"){ showConnected(); window.location.hash="ra-card"; window.location.reload(); return false; }
        if(out.indexOf("url ")===0){ showUrl(out.slice(4).trim()); return true; }
        // A dead login unit must STOP the spinner and say something actionable.
        if(out==="error"){ showError(); return false; }
        showStarting(); return true;
      }
      function poll(){
        fetch("/remote-access/status",{cache:"no-store"}).then(function(r){return r.text();}).then(function(t){
          if(apply(t.trim())) timer=setTimeout(poll,3000);
        }).catch(function(){ timer=setTimeout(poll,3000); });
      }
      function begin(){ if(!timer){ showStarting(); poll(); } }
      var f=document.getElementById("ra-form");
      // Send the form body: the route now requires the danger-zone password, and
      // this fetch used to post nothing at all.
      if(f) f.addEventListener("submit",function(e){
        e.preventDefault();
        var fd = new FormData(f);
        fetch("/remote-access",{method:"POST",body:new URLSearchParams(fd)})
          .then(function(r){ if(r.status===200||r.redirected){ } })
          .catch(function(){});
        begin();
      });
      var st=card.getAttribute("data-ra");
      if(st==="starting"||st==="url") poll();
    })();
    </script>"""

    def remote_access_card():
        # Read state once for the initial (server-side) render; ra_script then
        # auto-polls so the card advances on its own. This function NEVER triggers
        # enable (POST /remote-access does). No-JS fallback: the off-state form
        # posts to /remote-access (303 -> here) and "starting" keeps a spinner; a
        # re-click is idempotent.
        out = ""
        try:
            r = subprocess.run(["sudo", "-n", "${wrappers.remoteAccessStatus}"],
                               capture_output=True, text=True, timeout=10)
            out = (r.stdout or "").strip()
        except Exception:
            pass
        # One password row for both forms on this card (ON and OFF).
        ra_pw_row = ("<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">"
                     "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>")
        if out == "connected":
            state = "connected"
            # The OFF switch (2026-10-03). Server-rendered only: ra_script reloads
            # the page when a sign-in finishes, so there is one copy of this form.
            inner = ("<p class=\"sub\">Remote access is on and connected. You can reach your "
                     "Keephaven from outside your home using your account.</p>"
                     "<p class=\"sub\">Turning it off also stops backups between two "
                     "Keephavens and support access, until you turn it back on. Turning it "
                     "back on usually needs no new sign-in.</p>"
                     "<form method=\"POST\" action=\"/remote-access/off\">"
                     "<label>Your password (the one on the sticker always works)</label>"
                     + ra_pw_row +
                     "<button class=\"neutral\" type=\"submit\">Turn off remote access</button></form>")
        elif out.startswith("url "):
            state = "url"
            u = html.escape(out[4:].strip())
            inner = ("<p class=\"sub\">Remote access is turning on. Open this link and sign in "
                     "with your account to finish &mdash; you can leave this page:</p>"
                     "<div class=\"pw\"><a href=\"" + u + "\">" + u + "</a></div>"
                     "<form method=\"POST\" action=\"/remote-access/off\">"
                     "<label>Changed your mind? Enter your password to cancel.</label>"
                     + ra_pw_row +
                     "<button class=\"neutral\" type=\"submit\">Cancel and turn off</button></form>")
        elif out == "error":
            state = "error"
            inner = ("<p class=\"sub\">Remote access could not be turned on. Restart your "
                     "Keephaven and try again; if it keeps failing, contact "
                     "support@keephaven.co.</p>"
                     "<form method=\"POST\" action=\"/remote-access\">"
                     "<button type=\"submit\">Try again</button></form>")
        elif out == "starting":
            state = "starting"
            inner = ("<p class=\"sub\">Turning on&hellip; the sign-in link will appear here in a "
                     "moment.</p><div class=\"ra-spin\"></div>"
                     "<form method=\"POST\" action=\"/remote-access/off\">"
                     "<label>Changed your mind? Enter your password to cancel.</label>"
                     + ra_pw_row +
                     "<button class=\"neutral\" type=\"submit\">Cancel and turn off</button></form>")
        else:
            state = "off"
            inner = ("<p class=\"sub\">Reach your Keephaven from outside your home. Turn this on, "
                     "then sign in with your account on the link that appears. You can turn it "
                     "off again here any time.</p>"
                     "<p class=\"sub\">We ask for your password here because turning this on lets "
                     "you reach your Keephaven from outside your home &mdash; so it should only "
                     "ever be you who switches it on.</p>"
                     "<form id=\"ra-form\" method=\"POST\" action=\"/remote-access\">"
                     "<label>Your password (the one on the sticker always works)</label>"
                     + ra_pw_row +
                     "<button type=\"submit\">Turn on remote access</button></form>")
        return ("<div class=\"card\" id=\"ra-card\" data-ra=\"" + state + "\">"
                "<h2>Remote access</h2><div id=\"ra-body\">" + inner + "</div></div>"
                + ra_script)

    SUFFIX_CHARS = "bcdfghjkmnpqrstvwxyz23456789"  # credentials.nix generation charset

    def valid_suffix(s):
        return len(s) == 5 and all(c in SUFFIX_CHARS for c in s)

    def my_suffix():
        # This box's own suffix, from the LIVE hostname (cloudunit-set-hostname
        # sets keephaven-<suffix> from UNIT_SUFFIX at boot, base.nix). NOT from
        # unit.env: that file is root:600 and this service runs as cloudunit-web
        # -- a direct read fails EACCES silently (the .21 danger-zone auth bug
        # class; re-bitten by the first Phase 1 gate attempt on w2x93, where
        # kh_host()'s silent "keephaven.local" fallback broke /pair/start).
        # gethostname() needs no privilege and carries the same token.
        try:
            h = socket.gethostname()
        except Exception:
            return ""
        if h.startswith("keephaven-"):
            s = h[len("keephaven-"):]
            if valid_suffix(s):
                return s
        return ""

    def tailnet_peer_lookup(peer_suffix):
        # Find the peer on the owner's tailnet: exact hostname first, then the
        # rename-churn variants (keephaven-<suffix>-1 etc., decisions.md
        # 2026-07-26). Prefers an online entry. Returns (ip, nodeid) or ("", "").
        name = "keephaven-" + peer_suffix
        best = ("", "")
        try:
            r = run(["sudo", "-n", "${wrappers.tailnetPeers}"], timeout=10)
            for line in (r.stdout or "").splitlines():
                f = line.split("\t")
                if len(f) < 4 or not f[2]:
                    continue
                if f[0] == name or f[0].startswith(name + "-"):
                    if f[3] == "true":
                        return (f[1], f[2])
                    if not best[1]:
                        best = (f[1], f[2])
        except Exception:
            pass
        return best

    def pair_resolve_if_pending(peer_suffix):
        # A pending pair (LAN/bench ceremony, no tailnet yet) self-completes the
        # first time the peer is visible on the tailnet. Idempotent, cheap.
        ip, nodeid = tailnet_peer_lookup(peer_suffix)
        if nodeid:
            r = run(["sudo", "-n", "${wrappers.pairRecord}", peer_suffix, nodeid], timeout=10)
            return r is not None and r.returncode == 0
        return False

    # Messages for the POST-redirect-GET flow below. Pairing POSTs MUST NOT render
    # a page directly: the browser then re-submits the whole POST (password field
    # included) on refresh or tab-restore, which can silently re-run a destructive
    # action. The Phase 1 gate recorded an unpair nobody clicked. /remote-access
    # already used 303 for exactly this reason; pairing now matches.
    PAIR_MSGS = {
        "paired": "Paired with {peer}. The two boxes now trust each other.",
        "paired-pending": "Paired with {peer}. The boxes will connect once Remote access is on for both.",
        "unpaired": "Unpaired. The trusted connection on this box has been removed. If the other box is still paired, unpair it there too.",
        "badname": "That doesn't look like a Keephaven name. Enter the name printed on the other box's sticker, like keephaven-xw3km.",
        "self": "That's this Keephaven's own name. Enter the OTHER box's name.",
        "nopw": "Enter the other Keephaven's password (printed on its sticker).",
        "authfail": "Pairing was NOT started. " + AUTH_WRONG,
        "autherr": "Pairing was NOT started. " + AUTH_ERROR,
        "unpair-authfail": "The boxes were NOT unpaired. " + AUTH_WRONG,
        "unpair-autherr": "The boxes were NOT unpaired. " + AUTH_ERROR,
        "noidentity": "Pairing isn't available: this Keephaven's identity could not be read. Restart the box and try again.",
        "nokey": "Pairing failed: this box couldn't prepare its pairing key. Restart the box and try again.",
        "peerpw": "Pairing was NOT completed. The other Keephaven rejected the password - check the password printed on ITS sticker and try again.",
        "unreachable": "Pairing was NOT completed. Couldn't reach {peer}. Check that it's powered on and on the same network (or that Remote access is on for both boxes), then try again.",
        "storage": "Pairing was NOT completed. The other Keephaven could not prepare its backup storage area, so it did not accept the pairing. Restart that box and try again; if it keeps failing, contact support@keephaven.co.",
        "reversal": ("Pairing was NOT completed. {peer} has been used as a MAIN Keephaven. "
                     "Pairing this way would make it the BACKUP for this box, and it would stop "
                     "being a main Keephaven. If that's really what you want, tick "
                     "“Make it the backup anyway” and pair again."),
        "peerfail": "Pairing was NOT completed. The other Keephaven reported a problem. Restart both boxes and try again.",
        "recfail": "The other Keephaven accepted, but this box couldn't record the pairing. Try pairing again.",
    }

    def pair_msg(code, peer=""):
        t = PAIR_MSGS.get(code, "")
        if not t:
            return ""
        return t.replace("{peer}", "keephaven-" + peer if peer else "the other Keephaven")

    def sync_status():
        # Direct read is correct here: sync-status.json is 0644 in a 0755 dir.
        # (pair.env is root:600 -- that one goes through a sudo wrapper.)
        try:
            with open("${dataDir}/replication/sync-status.json") as f:
                return json.load(f)
        except Exception:
            return {}

    def days_since(iso):
        if not iso:
            return None
        try:
            t = time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ")
        except Exception:
            return None
        return int((time.time() - time.mktime(t) + time.timezone) // 86400)

    def backup_detail_html(role):
        # The Settings companion to the dashboard staleness card: the same truth
        # with more detail, on whichever box the owner happens to be looking at.
        if role == "backup-target":
            out = ""
            try:
                r = run(["sudo", "-n", "${wrappers.replicaTargetStatus}"], timeout=15)
                out = (r.stdout or "").strip()
            except Exception:
                pass
            if not out.startswith("target "):
                return ""
            f = {}
            for tok in out.split()[1:]:
                if "=" in tok:
                    k, v = tok.split("=", 1)
                    f[k] = v
            newest = f.get("newest", "none")
            when = "no backup received yet" if newest in ("none", "") else ("last received " + newest.replace("T", " ").replace("Z", " UTC"))
            return ("<p class=\"sub\">This box is holding the backup: <b>" + html.escape(f.get("dumps", "0"))
                    + "</b> database copies, " + html.escape(when) + "."
                    + " Space used <b>" + html.escape(f.get("used", "?")) + "</b>, free <b>"
                    + html.escape(f.get("free", "?")) + "</b> (" + html.escape(f.get("diskpct", "?")) + " of the disk in use).</p>")
        st = sync_status()
        if not st:
            return "<p class=\"sub\">No backup has run yet.</p>"
        d = days_since(st.get("last_success", ""))
        if d is None:
            line = "No backup has completed yet."
        elif d <= 0:
            line = "Last backup: today."
        elif d == 1:
            line = "Last backup: yesterday."
        else:
            line = "Last backup: " + str(d) + " days ago."
        state = st.get("state", "")
        if state and state != "ok":
            line += " Last attempt: " + str(st.get("message", state)) + "."
        return "<p class=\"sub\">" + html.escape(line) + "</p>"

    def promote_card():
        # The irreversible one. Shown only on a box that is actually a backup
        # target, and only ever ONE state at a time: in-progress, finished, or
        # the confirm form. Never a bare button - the confirm has to name the
        # source box and the backup's AGE, because "3 days ago" is what an owner
        # can actually judge. A date alone is not.
        st = {}
        try:
            with open("${dataDir}/replication/promote-status.json") as f:
                st = json.load(f)
        except Exception:
            st = {}
        state = st.get("state", "")
        if state in ("starting", "files-restored", "db-restored"):
            return ("<div class=\"card\"><h2>Restoring from your backup</h2>"
                    "<p class=\"sub\">" + html.escape(str(st.get("message", ""))) + "</p>"
                    "<p class=\"sub\">You can close this page &mdash; it keeps going.</p></div>")
        if state in ("done", "done-check-password"):
            return ("<div class=\"card\"><h2>Restored</h2>"
                    "<p class=\"sub\">" + html.escape(str(st.get("message", ""))) + "</p></div>")

        out = ""
        try:
            r = run(["sudo", "-n", "${wrappers.promotePreflight}"], timeout=20)
            out = (r.stdout or "").strip()
        except Exception:
            pass
        f = {}
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                f[k] = v
        if f.get("state") == "not-a-backup":
            return ""
        if f.get("state") == "no-backup-yet":
            return ("<div class=\"card\"><h2>Make this my main Keephaven</h2>"
                    "<p class=\"sub\">No backup has arrived on this box yet, so there is nothing "
                    "to restore. This option appears once a backup has been received.</p></div>")

        peer = html.escape("keephaven-" + f.get("peer", "?"))
        age = html.escape(f.get("age", "unknown"))
        taken = html.escape(f.get("taken", "unknown"))
        warn = ""
        if state and state.startswith(("refused", "files-failed", "db-failed")):
            warn = ("<p class=\"sub\"><b>Last attempt:</b> "
                    + html.escape(str(st.get("message", ""))) + "</p>")
        if f.get("version_ok") == "no":
            # Refuse up front rather than letting them type ERASE and then fail.
            return ("<div class=\"card\"><h2>Make this my main Keephaven</h2>" + warn +
                    "<p class=\"sub\">The backup on this box was made by a newer version of "
                    "Keephaven (" + html.escape(f.get("source_version", "?")) + ") than this box "
                    "is running (" + html.escape(f.get("my_version", "?")) + "). Update this "
                    "Keephaven first, then this option will work.</p></div>")
        return ("<div class=\"card\"><h2>Make this my main Keephaven</h2>" + warn +
                "<p class=\"sub\">This will replace everything on this Keephaven with the backup "
                "from <b>" + peer + "</b>, taken <b>" + age + "</b> (" + taken + "). Your apps "
                "start again and your photos, films, music and files come back.</p>"
                # The single most important sentence on this screen, so it does
                # NOT sit inside a paragraph. The irreversible mistake is not
                # restoring a bad backup - it is restoring while the other box is
                # merely unplugged. Given its own bordered, amber callout, led by
                # the check the owner should make, with the harmless alternative
                # named. [Dafarus, 2026-08-10]
                "<div style=\"background:#fff8ee;border:1px solid #f0d9b5;border-radius:10px;"
                "padding:14px;margin:14px 0\">"
                "<p style=\"margin:0 0 8px;font-weight:700\">Only do this if " + peer +
                " is gone for good.</p>"
                "<p style=\"margin:0\" class=\"sub\">If it is only switched off, unplugged, or "
                "off the internet, turn it back on instead &mdash; you do not need this. "
                "<b>Restoring cannot be undone.</b> Anything already on this box with the same "
                "name is replaced; anything else is left alone.</p></div>"
                "<form method=\"POST\" action=\"/promote\">"
                "<label>Type RESTORE to confirm</label>"
                "<input name=\"confirm\" autocomplete=\"off\" placeholder=\"RESTORE\">"
                "<label>Your password (the one on this box's sticker always works)</label>"
                "<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">"
                "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                "<button class=\"danger\" type=\"submit\">Restore and make this my main Keephaven</button>"
                "</form></div>")

    def photos_signin_card():
        # A PERMANENT home for the one thing a promoted owner will hit at exactly
        # the wrong moment: tapping Photos lands on Immich's own login screen,
        # which knows nothing about Keephaven and just says the password is
        # wrong. The explanation was on the page they left. And the box that
        # holds the right password is gone - that is what promoting means.
        # So this sits at the top level, not inside Backup, and it removes
        # ITSELF once this box's own password works. [Dafarus, 2026-08-14]
        out = ""
        try:
            r = run(["sudo", "-n", "${wrappers.photosSigninStatus}"], timeout=20)
            out = (r.stdout or "").strip()
        except Exception:
            pass
        if out != "other-box":
            return ""
        src = ""
        try:
            with open("${dataDir}/replication/.promoted") as f:
                for line in f:
                    if line.startswith("promoted_from="):
                        src = line.split("=", 1)[1].strip()
        except Exception:
            pass
        srch = html.escape("keephaven-" + src) if src else "your other Keephaven"
        return ("<div class=\"card\"><h2>Photos sign-in</h2>"
                "<p class=\"sub\">Your photo library was restored from <b>" + srch + "</b>, and "
                "it kept that box's sign-in. So when you open <b>Photos</b>, use the password "
                "printed on <b>" + srch + "'s</b> sticker &mdash; not this box's. Everything "
                "else (Movies, Music, Books, file sharing) uses this box's own password as "
                "usual.</p>"
                "<p class=\"sub\">You can fix that here, once. Enter the password you use for "
                "Photos now, and it will be changed to this box's own sticker password like "
                "everything else. This message then disappears on its own.</p>"
                "<form method=\"POST\" action=\"/photos-signin-fix\">"
                "<label>The password you currently use for Photos (from " + srch + "'s sticker)</label>"
                "<div class=\"pwrow\"><input name=\"oldpw\" type=\"password\" autocomplete=\"off\">"
                "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                "<p class=\"sub\">If you no longer have that sticker, email "
                "support@keephaven.co and we can reset it for you.</p>"
                "<button type=\"submit\">Use this box's password for Photos too</button>"
                "</form></div>")

    def backup_mode_card():
        # Converting an already-set-up box without a soft reset. Behind the
        # danger-zone password because it stops all six services.
        out = ""
        try:
            r = run(["sudo", "-n", "${wrappers.backupModeStatus}"], timeout=10)
            out = (r.stdout or "").strip()
        except Exception:
            pass
        eye = ("<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button>")
        pw = ("<label>Your password (the one on the sticker always works)</label>"
              "<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">" + eye + "</div>")
        if out == "on":
            return ("<div class=\"card\"><h2>Backup box</h2>"
                    "<p class=\"sub\">This Keephaven is set up as a <b>backup</b>. Its own apps are "
                    "switched off and it holds a copy of another box. Turning this off starts its "
                    "apps again; nothing that is stored on it is deleted either way.</p>"
                    "<form method=\"POST\" action=\"/backup-mode-off\" "
                    "onsubmit=\"return confirm('Stop being a backup box and start this Keephaven\\'s own apps?');\">"
                    + pw +
                    "<button class=\"neutral\" type=\"submit\">Stop being a backup box</button></form></div>")
        return ("<div class=\"card\"><h2>Backup box</h2>"
                "<p class=\"sub\">Turn this Keephaven into a <b>backup</b> for another one. Its six "
                "apps stop, and it shows backup status instead. <b>Nothing already on this box is "
                "deleted</b> &mdash; it is left exactly as it is, just not served. Use this on the "
                "second box, not on the Keephaven you use every day.</p>"
                "<form method=\"POST\" action=\"/backup-mode-on\" "
                "onsubmit=\"return confirm('Turn this Keephaven into a backup box? Its own apps will stop.');\">"
                + pw +
                "<button class=\"neutral\" type=\"submit\">Make this a backup box</button></form></div>")

    def backup_now_form():
        return ("<form method=\"POST\" action=\"/backup-now\">"
                "<button class=\"neutral\" type=\"submit\">Back up now</button></form>")

    def pairing_card():
        out = ""
        try:
            r = run(["sudo", "-n", "${wrappers.pairStatus}"], timeout=10)
            out = (r.stdout or "").strip()
        except Exception:
            pass
        if out.startswith("paired"):
            parts = out.split()
            role = parts[1] if len(parts) > 1 else ""
            peer = parts[2] if len(parts) > 2 else ""
            state = parts[3] if len(parts) > 3 else "ok"
            if state == "pending" and peer and pair_resolve_if_pending(peer):
                state = "ok"
            peer_h = html.escape("keephaven-" + peer)
            if state == "broken":
                # The record claims a pairing this box cannot honour (missing pair
                # key / missing authorized key). Never render a confident "paired"
                # over state that isn't there — say so and offer a re-pair.
                return ("<div class=\"card\"><h2>Pairing needs attention</h2>"
                        "<p class=\"sub\">This Keephaven still has a pairing recorded with <b>"
                        + peer_h + "</b>, but the connection details are missing, so backups "
                        "to that box cannot run. This usually means the pairing was removed on "
                        "one side. <b>Unpair here and pair the two boxes again</b> to fix it.</p>"
                        "<form method=\"POST\" action=\"/pair/unpair\" "
                        "onsubmit=\"return confirm('Remove the broken pairing from this Keephaven?');\">"
                        "<label>Your password (the one on the sticker always works)</label>"
                        "<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">"
                        "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                        "<button class=\"neutral\" type=\"submit\">Remove this pairing</button></form></div>")
            if role == "backup-target":
                desc = ("This Keephaven is set up to hold the backup for <b>" + peer_h + "</b>.")
            else:
                desc = ("This Keephaven is paired with <b>" + peer_h + "</b> as its backup box.")
            if state == "pending":
                desc += (" The two boxes haven't seen each other on your private network yet "
                         "&mdash; make sure <b>Remote access</b> is turned on for both. "
                         "They'll connect on their own once it is.")
            return ("<div class=\"card\"><h2>Paired Keephaven</h2>"
                    "<p class=\"sub\">" + desc + " Unpairing removes the trusted connection "
                    "between the two boxes.</p>"
                    + backup_detail_html(role)
                    + (backup_now_form() if role == "primary" else "")
                    + "<form method=\"POST\" action=\"/pair/unpair\" "
                    "onsubmit=\"return confirm('Unpair the two Keephavens now?');\">"
                    "<label>Your password (the one on the sticker always works)</label>"
                    "<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">"
                    "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                    "<button class=\"neutral\" type=\"submit\">Unpair</button></form></div>")
        return ("<div class=\"card\"><h2>Pair with another Keephaven</h2>"
                "<p class=\"sub\">Pairing creates a private, trusted connection between two "
                "Keephavens you own &mdash; the first step in keeping a backup of this box at "
                "another house. The other Keephaven must be powered on and reachable (on your "
                "home network, or with <b>Remote access</b> turned on for both boxes).</p>"
                "<p class=\"sub\"><b>Direction matters:</b> do this on the Keephaven you want to "
                "keep as your <b>main</b> box. The box you name below becomes its <b>backup</b>.</p>"
                "<form id=\"pair-form\" method=\"POST\" action=\"/pair/start\" "
                "onsubmit=\"var n=this.peer.value.trim()||'the other box';"
                "return confirm('Pair with '+n+'?\\n\\nTHIS Keephaven stays your main box.\\n'"
                "+n+' becomes its backup copy.');\">"
                "<label>The other Keephaven's name (on its sticker)</label>"
                "<input name=\"peer\" autocomplete=\"off\" placeholder=\"keephaven-xw3km\">"
                "<label>The other Keephaven's password (on its sticker)</label>"
                "<div class=\"pwrow\"><input name=\"peerpw\" type=\"password\" autocomplete=\"off\">"
                "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                "<label>This Keephaven's password</label>"
                "<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">"
                "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                "<p class=\"sub\" style=\"margin-top:14px\"><label style=\"font-weight:400\">"
                "<input type=\"checkbox\" name=\"force\" value=\"yes\" style=\"width:auto;margin-right:8px\">"
                "Make it the backup anyway &mdash; only tick this if the other box has been used "
                "as a main Keephaven and you want it to become this box's backup.</label></p>"
                "<button type=\"submit\">Pair</button></form></div>")

    def update_card():
        # Protected-surface apply control. Reads the (root-written) update status;
        # only offers "install" when a signed candidate is verified + staged.
        try:
            with open("/var/lib/cloudunit/update/status.json") as f:
                st = json.load(f)
        except Exception:
            st = {}
        state = st.get("state", "")
        if state == "staged-ok":
            ver = html.escape(str(st.get("available", "")))
            return ("<div class=\"card\"><h2>Software update</h2>"
                    "<p class=\"sub\">A verified update (" + ver + ") is ready to install. "
                    "Keephaven will restart to install it. Your photos, files, and apps are kept; "
                    "if the update has a problem it rolls back to the current version on its own.</p>"
                    "<form method=\"POST\" action=\"/update-apply\" "
                    "onsubmit=\"return confirm('Install the update and restart now? Your photos and files are kept.');\">"
                    "<button type=\"submit\">Install update &amp; restart</button></form></div>")
        if state in ("applying", "rolling-back"):
            return ("<div class=\"card\"><h2>Software update</h2>"
                    "<p class=\"sub\">An update is being installed and your Keephaven will restart. "
                    "This can take a few minutes.</p></div>")
        return ""

    # ---- APP PICKER: Settings -> Apps (docs/architecture/app-picker.md) ----
    # State comes from the root wrapper (the markers live on the data partition);
    # Immich/Photos is always on and never listed.
    APP_NAMES = {"jellyfin": "Movies (Jellyfin)", "navidrome": "Music (Navidrome)",
                 "audiobookshelf": "Audiobooks (AudioBookshelf)", "kavita": "Books (Kavita)",
                 "freshrss": "News (FreshRSS)"}

    def app_states():
        # [(app, is_on), ...] in image order; "backup" on a backup box; None if unreadable.
        r = run(["sudo", "-n", "${wrappers.appSet}", "status"], timeout=10)
        if r is None or r.returncode != 0:
            return None
        lines = (r.stdout or "").strip().splitlines()
        if lines[:1] == ["backup-mode"]:
            return "backup"
        st = []
        for line in lines:
            p = line.split()
            if len(p) == 2 and p[0] in APP_NAMES and p[1] in ("on", "off"):
                st.append((p[0], p[1] == "on"))
        return st

    def apps_card():
        # Pre-setup the page can still render via /done (an allowlisted result
        # page), but POST /apps is refused there -- so don't show the card at all.
        if not setup_done():
            return ""
        st = app_states()
        # Nothing to pick (Photos edition), a backup box, or unreadable: no card.
        if not st or st == "backup":
            return ""
        rows = "".join(
            "<label class=\"appchk\"><input type=\"checkbox\" name=\"app\" value=\"" + a + "\""
            + (" checked" if on else "") + "> " + html.escape(APP_NAMES[a]) + "</label>"
            for a, on in st)
        return ("<details class=\"section\" open><summary>Apps</summary><div class=\"card\">"
                "<h2>Your apps</h2>"
                "<p class=\"sub\">Untick an app to turn it off. Its files stay on your Keephaven "
                "&mdash; nothing is deleted &mdash; and you can turn it back on any time. "
                "Photos is always on.</p>"
                "<form method=\"POST\" action=\"/apps\">" + rows +
                "<label>Your password (the one on the sticker always works)</label>"
                "<div class=\"pwrow\"><input name=\"auth\" type=\"password\" autocomplete=\"off\">"
                "<button type=\"button\" class=\"pweye\" aria-label=\"Show or hide password\"><svg class=\"eye-on\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z\"/><circle cx=\"12\" cy=\"12\" r=\"3\"/></svg><svg class=\"eye-off\" style=\"display:none\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><path d=\"M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94\"/><path d=\"M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19\"/><line x1=\"1\" y1=\"1\" x2=\"23\" y2=\"23\"/></svg></button></div>"
                "<button type=\"submit\">Save apps</button></form></div></details>")

    def page(msg="", host=None):
        note = ("<div class='note'>" + html.escape(msg) + "</div>") if msg else ""
        apps_card_html = apps_card()
        support = support_status_line()
        remote_card = remote_access_card()
        update_card_html = update_card()
        pair_card = pairing_card() if REPLICATION_UI else ""
        photos_card = photos_signin_card() if REPLICATION_UI else ""
        home = "http://" + ((host.split(":")[0].strip() if host else "") or kh_host()) + "/"
        backup_section = ("<details class=\"section\" open><summary>Backup</summary>"
                          + pair_card + promote_card() + backup_mode_card()
                          + "</details>") if pair_card else ""
        return """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven Settings</title>
    <style>
      :root {{ --ink:#1c2733; --muted:#5f6b78; --line:#e5eaf0; --bg:#f5f7fa; --card:#fff;
              --brand:#2d6cdf; --brand-dark:#1f52ad; --ok:#2a8a4a; --danger:#c23b3b;
              --warnbg:#fff8ee; --warnline:#f0d9b5;
              --r:12px; --shadow:0 1px 3px rgba(16,24,32,.06),0 1px 2px rgba(16,24,32,.04); }}
      * {{ box-sizing:border-box; }}
      body {{ margin:0; font-family: system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
              color:var(--ink); background:var(--bg); padding-top:56px; line-height:1.5;
              -webkit-text-size-adjust:100%; }}
      .topbar {{ position:fixed; top:0; left:0; right:0; height:56px; z-index:10;
                 display:flex; align-items:center; justify-content:space-between;
                 padding:0 16px; background:#fff; border-bottom:1px solid var(--line); }}
      .brand {{ display:flex; align-items:center; gap:8px; font-weight:700; font-size:1.15rem;
                letter-spacing:-.01em; color:var(--ink); text-decoration:none; }}
      .brandmark {{ width:12px; height:12px; border-radius:3px; background:var(--brand); }}
      .tabs {{ display:flex; gap:6px; }}
      .tab {{ display:inline-flex; align-items:center; gap:6px; padding:7px 12px;
              border-radius:999px; text-decoration:none; color:var(--muted);
              font-size:.9rem; font-weight:600; }}
      .tab svg {{ width:16px; height:16px; }}
      .tab.active {{ background:#eaf1fc; color:var(--brand); }}
      .tab:hover {{ color:var(--brand); }}
      .wrap {{ max-width:640px; margin:0 auto; padding:16px 16px 24px; }}
      h1 {{ text-align:center; font-size:1.5rem; margin:6px 0 16px; }}
      .section {{ margin-bottom:16px; border:1px solid var(--line); border-radius:var(--r);
                  background:var(--card); box-shadow:var(--shadow); overflow:hidden; }}
      .section > summary {{ cursor:pointer; padding:14px 16px; font-size:.8rem; font-weight:700;
                            letter-spacing:.06em; text-transform:uppercase; color:var(--muted); }}
      .section[open] > summary {{ border-bottom:1px solid var(--line); }}
      .section .card {{ border:0; border-top:1px solid var(--line); border-radius:0;
                        box-shadow:none; background:transparent; margin:0; }}
      .section > summary + .card {{ border-top:0; }}
      .card {{ background:var(--card); border:1px solid var(--line); border-radius:var(--r);
               box-shadow:var(--shadow); padding:18px; margin-bottom:16px; }}
      .card h2 {{ font-size:1.05rem; margin:0 0 6px; }}
      label {{ display:block; margin:12px 0 4px; font-weight:600; font-size:.92rem; }}
      label.appchk {{ display:flex; align-items:center; gap:10px; margin:8px 0; font-weight:500; font-size:1rem; }}
      label.appchk input {{ width:20px; height:20px; margin:0; flex:none; }}
      input, select {{ width:100%; padding:10px; border:1px solid #ccd3db; border-radius:8px;
                       box-sizing:border-box; font-size:1rem; }}
      button {{ margin-top:16px; padding:11px 18px; border:0; border-radius:8px;
                background:var(--brand); color:#fff; font-size:1rem; font-weight:600; cursor:pointer; }}
      button:hover {{ background:var(--brand-dark); }}
      button.neutral {{ background:#fff; color:var(--ink); border:1px solid #ccd3db; }}
      button.neutral:hover {{ background:#f1f4f8; }}
      button.danger {{ background:var(--danger); color:#fff; }}
      button.danger:hover {{ background:#a83030; }}
      .section.danger {{ border-color:var(--warnline); background:var(--warnbg); }}
      .section.danger > summary {{ color:#9a6a1a; display:flex; align-items:center; gap:8px; }}
      .section.danger > summary svg {{ width:16px; height:16px; }}
      .section.danger[open] > summary {{ border-bottom-color:var(--warnline); }}
      .section.danger .card {{ border-top-color:var(--warnline); }}
      .note {{ background:#e7f3e7; border:1px solid #b6dbb6; padding:12px;
               border-radius:8px; margin-bottom:16px; }}
      .sub {{ color:var(--muted); font-size:.9em; }}
      .pw {{ font-size:1.1em; font-weight:600; text-align:center; background:#fff;
             border:1px solid var(--line); border-radius:10px; padding:16px; margin:14px 0;
             word-break:break-all; }}
      .ra-spin {{ width:22px; height:22px; margin:14px auto 0; border:3px solid #cfd8e3;
                  border-top-color:var(--brand); border-radius:50%;
                  animation:ra-spin .9s linear infinite; }}
      @keyframes ra-spin {{ to {{ transform:rotate(360deg); }} }}
      a {{ color:var(--brand); }}
      .refresh {{ text-align:center; margin-top:20px; }}
      .pwrow {{ position:relative; }}
      .pwrow input {{ padding-right:44px; }}
      .pweye {{ position:absolute; right:4px; top:50%; transform:translateY(-50%);
                margin:0; padding:6px; background:transparent; border:0;
                cursor:pointer; color:var(--muted); line-height:0; }}
      .pweye:hover {{ background:transparent; color:var(--ink); }}
      .pweye svg {{ width:20px; height:20px; }}
    </style></head>
    <body>
      <header class="topbar">
        <a class="brand" href="{home}"><span class="brandmark"></span>Keephaven</a>
        <nav class="tabs">
          <a class="tab" href="{home}"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 11l9-8 9 8"/><path d="M5 10v9a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-9"/></svg><span>Home</span></a>
          <a class="tab active" href="/"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg><span>Settings</span></a>
        </nav>
      </header>
      <main class="wrap">
      <h1>Settings</h1>
      {note}
      {update_card}
      {photos_card}
      {apps_card}
      <details class="section" open>
        <summary>Network</summary>
        <div class="card">
          <h2>Network name</h2>
          <p class="sub">The Wi-Fi network name devices see. Changing only the name does not
             change your password. You will need to reconnect to the renamed network.</p>
          <form method="POST" action="/ssid">
            <label>Network name</label>
            <input name="ssid" placeholder="Leave blank to keep current" maxlength="32">
            <button type="submit">Save network name</button>
          </form>
        </div>
        <div class="card">
          <h2>Password</h2>
          <p class="sub">This is the one password for everything: Wi-Fi, all your apps, and file
             sharing. Changing it updates them all. It can take a minute, and you will need to
             reconnect to Wi-Fi with the new password.</p>
          <form method="POST" action="/password"
                onsubmit="return confirm('Change the password for Wi-Fi and all apps now?');">
            <label>New password (at least 8 characters, no spaces)</label>
            <input name="password" type="text" placeholder="Leave blank to keep current" minlength="8" maxlength="63">
            <label>Current password (or the one on the sticker)</label>
            <div class="pwrow">
              <input name="auth" type="password" autocomplete="off">
              <button type="button" class="pweye" aria-label="Show or hide password"><svg class="eye-on" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg><svg class="eye-off" style="display:none" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg></button>
            </div>
            <button type="submit">Change password</button>
          </form>
        </div>
      </details>
      <details class="section" open>
        <summary>Access</summary>
        {remote_card}
        <div class="card">
          <h2>Support access</h2>
          <p class="sub">{support} Only turn this on if Keephaven support asks you to. Paste the
             key they give you and pick how long it stays on. It turns off by itself when the time
             is up, and a restart always turns it off.</p>
          <form method="POST" action="/support-access">
            <label>Support key (paste exactly what support sends you)</label>
            <input name="key" autocomplete="off" placeholder="ssh-ed25519 AAAA...">
            <label>Turn off after</label>
            <select name="hours">
              <option value="8">8 hours</option>
              <option value="24" selected>24 hours</option>
              <option value="72">72 hours (3 days)</option>
            </select>
            <label>Your password (the one on the sticker always works)</label>
            <div class="pwrow">
              <input name="auth" type="password" autocomplete="off">
              <button type="button" class="pweye" aria-label="Show or hide password"><svg class="eye-on" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg><svg class="eye-off" style="display:none" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg></button>
            </div>
            <button type="submit">Turn on support access</button>
          </form>
          <form method="POST" action="/support-access-revoke"
                onsubmit="return confirm('Turn off support access now?');">
            <button class="neutral" type="submit">Turn off support access</button>
          </form>
        </div>
      </details>
      {backup_section}
      <div class="card">
        <h2>Restart Keephaven</h2>
        <p class="sub">Turn it off and on again. Nothing changes &mdash; this just restarts the
           box and brings your apps back. Try this first if something isn't working right.</p>
        <form method="POST" action="/restart"
              onsubmit="return confirm('Restart Keephaven now?');">
          <button type="submit">Restart</button>
        </form>
      </div>
      <div class="card">
        <h2>Send a health report</h2>
        <p class="sub">If support asks for one, this shows a short technical summary of
           how your Keephaven is doing &mdash; version, storage space, memory, and whether
           each app is running. <b>It contains none of your photos, files, or passwords.</b>
           You'll see exactly what it says before anything is sent, and nothing sends
           until you choose to.</p>
        <form method="GET" action="/health-report">
          <button class="neutral" type="submit">Prepare health report</button>
        </form>
      </div>
      <details class="section danger">
        <summary><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0z"/><line x1="12" y1="9" x2="12" y2="13"/><line x1="12" y1="17" x2="12.01" y2="17"/></svg>Danger zone</summary>
        <div class="card">
          <h2>Reset password</h2>
          <p class="sub">Forgot your password? This puts everything back to the password printed
             on the sticker on your Keephaven. Your photos, files, and apps are not deleted.</p>
          <form method="POST" action="/reset-password"
                onsubmit="return confirm('Reset the password back to the one on the sticker?');">
            <label>The password printed on your sticker</label>
            <div class="pwrow">
              <input name="auth" type="password" autocomplete="off">
              <button type="button" class="pweye" aria-label="Show or hide password"><svg class="eye-on" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg><svg class="eye-off" style="display:none" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg></button>
            </div>
            <button class="neutral" type="submit">Reset my password</button>
          </form>
        </div>
        <div class="card">
          <h2>Start setup over</h2>
          <p class="sub">Start the first-time setup again. Your photos, files, and apps are
             <b>kept</b> &mdash; nothing is deleted. The box restarts into setup.</p>
          <form method="POST" action="/soft-reset"
                onsubmit="return confirm('Re-run setup now? Your photos and files are kept.');">
            <label>Your password (the one on the sticker always works)</label>
            <div class="pwrow">
              <input name="auth" type="password" autocomplete="off">
              <button type="button" class="pweye" aria-label="Show or hide password"><svg class="eye-on" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg><svg class="eye-off" style="display:none" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg></button>
            </div>
            <button class="neutral" type="submit">Start setup over</button>
          </form>
        </div>
        <div class="card">
          <h2>Factory reset</h2>
          <p class="sub"><b>This permanently deletes everything</b> &mdash; all your photos, music,
             movies, books, and files, and every app account. The box returns to how it was out of
             the box, using the password on your sticker. This cannot be undone.</p>
          <form method="POST" action="/factory-reset"
                onsubmit="return confirm('This ERASES ALL your photos and files permanently. Are you absolutely sure?');">
            <label>Type ERASE to confirm</label>
            <input name="confirm" autocomplete="off" placeholder="ERASE">
            <label>Your password (the one on the sticker always works)</label>
            <div class="pwrow">
              <input name="auth" type="password" autocomplete="off">
              <button type="button" class="pweye" aria-label="Show or hide password"><svg class="eye-on" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/><circle cx="12" cy="12" r="3"/></svg><svg class="eye-off" style="display:none" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M17.94 17.94A10.07 10.07 0 0 1 12 20c-7 0-11-8-11-8a18.45 18.45 0 0 1 5.06-5.94"/><path d="M9.9 4.24A9.12 9.12 0 0 1 12 4c7 0 11 8 11 8a18.5 18.5 0 0 1-2.16 3.19"/><line x1="1" y1="1" x2="23" y2="23"/></svg></button>
            </div>
            <button class="danger" type="submit">Erase everything &amp; start over</button>
          </form>
        </div>
      </details>
      <p class="refresh"><a href="/">&#8635; Refresh</a></p>
      </main>
      <script>
      document.querySelectorAll(".pweye").forEach(function(b) {{
        b.addEventListener("click", function() {{
          var i = b.parentNode.querySelector("input");
          var show = i.getAttribute("type") === "password";
          i.setAttribute("type", show ? "text" : "password");
          b.querySelector(".eye-on").style.display = show ? "none" : "";
          b.querySelector(".eye-off").style.display = show ? "" : "none";
        }});
      }});
      </script>
    </body></html>""".format(note=note, support=html.escape(support), remote_card=remote_card, update_card=update_card_html, backup_section=backup_section, photos_card=photos_card, apps_card=apps_card_html, home=html.escape(home))

    def run(cmd, timeout=None):
        try:
            return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(cmd, 124, "", "timeout")

    # ---- POST-redirect-GET plumbing for the danger zone ----
    # A page rendered straight from a POST is RE-SUBMITTED by the browser on
    # refresh, tab-restore, or Back-then-Forward -- carrying the password field
    # with it. On these routes that means a second factory reset, password change,
    # or reboot that nobody asked for; a customer refreshing after an erase would
    # erase again. Every danger-zone POST therefore does its work, stashes the
    # result, and 303s to a GET (/done?t=...) that is safe to reload forever.
    # (Observed for real: the Phase 1 gate journal recorded an unpair nobody
    # clicked, 2026-08-05.)
    #
    # Results are held in memory only, keyed by an unguessable token, and expire.
    # "msg" re-renders the live settings page with a note (so a reload shows
    # CURRENT state); "html" replays a fixed page verbatim (the reconnect /
    # erasing pages, which must keep showing the password and instructions).
    _results = {}
    _results_lock = threading.Lock()
    RESULT_TTL = 900

    def stash_result(kind, payload):
        tok = secrets.token_urlsafe(16)
        now = time.time()
        with _results_lock:
            for k in [k for k, v in _results.items() if now - v[0] > RESULT_TTL]:
                _results.pop(k, None)
            _results[tok] = (now, kind, payload)
        return tok

    def reconnect_page(newpw, ssid, title="Password changed", intro="Your apps and file sharing are updated. The Wi-Fi password is changing now."):
        pw = html.escape(newpw)
        net = html.escape(ssid) if ssid else "your Keephaven network"
        return """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven</title>
    <style>
      body {{ font-family: sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }}
      h1 {{ text-align: center; }}
      .pw {{ font-size: 1.5em; font-weight: 700; text-align: center; letter-spacing: .5px;
             background: #f4f6f8; border: 1px solid #e2e6ea; border-radius: 10px;
             padding: 16px; margin: 18px 0; word-break: break-all; }}
      ol {{ line-height: 1.7; font-size: 1.05em; }}
      .big {{ background: #fff6e5; border: 1px solid #ffd591; border-radius: 10px;
              padding: 16px; margin-top: 20px; }}
    </style></head>
    <body>
      <h1>{title}</h1>
      <p>{intro}</p>
      <p>Your new password is:</p>
      <div class="pw">{pw}</div>
      <div class="big">
        <ol>
          <li><b>Close this page.</b></li>
          <li>Open your phone's Wi-Fi settings and reconnect to <b>{net}</b> using the new password above.</li>
          <li>Open Keephaven again ({host}) once you are reconnected.</li>
        </ol>
      </div>
    </body></html>""".format(pw=pw, net=net, title=html.escape(title), intro=html.escape(intro), host=kh_host())

    def deferred_ap(newpw, delay=6):
        def worker():
            time.sleep(delay)
            run(["sudo", "-n", "${applyApConfig}/bin/cloudunit-apply-ap-config", "", newpw])
        threading.Thread(target=worker, daemon=True).start()

    def ssid_reconnect_page(new_ssid):
        net = html.escape(new_ssid)
        return """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven</title>
    <style>
      body {{ font-family: sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }}
      h1 {{ text-align: center; }}
      .pw {{ font-size: 1.5em; font-weight: 700; text-align: center; letter-spacing: .5px;
             background: #f4f6f8; border: 1px solid #e2e6ea; border-radius: 10px;
             padding: 16px; margin: 18px 0; word-break: break-all; }}
      ol {{ line-height: 1.7; font-size: 1.05em; }}
      .big {{ background: #fff6e5; border: 1px solid #ffd591; border-radius: 10px;
              padding: 16px; margin-top: 20px; }}
    </style></head>
    <body>
      <h1>Network renamed</h1>
      <p>Your network is being renamed. Your password is <b>not</b> changing.</p>
      <p>Your network's new name is:</p>
      <div class="pw">{net}</div>
      <div class="big">
        <ol>
          <li><b>Close this page.</b></li>
          <li>Open your phone's Wi-Fi settings and connect to <b>{net}</b> using your <b>same password</b>.</li>
          <li>Open Keephaven again ({host}) once you are reconnected.</li>
        </ol>
      </div>
    </body></html>""".format(net=net, host=kh_host())

    def deferred_ssid(new_ssid, delay=6):
        def worker():
            time.sleep(delay)
            run(["sudo", "-n", "${applyApConfig}/bin/cloudunit-apply-ap-config", new_ssid, ""])
        threading.Thread(target=worker, daemon=True).start()

    def ap_subnet():
        # Derive the AP network prefix from wlan0's live address, e.g.
        # "inet 192.168.50.1/24" -> "192.168.50.". Falls back to the known
        # configured value if wlan0 cannot be read.
        try:
            out = subprocess.run(["ip", "-4", "addr", "show", "wlan0"],
                                 capture_output=True, text=True).stdout
            for tok in out.split():
                if tok.count(".") == 3 and "/" in tok:
                    ip = tok.split("/")[0]
                    return ip.rsplit(".", 1)[0] + "."
        except Exception:
            pass
        return "192.168.50."

    def on_ap(handler):
        # True if the request came from a client on the Keephaven AP (which will
        # be dropped when the AP restarts). Safest default on error: True.
        try:
            return handler.client_address[0].startswith(ap_subnet())
        except Exception:
            return True

    def saved_page(title, value, kind):
        # Calm confirmation for clients NOT on the Keephaven AP (e.g. via the
        # home router over cable). Their connection is unaffected; still show the
        # new value for when they use the AP later.
        v = html.escape(value)
        label = "Your new password" if kind == "pw" else "Your network's new name"
        extra = ("Use this the next time you connect to Keephaven's own Wi-Fi network."
                 if kind == "pw" else
                 "This is the name of Keephaven's own Wi-Fi network for next time.")
        return """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven</title>
    <style>
      body {{ font-family: sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }}
      h1 {{ text-align: center; }}
      .pw {{ font-size: 1.5em; font-weight: 700; text-align: center; letter-spacing: .5px;
             background: #f4f6f8; border: 1px solid #e2e6ea; border-radius: 10px;
             padding: 16px; margin: 18px 0; word-break: break-all; }}
      .ok {{ background: #e7f3e7; border: 1px solid #b6dbb6; border-radius: 10px;
             padding: 16px; margin-top: 20px; }}
      a {{ color: #2d6cdf; }}
    </style></head>
    <body>
      <h1>{title}</h1>
      <p>{label}:</p>
      <div class="pw">{v}</div>
      <div class="ok">
        <p>Your current connection is not affected. {extra}</p>
      </div>
      <p style="text-align:center"><a href="/">&#8592; Back to Settings</a></p>
    </body></html>""".format(title=html.escape(title), label=label, v=v, extra=extra)

    def _restart_shell(title, lead, on_ap_client):
        if on_ap_client:
            where = "Reconnect to Keephaven's Wi-Fi (same name and password), then open " + kh_host() + " in a minute."
        else:
            where = "Open " + kh_host() + " again in a minute."
        return """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven</title>
    <style>body {{ font-family: sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }}
      h1 {{ text-align:center; }} .big {{ background:#fff6e5; border:1px solid #ffd591;
      border-radius:10px; padding:16px; margin-top:20px; }}</style></head>
    <body><h1>{title}</h1>
    <p>{lead}</p>
    <div class="big"><p>{where}</p></div>
    </body></html>""".format(title=html.escape(title), lead=html.escape(lead), where=html.escape(where))

    def setup_restart_page(on_ap_client):
        return _restart_shell("Restarting setup\u2026",
            "Keephaven is restarting into first-time setup. Your photos and files are kept.",
            on_ap_client)

    def restart_page(on_ap_client):
        return _restart_shell("Restarting\u2026",
            "Keephaven is restarting. Your photos, files, and settings are unchanged.",
            on_ap_client)

    def health_report_page(report):
        # Show the report verbatim; the send is a mailto the customer triggers.
        mailto = ("mailto:support@keephaven.co?subject=" +
                  urllib.parse.quote("Keephaven health report") +
                  "&body=" + urllib.parse.quote(report + "\n\n"))
        return """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven health report</title>
    <style>body {{ font-family: system-ui,sans-serif; max-width: 640px; margin: 40px auto;
      padding: 0 20px; color:#1c2733; line-height:1.5; }}
      h1 {{ font-size:1.5rem; }} .sub {{ color:#5f6b78; }}
      pre {{ background:#f5f7fa; border:1px solid #e5eaf0; border-radius:10px;
        padding:16px; overflow:auto; font-size:.92rem; }}
      .btn {{ display:inline-block; margin-top:8px; padding:11px 18px; border-radius:8px;
        background:#2d6cdf; color:#fff; font-weight:600; text-decoration:none; }}
      a.back {{ display:inline-block; margin-top:18px; color:#2d6cdf; }}</style></head>
    <body>
    <h1>Your health report</h1>
    <p class="sub">This is everything the report contains. It has none of your photos,
      files, or passwords. Nothing has been sent &mdash; tap the button to send it to
      support from your own email, or just close this page.</p>
    <pre>{report}</pre>
    <a class="btn" href="{mailto}">Send to support</a>
    <br><a class="back" href="/">&larr; Back to Settings</a>
    </body></html>""".format(report=html.escape(report), mailto=html.escape(mailto))

    class Handler(http.server.BaseHTTPRequestHandler):
        timeout = 15
        def _send(self, body, code=200, ctype="text/html; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            self.wfile.write(body.encode())

        def _done(self, kind, payload):
            # Do-work-then-redirect. See stash_result above.
            tok = stash_result(kind, payload)
            self.send_response(303)
            self.send_header("Location", "/done?t=" + tok)
            self.end_headers()

        def _msg(self, text):
            self._done("msg", text)

        def _result(self, body):
            self._done("html", body)

        def _pair_done(self, code, peer=""):
            # POST-redirect-GET: never render a pairing result straight from the
            # POST. A rendered POST response is re-submitted by the browser on
            # refresh/tab-restore -- with the password field -- which can silently
            # re-run a destructive action (the Phase 1 gate logged an unpair nobody
            # clicked). The 303 makes the reloadable URL a plain GET.
            loc = "/?m=" + urllib.parse.quote(code)
            if peer:
                loc += "&p=" + urllib.parse.quote(peer)
            self.send_response(303)
            self.send_header("Location", loc)
            self.end_headers()

        def do_GET(self):
            if pre_setup_blocked(self.path):
                self._send(NOT_YET_PAGE, 403)
                return
            if self.path == "/remote-access/status":
                # Tiny read-only endpoint the Settings card polls (every 3s) so it
                # can advance off->starting->url->connected on its own. Served on
                # its own thread (ThreadingMixIn), so a slow status read never
                # blocks the dashboard.
                rs = run(["sudo", "-n", "${wrappers.remoteAccessStatus}"], timeout=10)
                self._send((rs.stdout or "").strip() or "unknown",
                           ctype="text/plain; charset=utf-8")
                return
            if self.path.split("?", 1)[0] == "/health-report":
                # Read-only: run the diagnostics wrapper, show the FULL output on
                # screen, and offer a pre-filled mailto so the customer sends it
                # themselves. Nothing leaves the box here. (privacy page: no personal
                # data in the report.)
                r = run(["sudo", "-n", "${healthReport}/bin/cloudunit-health-report"], timeout=15)
                report = (r.stdout if r and r.returncode == 0 and r.stdout else
                          "Couldn't gather the report just now. Please restart your Keephaven and try again.")
                self._send(health_report_page(report))
                return
            if self.path.split("?", 1)[0] == "/done":
                # Reloadable result of a danger-zone POST. Idempotent by
                # construction: it only replays what the POST already produced.
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                ent = None
                tok = q.get("t", [""])[0]
                if tok:
                    with _results_lock:
                        ent = _results.get(tok)
                if ent is None:
                    # Unknown/expired token (e.g. the box rebooted, which is the
                    # normal end of a restart/erase flow) -- just show Settings.
                    self._send(page(host=self.headers.get("Host")))
                    return
                if ent[1] == "msg":
                    self._send(page(ent[2], host=self.headers.get("Host")))
                else:
                    self._send(ent[2])
                return
            # Landing page, optionally carrying a pairing result from the 303 above.
            # Both params are untrusted: the code is looked up in a fixed table and
            # the suffix is charset-validated before it can reach the page.
            msg = ""
            q = urllib.parse.urlparse(self.path).query
            if q:
                qs = urllib.parse.parse_qs(q)
                code = qs.get("m", [""])[0]
                peer = qs.get("p", [""])[0].strip().lower()
                msg = pair_msg(code, peer if valid_suffix(peer) else "")
            self._send(page(msg, host=self.headers.get("Host")))

        def do_POST(self):
            if pre_setup_blocked(self.path):
                self._send(NOT_YET_PAGE, 403)
                return
            length = int(self.headers.get("Content-Length", 0))
            data = urllib.parse.parse_qs(self.rfile.read(length).decode())

            if self.path == "/ssid":
                ssid = data.get("ssid", [""])[0].strip()
                if not ssid:
                    self._msg("Enter a network name to change it.")
                    return
                # Renaming restarts the AP and drops her, same as a password
                # change. Show the reconnect page first, then apply after a delay
                # so the page reaches her before Wi-Fi switches over.
                if on_ap(self):
                    self._result(ssid_reconnect_page(ssid))
                else:
                    self._result(saved_page("Network renamed", ssid, "ssid"))
                deferred_ssid(ssid)

            elif self.path == "/password":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Password was NOT changed."))
                    return
                newpw = data.get("password", [""])[0].strip()
                if not newpw:
                    self._msg("Enter a new password to change it.")
                    return
                r = run(["sudo", "-n", "${applyPassword}/bin/cloudunit-apply-password", newpw])
                if r.returncode != 0:
                    detail = (r.stdout.strip() + " " + r.stderr.strip()).strip()
                    self._msg("Some apps did not update. Nothing else changed. You can try again. Details: " + detail)
                    return
                if on_ap(self):
                    self._result(reconnect_page(newpw, current_ssid_safe()))
                else:
                    self._result(saved_page("Password changed", newpw, "pw"))
                deferred_ap(newpw)

            elif self.path == "/reset-password":
                verdict = auth_check_sticker(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Password was NOT reset."))
                    return
                rs = run(["sudo", "-n", "${readSticker}/bin/cloudunit-read-sticker"])
                sticker = rs.stdout.strip() if rs.returncode == 0 and rs.stdout.strip() else "the password on your sticker"
                if on_ap(self):
                    self._result(reconnect_page(sticker, current_ssid_safe(),
                        title="Password reset",
                        intro="Your password is being put back to the one on your Keephaven sticker."))
                else:
                    self._result(saved_page("Password reset", sticker, "pw"))
                def reset_worker():
                    time.sleep(6)
                    run(["sudo", "-n", "${resetPassword}/bin/cloudunit-reset-password"])
                threading.Thread(target=reset_worker, daemon=True).start()

            elif self.path == "/restart":
                self._result(restart_page(on_ap(self)))
                def restart_worker():
                    time.sleep(4)
                    run(["sudo", "-n", "${restartBox}/bin/cloudunit-restart"])
                threading.Thread(target=restart_worker, daemon=True).start()

            elif self.path == "/update-apply":
                # Protected apply trigger: arm + reboot via the narrow sudo wrapper
                # (cloudunit-web has NOPASSWD only for this fixed no-arg command).
                self._result(restart_page(on_ap(self)))
                def update_apply_worker():
                    time.sleep(4)
                    run(["sudo", "-n", "${wrappers.updateApply}"])
                threading.Thread(target=update_apply_worker, daemon=True).start()

            elif self.path == "/soft-reset":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Setup was NOT restarted."))
                    return
                self._result(setup_restart_page(on_ap(self)))
                def soft_worker():
                    time.sleep(4)
                    run(["sudo", "-n", "${softReset}/bin/cloudunit-soft-reset"])
                threading.Thread(target=soft_worker, daemon=True).start()

            elif self.path == "/factory-reset":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Factory reset was NOT done."))
                    return
                confirm = data.get("confirm", [""])[0].strip()
                if confirm != "ERASE":
                    self._msg("Factory reset was NOT done. To erase everything, type ERASE exactly.")
                    return
                # Server-side confirmed. Show a goodbye page, then wipe + reboot.
                self._result("""<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven</title>
    <style>body {{ font-family: sans-serif; max-width: 600px; margin: 40px auto; padding: 0 20px; }}
      h1 {{ text-align:center; }} .big {{ background:#fff6e5; border:1px solid #ffd591;
      border-radius:10px; padding:16px; margin-top:20px; }}</style></head>
    <body><h1>Erasing&hellip;</h1>
    <p>Keephaven is being erased and will restart fresh. This takes a few minutes.</p>
    <div class="big"><p>When it restarts, connect using the network name and password on your
    sticker, then open {host} to set it up again.</p></div>
    </body></html>""".format(host=kh_host()))
                def fr_worker():
                    time.sleep(4)
                    run(["sudo", "-n", "${factoryReset}/bin/cloudunit-factory-reset"])
                threading.Thread(target=fr_worker, daemon=True).start()

            elif self.path == "/remote-access":
                # AUTH ADDED (2026-08-09). This route had none, so any device on
                # the AP or LAN could switch remote access on and join the box to
                # a tailnet login flow the owner never asked for. It is now a
                # danger-zone action like every other state-changing route.
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Remote access was NOT turned on."))
                    return
                # Fire enable fire-and-forget (it is idempotent + status-first) so
                # the request returns instantly — no blocking poll, no give-up
                # page. The Settings card then auto-polls /remote-access/status and
                # surfaces the link the moment the box produces it, so a click
                # during a busy first-boot moment resolves a few seconds later
                # instead of dead-ending. No-JS browsers follow the 303 back to
                # Settings, where the card shows "starting"; a re-click is harmless.
                def ra_worker():
                    # 45s, was 20: the wrapper now STARTS tailscaled (it no longer
                    # runs from boot) and waits up to 15s for it to answer.
                    run(["sudo", "-n", "${wrappers.remoteAccessEnable}"], timeout=45)
                threading.Thread(target=ra_worker, daemon=True).start()
                self.send_response(303)
                self.send_header("Location", "/")
                self.end_headers()

            elif self.path == "/remote-access/off":
                # The real OFF switch (2026-10-03). Same danger-zone gate as ON:
                # :8888 is open to the whole LAN, and off also stops a paired
                # backup box and support access.
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Remote access was NOT turned off."))
                    return
                # Synchronous on purpose. `tailscale down` takes well under a
                # second, the wrapper checks its own result, and the owner must
                # never be shown "off" on a guess.
                r = run(["sudo", "-n", "${wrappers.remoteAccessDisable}"], timeout=45)
                if r is None or r.returncode != 0:
                    self._msg("Remote access could NOT be turned off. Restart your "
                              "Keephaven and try again; if it keeps failing, contact "
                              "support@keephaven.co.")
                    return
                self.send_response(303)
                self.send_header("Location", "/")
                self.end_headers()

            elif self.path == "/support-access":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Support access was NOT turned on."))
                    return
                key = data.get("key", [""])[0].strip()
                hours = data.get("hours", ["24"])[0].strip()
                if not key:
                    self._msg("Paste the support key to turn on support access.")
                    return
                if hours not in ("8", "24", "72"):
                    hours = "24"
                r = subprocess.run(
                    ["sudo", "-n", "${wrappers.supportGrant}", hours],
                    input=key, capture_output=True, text=True)
                if r.returncode != 0:
                    detail = (r.stdout.strip() + " " + r.stderr.strip()).strip()
                    self._msg("Support access was not turned on. Check the key and try again. Details: " + detail)
                    return
                self._msg("Support access is now on for " + hours + " hours. It will turn off by itself when the time is up.")

            elif self.path == "/apps":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Your apps were NOT changed."))
                    return
                st = app_states()
                if st == "backup":
                    self._msg("This Keephaven is a backup box. Its apps stay off until it takes over.")
                    return
                if not st:
                    self._msg("There are no apps to change on this Keephaven.")
                    return
                # Only names this box reported are acted on; anything else in the
                # form is ignored, so the request cannot name a service.
                want_on = set(data.get("app", []))
                turned_on, turned_off, failed = [], [], []
                for a, on in st:
                    new_on = a in want_on
                    if new_on == on:
                        continue
                    r = run(["sudo", "-n", "${wrappers.appSet}", a, "on" if new_on else "off"], timeout=60)
                    if r is not None and r.returncode == 0:
                        (turned_on if new_on else turned_off).append(APP_NAMES[a])
                    else:
                        failed.append(APP_NAMES[a])
                parts = []
                if turned_on:
                    parts.append("Turned on: " + ", ".join(turned_on) + ". "
                                 + ("They" if len(turned_on) > 1 else "It")
                                 + " can take a few minutes to be ready on the home screen.")
                if turned_off:
                    parts.append("Turned off: " + ", ".join(turned_off) + ". "
                                 + ("Their" if len(turned_off) > 1 else "Its")
                                 + " files are still on your Keephaven.")
                if failed:
                    parts.append("Could not change: " + ", ".join(failed) + ". Restart your Keephaven and try again.")
                self._msg(" ".join(parts) if parts else "Nothing changed.")

            elif self.path == "/support-access-revoke":
                run(["sudo", "-n", "${wrappers.supportRevoke}"])
                self._msg("Support access is now off.")

            elif self.path == "/pair/start":
                # A-side ceremony: this box mints its pair key and asks the OTHER
                # box (authenticated by ITS sticker password, which the owner
                # holds) to authorize it. Works over the tailnet (peer lookup) or
                # the LAN (mDNS .local) — the bench/LAN path pairs "pending" and
                # self-completes when both boxes are on the owner's tailnet.
                verdict = auth_check(data)
                if verdict != "ok":
                    self._pair_done("authfail" if verdict == "wrong" else "autherr")
                    return
                mine = my_suffix()
                if not mine:
                    self._pair_done("noidentity")
                    return
                peer_raw = data.get("peer", [""])[0].strip().lower()
                if peer_raw.endswith(".local"):
                    peer_raw = peer_raw[:-len(".local")]
                if peer_raw.startswith("keephaven-"):
                    peer_raw = peer_raw[len("keephaven-"):]
                if not valid_suffix(peer_raw):
                    self._pair_done("badname")
                    return
                if peer_raw == mine:
                    self._pair_done("self")
                    return
                peerpw = data.get("peerpw", [""])[0].strip()
                if not peerpw:
                    self._pair_done("nopw")
                    return
                force = "yes" if data.get("force", [""])[0].strip() else ""
                r = run(["sudo", "-n", "${wrappers.pairInit}"], timeout=15)
                if r is None or r.returncode != 0 or not (r.stdout or "").strip():
                    self._pair_done("nokey")
                    return
                pubkey = r.stdout.strip()
                ip, nodeid = tailnet_peer_lookup(peer_raw)
                addr = ip if ip else ("keephaven-" + peer_raw + ".local")
                fields = {"pw": peerpw, "suffix": mine, "pubkey": pubkey}
                if force:
                    fields["force"] = "yes"
                body = urllib.parse.urlencode(fields).encode()
                try:
                    req = urllib.request.Request(
                        "http://" + addr + ":8888/pair/accept", data=body)
                    with urllib.request.urlopen(req, timeout=20) as resp:
                        out = resp.read(4096).decode()
                except urllib.error.HTTPError as e:
                    detail = ""
                    try:
                        detail = e.read(512).decode("utf-8", "replace")
                    except Exception:
                        pass
                    if e.code == 403:
                        self._pair_done("peerpw", peer_raw)
                    elif "role-reversal" in detail:
                        self._pair_done("reversal", peer_raw)
                    elif "storage-not-ready" in detail:
                        self._pair_done("storage", peer_raw)
                    else:
                        self._pair_done("peerfail", peer_raw)
                    return
                except Exception:
                    self._pair_done("unreachable", peer_raw)
                    return
                if not out.startswith("OK"):
                    self._pair_done("peerfail", peer_raw)
                    return
                rr = run(["sudo", "-n", "${wrappers.pairRecord}", peer_raw, nodeid], timeout=10)
                if rr is None or rr.returncode != 0:
                    self._pair_done("recfail", peer_raw)
                    return
                self._pair_done("paired" if nodeid else "paired-pending", peer_raw)

            elif self.path == "/pair/accept":
                # B-side of the ceremony, called by the OTHER box over the
                # LAN/tailnet. Authenticated exactly like a local danger-zone
                # action: the caller must present THIS box's password (the owner
                # types it into the other box's screen). Plain-text response, not
                # a page — the caller is a Keephaven, not a browser.
                verdict = auth_check({"auth": data.get("pw", [""])})
                if verdict == "error":
                    self._send("ERROR: could not verify password", 500, ctype="text/plain; charset=utf-8")
                    return
                if verdict != "ok":
                    self._send("WRONG-PASSWORD", 403, ctype="text/plain; charset=utf-8")
                    return
                peer = data.get("suffix", [""])[0].strip().lower()
                if not valid_suffix(peer):
                    self._send("ERROR: bad suffix", 400, ctype="text/plain; charset=utf-8")
                    return
                pubkey = data.get("pubkey", [""])[0].strip()
                if not pubkey:
                    self._send("ERROR: missing key", 400, ctype="text/plain; charset=utf-8")
                    return
                cmd = ["sudo", "-n", "${wrappers.pairAccept}", peer]
                if data.get("force", [""])[0].strip() == "yes":
                    cmd.append("force")
                r = subprocess.run(cmd, input=pubkey, capture_output=True, text=True)
                if r.returncode == 4:
                    # Role reversal: this box has served as a MAIN Keephaven.
                    self._send("ERROR: role-reversal", 400, ctype="text/plain; charset=utf-8")
                    return
                if r.returncode == 3:
                    # Self-verification failed: kh-replica can't use the landing
                    # area. Distinct code so box A can say something actionable
                    # rather than "reported a problem".
                    self._send("ERROR: storage-not-ready", 400, ctype="text/plain; charset=utf-8")
                    return
                if r.returncode != 0:
                    self._send("ERROR: key-not-accepted", 400, ctype="text/plain; charset=utf-8")
                    return
                self._send("OK", ctype="text/plain; charset=utf-8")

            elif self.path == "/backup-now":
                # Owner-initiated backup. --no-block inside the wrapper, so this
                # returns instantly even when a first seed will run for hours.
                r = run(["sudo", "-n", "${wrappers.replicaSyncNow}"], timeout=20)
                if r is None or r.returncode != 0:
                    self._msg("Couldn't start the backup just now. Try again in a moment.")
                else:
                    self._msg("Backup started. It runs in the background - this page will show "
                              "the result once it finishes.")

            elif self.path == "/photos-signin-fix":
                # No danger-zone auth: the owner proves themselves by supplying
                # the CURRENT Photos password, which is the only thing that can
                # make this succeed. Asking for two passwords on a recovery
                # screen would be a wall, not a safeguard.
                oldpw = data.get("oldpw", [""])[0].strip()
                if not oldpw:
                    self._msg("Enter the password you currently use for Photos.")
                    return
                r = subprocess.run(["sudo", "-n", "${wrappers.photosSigninFix}"],
                                   input=oldpw, capture_output=True, text=True, timeout=60)
                if r.returncode == 3:
                    self._msg("That password didn't work for Photos. It is the one printed on "
                              "your OTHER Keephaven's sticker - the box this library came from.")
                elif r.returncode != 0:
                    self._msg("Couldn't change the Photos password just now. Nothing was changed; "
                              "you can still sign in to Photos with the other box's password.")
                else:
                    self._msg("Done - Photos now uses this Keephaven's own sticker password, "
                              "like everything else.")

            elif self.path == "/promote":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Nothing was restored."))
                    return
                if data.get("confirm", [""])[0].strip() != "RESTORE":
                    self._msg("Nothing was restored. To restore from the backup, type RESTORE exactly.")
                    return
                # --no-block: a restore can run for hours. The owner must be able
                # to close the page, lose Wi-Fi or reload without killing it.
                r = run(["sudo", "-n", "${wrappers.promoteStart}"], timeout=30)
                if r is None or r.returncode != 0:
                    self._msg("Couldn't start the restore just now. Nothing has been changed. "
                              "Restart your Keephaven and try again.")
                else:
                    self._msg("Restoring from your backup. This can take a while - you can close "
                              "this page and come back; this screen shows how it is going.")

            elif self.path in ("/backup-mode-on", "/backup-mode-off"):
                verdict = auth_check(data)
                if verdict != "ok":
                    self._msg(auth_deny_msg(verdict, "Backup mode was NOT changed."))
                    return
                on = self.path.endswith("-on")
                w = "${wrappers.backupModeEnable}" if on else "${wrappers.backupModeDisable}"
                r = run(["sudo", "-n", w], timeout=120)
                if r is None or r.returncode != 0:
                    self._msg("Couldn't change backup mode just now. Restart your Keephaven and try again.")
                elif on:
                    self._msg("This Keephaven is now a backup box. Its own apps have stopped; "
                              "nothing stored on it was deleted.")
                else:
                    self._msg("This Keephaven is no longer a backup box. Its apps are starting "
                              "again - give them a couple of minutes.")

            elif self.path == "/pair/unpair":
                verdict = auth_check(data)
                if verdict != "ok":
                    self._pair_done("unpair-authfail" if verdict == "wrong" else "unpair-autherr")
                    return
                run(["sudo", "-n", "${wrappers.pairUnpair}"], timeout=10)
                self._pair_done("unpaired")

            else:
                self._send(page(), 404)

        def log_message(self, *a):
            pass

    class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True
    with Threaded(("", PORT), Handler) as httpd:
        httpd.serve_forever()
  '';

  resetPassword = pkgs.writeShellScriptBin "cloudunit-reset-password" ''
    set -u
    UNIT_ENV="${dataDir}/unit.env"
    CURRENT_ENV="${dataDir}/current.env"
    sticker="$(${pkgs.gnugrep}/bin/grep '^UNIT_PASSWORD=' "$UNIT_ENV" | ${pkgs.coreutils}/bin/cut -d= -f2-)"
    if [ -z "$sticker" ]; then echo "ERROR: no sticker password" >&2; exit 3; fi

    # Try to reset all services to the sticker password. Capture the result but
    # do NOT bail on partial failure: a single stranded service (e.g. one whose
    # password drifted out of sync) must never block the AP reset below, because
    # the AP is the user's only way back onto the box. A stranded service is
    # recoverable separately (re-run, or factory reset); a missed AP reset is a
    # lockout.
    ${applyPassword}/bin/cloudunit-apply-password "$sticker"
    pwrc=$?

    # ALWAYS reset the AP to the sticker password. This is the critical step for
    # recovery and runs regardless of per-service results.
    ssid="$(${pkgs.gnugrep}/bin/grep '^AP_SSID=' "${dataDir}/ap.env" | ${pkgs.coreutils}/bin/cut -d= -f2-)"
    ${applyApConfig}/bin/cloudunit-apply-ap-config "$ssid" "$sticker"
    aprc=$?

    # Only an AP failure is fatal - that is the genuine lockout risk.
    if [ "$aprc" -ne 0 ]; then
      echo "ERROR: AP password reset failed (rc=$aprc)" >&2
      exit "$aprc"
    fi

    # AP is now on the sticker. Make current.env reflect that so the live-password
    # bookkeeping matches the AP and the services that did reset. (apply-password
    # only advances current.env on full success, so after a partial we set it
    # here to keep the common path consistent.)
    printf 'CURRENT_PASSWORD=%s\n' "$sticker" > "$CURRENT_ENV"
    ${pkgs.coreutils}/bin/chmod 600 "$CURRENT_ENV" 2>/dev/null || true

    if [ "$pwrc" -ne 0 ]; then
      echo "OK: AP and most services reset to sticker; some services need a re-run or factory reset"
      exit 0
    fi
    echo "OK: reset to sticker"
  '';
in
{
  options.cloudunit.wrappers = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = {};
    internal = true;
    description = ''
      Absolute /nix/store bin paths of privileged Settings wrappers, contributed
      by domain modules (e.g. tailscale.nix, support-access.nix). Settings owns
      the UI and the matching sudo NOPASSWD grants.
    '';
  };

  config = {
  users.users.${webUser} = {
    isSystemUser = true;
    group = webUser;
    description = "Keephaven web UI (unprivileged)";
  };
  users.groups.${webUser} = {};

  environment.systemPackages = [ applyApConfig applyPassword softReset resetPassword factoryReset restartBox readSticker readApPassword healthReport ];

  security.sudo.extraRules = [{
    users = [ webUser ];
    commands = [
      { command = "${applyApConfig}/bin/cloudunit-apply-ap-config"; options = [ "NOPASSWD" ]; }
      { command = "${applyPassword}/bin/cloudunit-apply-password"; options = [ "NOPASSWD" ]; }
      { command = "${resetPassword}/bin/cloudunit-reset-password"; options = [ "NOPASSWD" ]; }
      { command = "${softReset}/bin/cloudunit-soft-reset"; options = [ "NOPASSWD" ]; }
      { command = "${factoryReset}/bin/cloudunit-factory-reset"; options = [ "NOPASSWD" ]; }
      { command = "${restartBox}/bin/cloudunit-restart"; options = [ "NOPASSWD" ]; }
      { command = "${readSticker}/bin/cloudunit-read-sticker"; options = [ "NOPASSWD" ]; }
      { command = "${readApPassword}/bin/cloudunit-read-ap-password"; options = [ "NOPASSWD" ]; }
      { command = "${healthReport}/bin/cloudunit-health-report"; options = [ "NOPASSWD" ]; }
      { command = wrappers.remoteAccessEnable; options = [ "NOPASSWD" ]; }
      { command = wrappers.remoteAccessDisable; options = [ "NOPASSWD" ]; }
      { command = wrappers.remoteAccessStatus; options = [ "NOPASSWD" ]; }
      { command = wrappers.supportGrant; options = [ "NOPASSWD" ]; }
      { command = wrappers.supportRevoke; options = [ "NOPASSWD" ]; }
      { command = wrappers.supportStatus; options = [ "NOPASSWD" ]; }
      { command = wrappers.pairInit; options = [ "NOPASSWD" ]; }
      { command = wrappers.pairRecord; options = [ "NOPASSWD" ]; }
      { command = wrappers.pairAccept; options = [ "NOPASSWD" ]; }
      { command = wrappers.pairStatus; options = [ "NOPASSWD" ]; }
      { command = wrappers.pairUnpair; options = [ "NOPASSWD" ]; }
      { command = wrappers.tailnetPeers; options = [ "NOPASSWD" ]; }
      { command = wrappers.appSet; options = [ "NOPASSWD" ]; }
    ] ++ lib.optionals config.keephaven.replication.enable [
      { command = wrappers.replicaSyncNow; options = [ "NOPASSWD" ]; }
      { command = wrappers.replicaTargetStatus; options = [ "NOPASSWD" ]; }
      { command = wrappers.backupModeEnable; options = [ "NOPASSWD" ]; }
      { command = wrappers.backupModeDisable; options = [ "NOPASSWD" ]; }
      { command = wrappers.backupModeStatus; options = [ "NOPASSWD" ]; }
      { command = wrappers.promoteStart; options = [ "NOPASSWD" ]; }
      { command = wrappers.promotePreflight; options = [ "NOPASSWD" ]; }
      { command = wrappers.photosSigninStatus; options = [ "NOPASSWD" ]; }
      { command = wrappers.photosSigninFix; options = [ "NOPASSWD" ]; }
    ];
  }];

  systemd.services.cloudunit-settings = {
    description = "Cloud Unit - Settings web UI (unprivileged)";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig.RequiresMountsFor = dataDir;
    path = [ "/run/wrappers" pkgs.sudo applyApConfig applyPassword softReset resetPassword factoryReset restartBox
             pkgs.curl pkgs.docker pkgs.samba pkgs.gnugrep pkgs.coreutils pkgs.iproute2 readSticker readApPassword healthReport ];
    serviceConfig = {
      Type = "simple";
      User = webUser;
      Group = webUser;
      ExecStart = "${pkgs.python3}/bin/python3 ${settingsApp}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  networking.firewall.allowedTCPPorts = [ 8888 ];
  };
}
