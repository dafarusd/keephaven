# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  wrappers = config.cloudunit.wrappers;
  dataDir = "/var/lib/cloudunit";
  setupFlag = "${dataDir}/.setup-complete";

  wizardApp = pkgs.writeText "cloudunit-wizard.py" ''
    import http.server, socketserver, os, subprocess, threading, time, json

    DATA_DIR = "${dataDir}"
    SETUP_FLAG = "${setupFlag}"
    PORT = 80

    PAGE = """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1">
    <title>Keephaven Setup</title>
    <style>
      .spin { width: 36px; height: 36px; margin: 0 auto 18px;
              border: 4px solid #e2e6ea; border-top-color: #4a90d9;
              border-radius: 50%; animation: spin 1s linear infinite; }
      @keyframes spin { to { transform: rotate(360deg); } }
      body { font-family: sans-serif; max-width: 560px; margin: 0 auto;
             min-height: 100vh; display: flex; flex-direction: column;
             justify-content: center; padding: 20px; box-sizing: border-box;
             color: #1a2230; }
      h1 { font-size: 1.9em; margin-bottom: 8px; }
      h2 { font-size: 1.4em; }
      p { line-height: 1.5; color: #44505f; }
      .step { display: none; }
      .step.active { display: block; }
      .card { background: #f4f6f8; border: 1px solid #e2e6ea;
              border-radius: 14px; padding: 28px; }
      button { font-size: 1.05em; padding: 13px 26px; margin-top: 22px;
               cursor: pointer; border-radius: 9px; border: none;
               background: #2d6cdf; color: #fff; }
      button.secondary { background: #e2e6ea; color: #1a2230; }
      .row { display: flex; gap: 12px; flex-wrap: wrap; align-items: center; }
      .dots { text-align: center; margin-bottom: 26px; }
      .dot { display: inline-block; width: 9px; height: 9px; border-radius: 50%;
             background: #cfd6de; margin: 0 4px; }
      .dot.on { background: #2d6cdf; }
      .muted { color: #8893a0; font-size: .9em; }
    </style></head>
    <body>
      <div class="dots">
        <span class="dot" data-d="0"></span>
        <span class="dot" data-d="1"></span>
        <span class="dot" data-d="2"></span>
      </div>

      <div class="step" data-step="0">
        <div class="card">
          <h1>Welcome to Keephaven</h1>
          <p>Your private cloud is ready to set up. This takes about a minute.</p>
          <p class="muted">Your photos, movies, music and files live here on your
             own device &mdash; not in someone else's cloud.</p>
          <button onclick="go(1)">Get started</button>
          <p class="muted" style="margin-top:30px;font-size:.78em;opacity:.7">
             Setting up a second Keephaven as a backup?
             <a href="#" onclick="go(3);return false">Tap here</a>.</p>
        </div>
      </div>

      <div class="step" data-step="1">
        <div class="card">
          <h2>One thing to know</h2>
          <p>You can reach your Keephaven from anywhere &mdash; not just at home.</p>
          <p class="muted">When you want that, open <b>Settings</b> from your
             dashboard and turn on remote access. No rush; everything works at
             home right now.</p>
          <button onclick="show(2)">Continue</button>
        </div>
      </div>

      <div class="step" data-step="2">
        <div class="card">
          <h2>All set!</h2>
          <p>That's everything. When you tap Finish, Keephaven will start up and
             your dashboard will be ready in about a minute.</p>
          <button onclick="finish()">Finish</button>
        </div>
      </div>

      <div class="step" data-step="3">
        <div class="card">
          <h2>Set up as a backup</h2>
          <p>This Keephaven will hold a <b>copy</b> of another one.</p>
          <p class="muted">Its own apps stay switched off, so there is nothing to
             open on this box. Anything already stored on it is left alone &mdash;
             nothing is deleted.</p>
          <p class="muted">Afterwards, pair it from your <b>main</b> Keephaven, and
             turn on remote access on both boxes so they can find each other.</p>
          <button onclick="finishBackup()">Set up as a backup</button>
          <p class="muted" style="margin-top:14px;font-size:.9em">
             <a href="#" onclick="go(0);return false">No &mdash; this is my main Keephaven</a></p>
        </div>
      </div>

      <script>
        var state = {};
        function show(n) {
          document.querySelectorAll(".step").forEach(function(s) {
            s.classList.toggle("active", +s.dataset.step === n);
          });
          document.querySelectorAll(".dot").forEach(function(d) {
            d.classList.toggle("on", +d.dataset.d === n);
          });
        }
        function go(n) { show(n); }
        function finishBackup() {
          state.role = "backup";
          finish();
        }
        function finish() {
          fetch("/finish", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(state)
          }).then(function() {
            document.body.innerHTML =
              "<div class='card' style='text-align:center'>" +
              "<div class='spin'></div>" +
              "<h1>Initializing your cloud</h1>" +
              "<p id='msg'>Starting your private services&hellip;</p>" +
              "<p class='muted' id='hint'>This can take a couple of minutes. Keep this page open &mdash; it continues on its own.</p></div>";
            var steps = ["Starting your private services\u2026","Preparing photos, media and files\u2026","Securing your connection\u2026","Almost there\u2026"];
            var si = 0;
            setInterval(function(){ si=(si+1)%steps.length; var m=document.getElementById("msg"); if(m) m.innerHTML=steps[si]; }, 6000);
            var dash = "/";
            var tries = 0;
            var done = false;
            function probe() {
              if (done) return;
              tries++;
              fetch(dash + "?_=" + Date.now(), { mode: "no-cors", cache: "no-store" })
                .then(function() {
                  if (!done) { done = true; window.location.href = dash; }
                })
                .catch(function() { /* still rebooting; keep waiting */ });
              if (tries === 18) {
                document.getElementById("hint").innerHTML =
                  "Still reconnecting&hellip; if nothing happens in a moment, reconnect to the " +
                  "<b>__KH_SSID__</b> Wi-Fi and open <b>http://192.168.50.1</b>";
              }
            }
            setTimeout(function(){ probe(); setInterval(probe, 4000); }, 8000);
          });
        }
        show(0);
      </script>
    </body></html>"""

    DONE_PAGE = """<!DOCTYPE html>
    <html><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Keephaven</title>
    <style>.spin { width: 36px; height: 36px; margin: 0 auto 18px;
      border: 4px solid #e2e6ea; border-top-color: #4a90d9; border-radius: 50%;
      animation: spin 1s linear infinite; }
      @keyframes spin { to { transform: rotate(360deg); } }</style></head>
    <body style="font-family:sans-serif;text-align:center;padding:2em">
    <div class="spin"></div>
    <h1>Initializing your cloud</h1>
    <p>Preparing your dashboard&hellip;</p>
    <script>
      var dash = "/";
      var done = false;
      function probe() {
        if (done) return;
        fetch(dash + "?_=" + Date.now(), { mode: "no-cors", cache: "no-store" })
          .then(function(){ if(!done){ done=true; window.location.href=dash; } })
          .catch(function(){});
      }
      probe(); setInterval(probe, 3000);
    </script>
    </body></html>"""

    def kh_identity():
        # The per-unit suffix is the source of truth for both the AP SSID
        # (Keephaven-<suffix>) and the mDNS host (keephaven-<suffix>.local).
        # unit.env exists by the time the wizard is reachable (the AP is up,
        # which means unit-bootstrap already wrote it).
        suffix = ""
        try:
            with open(DATA_DIR + "/unit.env") as f:
                for line in f:
                    if line.startswith("UNIT_SUFFIX="):
                        suffix = line.split("=", 1)[1].strip()
                        break
        except Exception:
            pass
        if suffix:
            return ("keephaven-" + suffix, "Keephaven-" + suffix)
        return ("keephaven", "Keephaven")

    def render(page):
        host, ssid = kh_identity()
        return page.replace("__KH_HOST__", host).replace("__KH_SSID__", ssid)

    class Handler(http.server.BaseHTTPRequestHandler):
        # Robustness: a client that resets (RST) or stalls mid-request -- phone
        # captive-portal probes do this constantly -- must not surface as an
        # unhandled ConnectionResetError/BrokenPipeError/timeout out of the
        # handler. Give the socket a read timeout so a stalled read can't pin a
        # thread, and swallow connection errors + timeouts so the worker thread
        # just ends quietly. (ConnectionError covers reset + broken pipe.)
        timeout = 30

        def handle(self):
            try:
                super().handle()
            except (ConnectionError, TimeoutError):
                self.close_connection = True

        def _send(self, body, code=200, ctype="text/html; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.end_headers()
            self.wfile.write(body.encode())

        def do_GET(self):
            # If setup is already complete, NEVER show the wizard again. Serve a
            # self-contained "loading" page that polls the dashboard and
            # redirects once it is up. Guards against the wizard process being
            # briefly alive during the finalize transition (and manual refresh).
            if os.path.exists(SETUP_FLAG):
                self._send(DONE_PAGE)
                return
            # Serve the wizard for EVERY GET path (query strings included),
            # mirroring the dashboard's no-redirect behavior. The catch-all
            # 302 -> http://192.168.50.1/ that used to live here was the sole
            # HTTP-behavior asymmetry vs the (Chrome-working) dashboard and is
            # removed as the candidate fix for the Chrome-x-wizard failure
            # (cause unproven; see ideas-backlog "Open issues"). It only ever
            # served the abandoned captive auto-pop.
            self._send(render(PAGE))

        def do_POST(self):
            if self.path == "/finish":
                length = int(self.headers.get("Content-Length", 0))
                try:
                    state = json.loads(self.rfile.read(length).decode() or "{}")
                except Exception:
                    state = {}
                os.makedirs(DATA_DIR, exist_ok=True)
                # BACKUP FORK (Phase 3). Enable backup mode BEFORE the setup flag,
                # so cloudunit-finalize (which reads the marker) always sees a
                # settled answer. Failure is logged and the box continues as a
                # NORMAL Keephaven: a half-configured backup box would be worse
                # than one the owner has to convert again from Settings.
                if state.get("role") == "backup":
                    try:
                        r = subprocess.run(["${wrappers.backupModeEnable}"],
                                           capture_output=True, text=True, timeout=120)
                        if r.returncode != 0:
                            subprocess.run(["${pkgs.util-linux}/bin/logger", "-t", "cloudunit-wizard",
                                            "backup-mode enable FAILED rc=%d; continuing as a normal box"
                                            % r.returncode])
                        else:
                            subprocess.run(["${pkgs.util-linux}/bin/logger", "-t", "cloudunit-wizard",
                                            "set up as a BACKUP box"])
                    except Exception as e:
                        subprocess.run(["${pkgs.util-linux}/bin/logger", "-t", "cloudunit-wizard",
                                        "backup-mode enable ERROR (%s); continuing as a normal box" % e])
                with open(SETUP_FLAG, "w") as f:
                    f.write("setup complete\n")
                self._send("{\"ok\":true}", ctype="application/json")
                def _finalize():
                    time.sleep(3)
                    subprocess.Popen(["${pkgs.systemd}/bin/systemctl", "start",
                                      "--no-block", "cloudunit-finalize.service"])
                threading.Thread(target=_finalize, daemon=True).start()
            else:
                self._send(render(PAGE))

        def log_message(self, *args):
            pass

    # Threaded server: a single stalled client (e.g. an OS captive-portal probe
    # that opens a TCP connection and never sends a request line -- Android fires
    # several) must not wedge the whole wizard. The single-threaded TCPServer this
    # replaced blocked serve_forever on the first such connection, leaving the
    # wizard "listening" on :80 but unreachable to every other client. Mirrors the
    # dashboard's server (dashboard.nix), which already uses this exact pattern.
    class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True
    with Threaded(("", PORT), Handler) as httpd:
        httpd.serve_forever()
  '';
in
{
  systemd.services.cloudunit-wizard = {
    description = "Cloud Unit - First-boot setup wizard";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    unitConfig = {
      ConditionPathExists = "!${setupFlag}";
      RequiresMountsFor = dataDir;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${wizardApp}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };
}
