# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:
let
  targetStatusBin = config.cloudunit.wrappers.replicaTargetStatus;
  photosStatusBin = config.cloudunit.wrappers.photosSigninStatus;
  dataDir = "/var/lib/cloudunit";
  setupFlag = "${dataDir}/.setup-complete";
  # Post-setup dashboard. Serves a tile page on LAN port 80. Tiles start
  # disabled with a spinner and only become clickable once each service's
  # health check passes, so the user can never click into a half-started
  # service (which would show its raw setup screen). A progress bar shows how
  # many of the services are ready.
  dashboardApp = pkgs.writeText "cloudunit-dashboard.py" ''
    import http.server, socketserver, subprocess, json, os
    PORT = 80
    PAGE = """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1">
    <title>Keephaven</title>
    <style>
      :root { --ink:#1c2733; --muted:#5f6b78; --line:#e5eaf0; --bg:#f5f7fa; --card:#fff;
              --brand:#2d6cdf; --brand-dark:#1f52ad; --ok:#2a8a4a;
              --r:12px; --shadow:0 1px 3px rgba(16,24,32,.06),0 1px 2px rgba(16,24,32,.04); }
      * { box-sizing: border-box; }
      body { margin:0; font-family: system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
             color:var(--ink); background:var(--bg); padding-top:56px; line-height:1.5;
             -webkit-text-size-adjust:100%; }
      .topbar { position:fixed; top:0; left:0; right:0; height:56px; z-index:10;
                display:flex; align-items:center; justify-content:space-between;
                padding:0 16px; background:#fff; border-bottom:1px solid var(--line); }
      .brand { display:flex; align-items:center; gap:8px; font-weight:700; font-size:1.15rem;
               letter-spacing:-.01em; color:var(--ink); text-decoration:none; }
      .brandmark { width:12px; height:12px; border-radius:3px; background:var(--brand); }
      .tabs { display:flex; gap:6px; }
      .tab { display:inline-flex; align-items:center; gap:6px; padding:7px 12px;
             border-radius:999px; text-decoration:none; color:var(--muted);
             font-size:.9rem; font-weight:600; }
      .tab svg { width:16px; height:16px; }
      .tab.active { background:#eaf1fc; color:var(--brand); }
      .tab:hover { color:var(--brand); }
      .wrap { max-width:760px; margin:0 auto; padding:16px 16px 8px; }
      .hero { text-align:center; margin:6px 0 16px; }
      .hero h1 { font-size:1.6rem; margin:0; letter-spacing:-.01em; }
      .hero .sub { color:var(--muted); font-size:.98rem; margin-top:2px; }
      .progress-wrap { margin:0 auto 18px; max-width:520px; }
      .progress-text { text-align:center; color:var(--muted); font-size:.9rem; margin-bottom:8px; }
      .progress-bar { height:8px; background:#e2e6ea; border-radius:6px; overflow:hidden; }
      .progress-fill { height:100%; width:0%; background:var(--brand);
                       border-radius:6px; transition:width .4s ease; }
      .progress-wrap.done { opacity:0; transition:opacity .6s ease;
                            pointer-events:none; height:0; margin:0; }
      .grid { display:grid; grid-template-columns:repeat(2,1fr); gap:12px; }
      @media (min-width:620px) { .grid { grid-template-columns:repeat(auto-fill,minmax(150px,1fr)); } }
      .tile { display:flex; flex-direction:column; align-items:flex-start; gap:2px;
              padding:14px 15px; border-radius:var(--r); background:var(--card);
              border:1px solid var(--line); box-shadow:var(--shadow); text-decoration:none;
              color:var(--ink); position:relative; min-height:86px;
              transition:transform .12s, box-shadow .12s, opacity .3s; }
      .tile.ready { cursor:pointer; }
      .tile.ready:hover { transform:translateY(-1px); box-shadow:0 4px 12px rgba(16,24,32,.10); }
      .tile.starting { opacity:.6; cursor:default; }
      .tile .name { font-size:1.05rem; font-weight:600; }
      .tile .desc { color:var(--muted); font-size:.82rem; }
      .tile .status { font-size:.82rem; margin-top:auto; padding-top:8px; color:var(--muted);
                      display:flex; align-items:center; gap:6px; min-height:16px; }
      .spin { width:12px; height:12px; border:2px solid #ccd; border-top-color:var(--brand);
              border-radius:50%; display:inline-block; animation:spin .8s linear infinite; }
      @keyframes spin { to { transform:rotate(360deg); } }
      .tile.ready .status { color:var(--ok); font-weight:600; }
      .dot { width:8px; height:8px; border-radius:50%; background:var(--ok); display:inline-block; }
      .backup-notice { max-width:560px; margin:26px auto 8px; padding:16px 18px 0;
                       border-top:1px solid var(--line); color:#8893a0;
                       font-size:.85rem; line-height:1.5; text-align:center; }
      .upd { max-width:560px; margin:0 auto 18px; padding:12px 16px;
             border-radius:10px; font-size:.95rem; text-align:center; }
      .upd.avail { background:#eaf3ff; border:1px solid #cfe2fb; color:#235; }
      .upd.ok { color:#8893a0; font-size:.85rem; }
      .upd.err { color:#a06; font-size:.85rem; }
      .upd button { margin-left:10px; padding:6px 14px; border:0;
                    border-radius:6px; background:var(--brand); color:#fff;
                    font-size:.9rem; cursor:pointer; }
      .upd-note { color:#678; font-size:.8rem; margin-top:6px; }
      .tile .usage { font-size:.74rem; color:#8893a0; margin-top:5px; min-height:12px; line-height:1.35; }
      #freespace { max-width:560px; margin:2px auto 16px; text-align:center; color:#8893a0; font-size:.82rem; }
      #freespace.warn { background:#fff3f0; border:1px solid #f3c4b8; color:#a0341f;
                        padding:10px 14px; border-radius:9px; font-weight:600; font-size:.92rem; }
    </style></head>
    <body>
      <header class="topbar">
        <a class="brand" href="/"><span class="brandmark"></span>Keephaven</a>
        <nav class="tabs">
          <a class="tab active" href="/"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 11l9-8 9 8"/><path d="M5 10v9a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-9"/></svg><span>Home</span></a>
          <a class="tab" id="settings-link" href="#"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg><span>Settings</span></a>
        </nav>
      </header>
      <main class="wrap">
        <div class="hero"><h1>Keephaven</h1><div class="sub">Your private cloud</div></div>
        <div id="update-banner"></div>
        <div id="backup-banner"></div>
        <div id="promoted-banner"></div>
        <div class="progress-wrap" id="pwrap">
          <div class="progress-text" id="ptext">Setting up your cloud&hellip;</div>
          <div class="progress-bar"><div class="progress-fill" id="pfill"></div></div>
        </div>
        <div id="freespace"></div>
        <div class="grid" id="grid"></div>
        <div class="backup-notice">
          Keephaven is your private copy. Like any device, keep another copy too &mdash;
          leave originals on your phone or computer, or back up to a USB drive.
          Don't make Keephaven your only copy.
        </div>
      </main>
      <script>
        var host = window.location.hostname;
        var services = [
          { name: "Photos", desc: "Immich", port: 2283, health: "/api/server/ping", slow: true, key: "immich" },
          { name: "Movies", desc: "Jellyfin", port: 8096, health: "/System/Info/Public", key: "jellyfin" },
          { name: "Music", desc: "Navidrome", port: 4533, health: "/ping", key: "navidrome" },
          { name: "Audiobooks", desc: "AudioBookshelf", port: 13378, health: "/healthcheck", key: "audiobookshelf" },
          { name: "Books", desc: "Kavita", port: 5001, health: "/api/health", key: "kavita" },
          { name: "News", desc: "FreshRSS", port: 8081, health: "/", key: "freshrss" }
        ];
        var total = services.length;
        var readyCount = 0;
        var grid = document.getElementById("grid");
        var pfill = document.getElementById("pfill");
        var ptext = document.getElementById("ptext");
        var pwrap = document.getElementById("pwrap");

        function updateProgress() {
          var pct = Math.round((readyCount / total) * 100);
          pfill.style.width = pct + "%";
          if (readyCount >= total) {
            ptext.textContent = "All set";
            setTimeout(function(){ pwrap.classList.add("done"); }, 800);
          } else {
            ptext.innerHTML = "Setting up your cloud &mdash; " + readyCount +
              " of " + total + " ready";
          }
        }

        services.forEach(function(s) {
          var base = "http://" + host + ":" + s.port;
          var a = document.createElement("a");
          a.className = "tile starting";
          a.innerHTML = "<div class='name'>" + s.name + "</div>" +
                        "<div class='desc'>" + s.desc + "</div>" +
                        "<div class='status'><span class='spin'></span>Starting&hellip;</div>" +
                        "<div class='usage'></div>";
          a.addEventListener("click", function(e){
            if (!a.classList.contains("ready")) { e.preventDefault(); }
          });
          grid.appendChild(a);
          s._el = a;
          s._base = base;
          s._ready = false;
        });

        function markReady(s) {
          if (s._ready) return;
          s._ready = true;
          readyCount++;
          var a = s._el;
          a.href = s._base;
          a.classList.remove("starting");
          a.classList.add("ready");
          a.querySelector(".status").innerHTML = "<span class='dot'></span>Ready";
          updateProgress();
        }

        function probe(s) {
          if (s._ready) return;
          fetch(s._base + s.health + "?_=" + Date.now(),
                { mode: "no-cors", cache: "no-store" })
            .then(function(){ markReady(s); })
            .catch(function(){ /* not up yet */ });
        }

        function pollAll() {
          var anyPending = false;
          services.forEach(function(s){ if (!s._ready) { anyPending = true; probe(s); } });
          if (anyPending) setTimeout(pollAll, 3000);
        }

        updateProgress();
        pollAll();
        document.getElementById("settings-link").href = "http://" + host + ":8888";

        // ----- per-service storage + free space (reads cached /storage) -----
        function ago(iso){
          // normalize postgres "YYYY-MM-DD HH:MM:SS.ffffff+00" -> ISO UTC, no regex
          var s2 = String(iso).replace(" ","T").slice(0,19) + "Z";
          var t = Date.parse(s2); if(isNaN(t)){ return ""; }
          var s = Math.max(0, (Date.now() - t) / 1000);
          if(s < 3600){ return Math.round(s/60) + "m ago"; }
          if(s < 86400){ return Math.round(s/3600) + "h ago"; }
          return Math.round(s/86400) + "d ago";
        }
        function renderStorage(d){
          if(!d || !d.services){ return; }
          services.forEach(function(s){
            var u = d.services[s.key]; if(!u || !s._el){ return; }
            var el = s._el.querySelector(".usage"); if(!el){ return; }
            var t = u.size || "";
            if(s.key === "immich"){
              if(typeof u.count === "number"){ t += " · " + u.count.toLocaleString() + " photos"; }
              if(u.last_added){ var a = ago(u.last_added); if(a){ t += " · last added " + a; } }
            }
            el.textContent = t;
          });
          var fs = document.getElementById("freespace");
          if(fs && d.free){
            var pf = d.free.pct_free;
            if(typeof pf === "number" && pf < 10){
              fs.className = "freespace warn";
              fs.textContent = "Low storage: only " + (d.free.avail || "?") + " free (" + pf +
                "%). Remove some files, or move to a larger Keephaven.";
            } else {
              fs.className = "freespace";
              fs.textContent = (d.free.avail || "?") + " free of " + (d.free.total || "?");
            }
          }
        }
        function pollStorage(){
          fetch("/storage?_=" + Date.now(), { cache: "no-store" })
            .then(function(r){ return r.json(); }).then(renderStorage).catch(function(){});
          setTimeout(pollStorage, 60000);
        }
        pollStorage();

        // ----- U2 detect+notify: render the update status (same-origin) -----
        function escUpd(x){
          return String(x).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;");
        }
        function renderUpdate(s){
          var el = document.getElementById("update-banner");
          if(!el){ return; }
          if(s.state === "update-available"){
            el.innerHTML = "<div class='upd avail'>Update available: <b>" +
              escUpd(s.available) + "</b>" +
              "<button id='upd-install'>Install now</button></div>";
            var btn = document.getElementById("upd-install");
            if(btn){ btn.addEventListener("click", function(){
              btn.disabled = true; btn.textContent = "Starting…";
              fetch("/install", { method: "POST" }).catch(function(){});
            }); }
          } else if(s.state === "checking"){
            el.innerHTML = "<div class='upd ok'>Checking for updates&hellip;</div>";
          } else if(s.state === "downloading"){
            el.innerHTML = "<div class='upd avail'>Downloading update&hellip;</div>";
          } else if(s.state === "verifying"){
            el.innerHTML = "<div class='upd avail'>Verifying update&hellip;</div>";
          } else if(s.state === "staged-ok"){
            el.innerHTML = "<div class='upd avail'>Update verified and ready" +
              (s.available ? " (" + escUpd(s.available) + ")" : "") + ". " +
              "<a href='http://" + host + ":8888'>Open Settings to install</a>" +
              "<div class='upd-note'>Your photos and files are kept; it rolls back on its own if the update has a problem.</div></div>";
          } else if(s.state === "applying" || s.state === "rolling-back"){
            el.innerHTML = "<div class='upd avail'>Installing update&hellip; your Keephaven will restart. This can take a few minutes.</div>";
          } else if(s.state === "applied-ok"){
            el.innerHTML = "<div class='upd ok'>Update installed" +
              (s.current ? " (" + escUpd(s.current) + ")" : "") + ".</div>";
          } else if(s.state === "rolled-back"){
            el.innerHTML = "<div class='upd err'>An update didn't work and your Keephaven restored the previous version.</div>";
          } else if(s.state === "failed-verification"){
            el.innerHTML = "<div class='upd err'>This update could not be verified and was not installed.</div>";
          } else if(s.state === "held"){
            // Deliberately held before anything was touched: say so plainly, say
            // the box is fine, and give the one action that resolves it.
            el.innerHTML = "<div class='upd err'>We couldn't back up your photo " +
              "library, so this update was held. Your Keephaven is working normally " +
              "and nothing was changed. Please contact support@keephaven.co.</div>";
          } else if(s.state === "failed"){
            el.innerHTML = "<div class='upd err'>Update didn't complete" +
              (s.message ? ": " + escUpd(s.message) : "") + ".</div>";
          } else if(s.state === "up-to-date"){
            el.innerHTML = "<div class='upd ok'>Your Keephaven is up to date" +
              (s.current ? " (" + escUpd(s.current) + ")" : "") + "</div>";
          } else if(s.state === "error"){
            el.innerHTML = "<div class='upd err'>Couldn't check for updates right now.</div>";
          } else {
            el.innerHTML = "";
          }
        }
        function pollUpdate(){
        // ---- Phase 2: backup staleness. Never blocks anything; it only
        // reports. Wording escalates with age because a backup that quietly
        // stopped is the failure this product exists to prevent - and it is the
        // exact thing our own homepage mocks about DIY servers.
        function daysSince(iso){
          if(!iso) return null;
          var t = Date.parse(iso);
          if(isNaN(t)) return null;
          return Math.floor((Date.now() - t) / 86400000);
        }
        function renderBackup(s){
          var el = document.getElementById("backup-banner");
          if(!el) return;
          if(!s || s.state === "none"){ el.innerHTML = ""; return; }
          var d = daysSince(s.last_success);
          var cls = "ok", msg;
          if(s.state === "pending"){
            cls = "avail";
            msg = "Backup to your second Keephaven is waiting - turn on Remote access on both boxes.";
          } else if(s.state === "broken"){
            cls = "err";
            msg = "Backup to your second Keephaven is not set up correctly. Open Settings and pair the two boxes again.";
          } else if(d === null){
            cls = "avail";
            msg = "Backup to your second Keephaven hasn't completed yet.";
          } else if(d <= 1){
            cls = "ok";
            msg = "Backed up to your second Keephaven " + (d === 0 ? "today" : "yesterday") + ".";
          } else if(d <= 6){
            cls = "ok";
            msg = "Last backup to your second Keephaven: " + d + " days ago.";
          } else if(d <= 13){
            cls = "avail";
            msg = "No backup for " + d + " days. Check that your second Keephaven is powered on and connected.";
          } else {
            cls = "err";
            msg = "No backup for " + d + " days - your photos are on this box only. Check your second Keephaven.";
          }
          // A current failure is worth saying even while the last success is
          // recent: it is the early warning that the streak is about to break.
          if(s.state !== "ok" && s.state !== "pending" && s.state !== "broken" && s.message){
            msg += " (Last attempt: " + s.message + ".)";
            if(cls === "ok") cls = "avail";
          }
          el.innerHTML = "<div class='upd " + cls + "'>" + msg + "</div>";
        }
        // A promoted box has ONE copy. Say so every time they look, until they
        // pair a new second box - not once, and not quietly.
        function renderPromoted(d){
          var el = document.getElementById("promoted-banner");
          if(!el) return;
          if(!d || !d.promoted){ el.innerHTML = ""; return; }
          var from = d.promoted_from ? (" from keephaven-" + d.promoted_from) : "";
          var html = "<div class='upd err'>This is now your main Keephaven, restored" +
            from + ". <b>You no longer have a backup</b> \u2014 your photos are on this box " +
            "only. Add a second Keephaven and pair it to protect them again.</div>";
          // Said HERE too, because this is the screen the owner taps Photos from,
          // and Immich's own login screen cannot explain itself.
          if(d.photos_other_box){
            var src = d.promoted_from ? ("keephaven-" + d.promoted_from) : "your other Keephaven";
            html += "<div class='upd avail'><b>Opening Photos?</b> Use the password from " +
              src + "'s sticker \u2014 the photo library kept that box's sign-in. " +
              "Everything else uses this box's password. You can change it in " +
              "Settings \u2192 Photos sign-in.</div>";
          }
          el.innerHTML = html;
        }
        function pollPromoted(){
          fetch("/promoted?_=" + Date.now(), { cache: "no-store" })
            .then(function(r){ return r.json(); })
            .then(renderPromoted)
            .catch(function(){});
        }
        pollPromoted();
        setInterval(pollPromoted, 300000);

        function pollBackup(){
          fetch("/backup-status?_=" + Date.now(), { cache: "no-store" })
            .then(function(r){ return r.json(); })
            .then(renderBackup)
            .catch(function(){});
        }
        pollBackup();
        setInterval(pollBackup, 300000);

          fetch("/update-status?_=" + Date.now(), { cache: "no-store" })
            .then(function(r){ return r.json(); })
            .then(renderUpdate)
            .catch(function(){});
          setTimeout(pollUpdate, 15000);
        }
        pollUpdate();
      </script>
    </body></html>"""

    # ---- BACKUP-BOX VIEW (Phase 3) -------------------------------------------
    # A SEPARATE page, deliberately: it is served instead of the tile page only
    # when the backup-mode marker exists, and it shares nothing with PAGE above
    # -- its own markup, its own style block. The tile page every customer sees
    # is not restructured, not re-indented, not touched. A backup box is rare;
    # the main path is universal, and it has broken before.
    BACKUP_FLAG = "/var/lib/cloudunit/.backup-mode"

    BACKUP_PAGE = """<!DOCTYPE html>
    <html><head><meta charset="utf-8"><meta name="viewport"
    content="width=device-width, initial-scale=1"><title>Keephaven - Backup</title>
    <style>
      body {{ margin:0; font-family:system-ui,-apple-system,"Segoe UI",Roboto,sans-serif;
             background:#f5f7fa; color:#1c2733; line-height:1.5; }}
      .wrap {{ max-width:640px; margin:0 auto; padding:28px 16px 40px; }}
      h1 {{ font-size:1.5rem; margin:0 0 4px; }}
      .sub {{ color:#5f6b78; }}
      .card {{ background:#fff; border:1px solid #e5eaf0; border-radius:12px;
               padding:18px; margin-top:16px;
               box-shadow:0 1px 3px rgba(16,24,32,.06); }}
      .row {{ display:flex; justify-content:space-between; gap:12px; padding:6px 0; }}
      .row b {{ font-weight:600; }}
      .bar {{ height:10px; background:#eaeef3; border-radius:999px; overflow:hidden; margin-top:10px; }}
      .bar i {{ display:block; height:100%; background:#2d6cdf; width:0; }}
      .warn {{ background:#fff8ee; border-color:#f0d9b5; }}
      .err  {{ background:#fdecec; border-color:#f2c2c2; }}
      .note {{ color:#5f6b78; font-size:.92rem; margin-top:14px; }}
      a {{ color:#2d6cdf; }}
    </style></head>
    <body><div class="wrap">
      <h1>This Keephaven is a backup</h1>
      <p class="sub">It holds a copy of another Keephaven. Its own apps are switched
         off on purpose, so there is nothing to open here.</p>
      <div class="card" id="c">
        <div class="sub">Checking&hellip;</div>
      </div>
      <p class="note">Anything that was already on this box has been left alone &mdash;
         nothing was deleted. This box also keeps itself up to date on its own, so you
         do not need to do anything.</p>
      <p class="note"><a href="http://{host}:8888">Open Settings</a></p>
    </div>
    <script>
      function esc(x){{ return String(x==null?"":x).replace(/[<>&"]/g,
        function(c){{ return {{"<":"&lt;",">":"&gt;","&":"&amp;","\"":"&quot;"}}[c]; }}); }}
      function row(k,v){{ return "<div class='row'><span>"+esc(k)+"</span><b>"+esc(v)+"</b></div>"; }}
      function render(d){{
        var el = document.getElementById("c");
        if(!d || !d.paired){{
          el.className = "card warn";
          el.innerHTML = "<b>Not paired yet.</b><div class='sub'>Pair this box from your "
            + "main Keephaven to start receiving backups.</div>";
          return;
        }}
        var pct = parseInt(d.diskpct,10);
        var cls = "card", msg = "";
        if(!isNaN(pct) && pct >= 95){{ cls = "card err";
          msg = "<div class='sub'><b>This box is nearly full.</b> New backups are being "
              + "refused until there is room. Contact support@keephaven.co.</div>"; }}
        else if(!isNaN(pct) && pct >= 85){{ cls = "card warn";
          msg = "<div class='sub'>Storage is filling up. It is worth checking in on this.</div>"; }}
        el.className = cls;
        el.innerHTML =
            row("Backing up", "keephaven-" + d.peer)
          + row("Last backup received", d.newest === "none" ? "none yet" : d.newest)
          + row("Database copies held", d.dumps)
          + row("From version", d.source_version)
          + row("Space used", d.used)
          + row("Space free", d.free)
          + "<div class='bar'><i style='width:" + (isNaN(pct)?0:pct) + "%'></i></div>"
          + msg;
      }}
      function poll(){{
        fetch("/backup-box?_=" + Date.now(), {{cache:"no-store"}})
          .then(function(r){{ return r.json(); }}).then(render).catch(function(){{}});
      }}
      poll(); setInterval(poll, 60000);
    </script>
    </body></html>"""

    class Handler(http.server.BaseHTTPRequestHandler):
        timeout = 15

        def handle(self):
            try:
                super().handle()
            except (ConnectionError, TimeoutError):
                self.close_connection = True

        def do_GET(self):
            if self.path.split("?", 1)[0] == "/update-status":
                try:
                    with open("/var/lib/cloudunit/update/status.json", "rb") as f:
                        body = f.read(8192)
                except OSError:
                    body = b'{"state":"unknown"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.split("?", 1)[0] == "/backup-status":
                # Phase 2 staleness source. Absent file = this box is not a
                # primary in a pairing, and the card renders nothing at all.
                try:
                    with open("/var/lib/cloudunit/replication/sync-status.json", "rb") as f:
                        body = f.read(4096)
                except OSError:
                    body = b'{"state":"none"}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.split("?", 1)[0] == "/promoted":
                # Down-to-one-copy notice (decisions.md 2026-08-06). PERSISTENT,
                # not a toast: the owner reaches this screen having just survived
                # losing a box, sees their photos, and will otherwise assume they
                # are still protected. It clears only when a new pairing exists.
                d = {"promoted": False}
                try:
                    if os.path.exists("/var/lib/cloudunit/replication/.promoted") \
                       and not os.path.exists("/var/lib/cloudunit/replication/pair.env"):
                        d = {"promoted": True}
                        with open("/var/lib/cloudunit/replication/.promoted") as f:
                            for line in f:
                                if "=" in line:
                                    k, v = line.strip().split("=", 1)
                                    d[k] = v
                        # Photos wants the SOURCE box's password until the owner
                        # changes it. Carried on this existing poll rather than a
                        # new endpoint. Only "other-box" is reported, so a box
                        # still starting up ("unknown") never shows a scare.
                        try:
                            pr = subprocess.run(["${photosStatusBin}"], capture_output=True,
                                                text=True, timeout=20)
                            d["photos_other_box"] = ((pr.stdout or "").strip() == "other-box")
                        except Exception:
                            d["photos_other_box"] = False
                except Exception:
                    pass
                body = json.dumps(d).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.split("?", 1)[0] == "/backup-box":
                # Backup-box summary. The dashboard runs as root, but this still
                # goes through the shared wrapper so the parsing lives in ONE
                # place (replication-target.nix) rather than being reimplemented.
                d = {"paired": False}
                try:
                    r = subprocess.run(["${targetStatusBin}"], capture_output=True,
                                       text=True, timeout=15)
                    out = (r.stdout or "").strip()
                    if out.startswith("target "):
                        d = {"paired": True}
                        for tok in out.split()[1:]:
                            if "=" in tok:
                                k, v = tok.split("=", 1)
                                d[k] = v
                except Exception:
                    pass
                body = json.dumps(d).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            if self.path.split("?", 1)[0] == "/storage":
                try:
                    with open("/var/lib/cloudunit/storage.json", "rb") as f:
                        body = f.read(16384)
                except OSError:
                    body = b'{}'
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            # Backup box? Serve the OTHER page. One branch, at the last possible
            # moment, so every non-backup box reaches the identical code below.
            if os.path.exists(BACKUP_FLAG):
                bp = BACKUP_PAGE.format(host=(self.headers.get("Host") or "").split(":")[0])
                body = bp.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(PAGE.encode())
        def do_POST(self):
            # "Install now" -> kick the (privileged, no-arg, fixed) staging unit.
            # No user input flows into the command. U3 = download/verify/stage only;
            # NO reflash. The signature gate inside the unit is what protects against
            # malicious images regardless of who can POST here on the LAN.
            if self.path.split("?", 1)[0] == "/install":
                try:
                    n = int(self.headers.get("Content-Length", 0) or 0)
                    if n:
                        self.rfile.read(n)
                except Exception:
                    pass
                try:
                    subprocess.run(["systemctl", "start", "--no-block",
                                    "cloudunit-update-stage.service"],
                                   timeout=10, stdout=subprocess.DEVNULL,
                                   stderr=subprocess.DEVNULL)
                    code, body = 202, b'{"ok":true}'
                except Exception:
                    code, body = 500, b'{"ok":false}'
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)
                return
            self.send_response(404)
            self.end_headers()
        def log_message(self, *args):
            pass
    class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True
    with Threaded(("", PORT), Handler) as httpd:
        httpd.serve_forever()
  '';

  # Cached storage report: read-only du/df/DB, written to storage.json on a timer.
  # The dashboard's /storage endpoint just reads this file (like /update-status),
  # so page render never waits on du. Runs as root (no wrapper needed).
  storageReport = pkgs.writeShellScript "cloudunit-storage-report" ''
    set -u
    co=${pkgs.coreutils}/bin
    awk=${pkgs.gawk}/bin/awk
    jq=${pkgs.jq}/bin/jq
    docker=${pkgs.docker}/bin/docker
    D=${dataDir}
    sz() { $co/du -sh "$D/$1" 2>/dev/null | $co/cut -f1; }
    dfline=$($co/df -h --output=size,avail,pcent "$D" 2>/dev/null | $co/tail -1)
    TOTAL=$(printf '%s' "$dfline" | $awk '{print $1}')
    AVAIL=$(printf '%s' "$dfline" | $awk '{print $2}')
    PCTFREE=$(printf '%s' "$dfline" | $awk '{gsub(/%/,"",$3); print (100-$3)+0}')
    CNT=$($docker exec immich_postgres psql -U postgres -d immich -tAc "select count(*) from asset" 2>/dev/null | $co/tr -cd '0-9')
    LA=$($docker exec immich_postgres psql -U postgres -d immich -tAc 'select max("createdAt") from asset' 2>/dev/null | $co/tr -d '\n')
    tmp=$($co/mktemp)
    $jq -n \
      --arg gen "$($co/date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg total "$TOTAL" --arg avail "$AVAIL" --argjson pctfree "''${PCTFREE:-0}" \
      --arg immich "$(sz immich)" --arg cnt "''${CNT:-}" --arg la "''${LA:-}" \
      --arg jellyfin "$(sz jellyfin)" --arg navidrome "$(sz navidrome)" \
      --arg abs "$(sz audiobookshelf)" --arg kavita "$(sz kavita)" --arg freshrss "$(sz freshrss)" \
      '{generated:$gen, free:{total:$total, avail:$avail, pct_free:$pctfree},
        services:{
          immich: ({size:$immich}
                   + (if $cnt=="" then {} else {count:($cnt|tonumber)} end)
                   + (if $la=="" then {} else {last_added:$la} end)),
          jellyfin:{size:$jellyfin}, navidrome:{size:$navidrome},
          audiobookshelf:{size:$abs}, kavita:{size:$kavita}, freshrss:{size:$freshrss}
        }}' > "$tmp" 2>/dev/null && $co/mv "$tmp" "$D/storage.json" || $co/rm -f "$tmp"
  '';
in
{
  systemd.services.cloudunit-dashboard = {
    description = "Cloud Unit - Service dashboard";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    # systemctl on PATH for the "Install now" -> start staging unit trigger.
    path = [ pkgs.systemd ];
    unitConfig = {
      ConditionPathExists = "${setupFlag}";
      RequiresMountsFor = dataDir;
    };
    serviceConfig = {
      Type = "simple";
      ExecStart = "${pkgs.python3}/bin/python3 ${dashboardApp}";
      Restart = "on-failure";
      RestartSec = "5s";
    };
  };

  systemd.services.cloudunit-storage-report = {
    description = "Cloud Unit - storage usage report (writes storage.json)";
    unitConfig = {
      ConditionPathExists = "${setupFlag}";
      RequiresMountsFor = dataDir;
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${storageReport}";
    };
  };
  systemd.timers.cloudunit-storage-report = {
    description = "Cloud Unit - periodic storage report";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "20min";
      Persistent = true;
    };
  };
}
