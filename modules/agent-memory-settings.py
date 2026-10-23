# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Settings > Agents. Spliced into the settings app (modules/settings.nix) ONLY when
# keephaven.agentMemory.enable is true; with it off, the settings app is byte-identical.
# Uses the settings app's own helpers: run, auth_check, auth_deny_msg, setup_done, html, json.
# Every owner action goes through the one sudo wrapper (@ADMIN@), which re-validates input.

AGENT_ADMIN = "@ADMIN@"
AGENT_PORT = @PORT@


def agents_list():
    r = run(["sudo", "-n", AGENT_ADMIN, "list"], timeout=20)
    if r is None or r.returncode != 0:
        return None
    try:
        return json.loads((r.stdout or "").strip() or "[]")
    except ValueError:
        return None


def _agent_size(n):
    n = int(n or 0)
    for unit in ("bytes", "KB", "MB", "GB"):
        if n < 1024 or unit == "GB":
            return (str(n) + " " + unit) if unit == "bytes" else ("%.1f %s" % (n, unit))
        n = n / 1024.0


PW_FIELD = ("<label>Your password (the one on the sticker always works)</label>"
            "<input name=\"auth\" type=\"password\" autocomplete=\"off\">")


def agents_card():
    if not setup_done():
        return ""
    agents = agents_list()
    if agents is None:
        rows = "<p class=\"sub\">Couldn't read the agent list just now. Restart your Keephaven if this stays.</p>"
    elif not agents:
        rows = "<p class=\"sub\">No agents yet. Nothing can use agent memory until you add one.</p>"
    else:
        rows = ""
        for a in agents:
            state = "revoked" if a.get("revoked") else ("read only" if a.get("read_only") else "active")
            last = (a.get("last_write") or "never")[:16].replace("T", " ")
            name = html.escape(a["name"])
            rows += ("<div class=\"card\" style=\"margin:10px 0\"><b>" + name + "</b> &middot; " + state
                     + "<div class=\"sub\">" + _agent_size(a.get("used_bytes")) + " of "
                     + str(a.get("quota_mb")) + " MB &middot; " + str(a.get("files")) + " files &middot; last write "
                     + html.escape(last) + "</div>"
                     + "<form method=\"POST\" action=\"/agents\"><input type=\"hidden\" name=\"name\" value=\"" + name + "\">"
                     + PW_FIELD
                     + ("" if a.get("revoked") else "<button type=\"submit\" name=\"do\" value=\"revoke\">Revoke</button> ")
                     + "<button type=\"submit\" name=\"do\" value=\"delete\" class=\"danger\">Delete its files</button>"
                     + "</form></div>")
    return ("<details class=\"section\"><summary>Agents</summary><div class=\"card\">"
            "<h2>AI agents</h2>"
            "<p class=\"sub\">An agent you add here gets its own folder on this Keephaven. It can read and write "
            "only that folder, and its journal can only be added to, never changed. Revoke stops it at once; its "
            "files stay until you delete them. If this box backs up to another, the agent's files go too.</p>"
            + rows +
            "<h2>Add an agent</h2>"
            "<form method=\"POST\" action=\"/agents\"><input type=\"hidden\" name=\"do\" value=\"add\">"
            "<label>Name (lowercase letters, digits, dashes)</label><input name=\"name\" maxlength=\"32\">"
            "<label>Size limit in MB</label><input name=\"quota\" value=\"1024\" inputmode=\"numeric\">"
            "<label class=\"appchk\"><input type=\"checkbox\" name=\"ro\" value=\"1\"> Read only</label>"
            + PW_FIELD +
            "<button type=\"submit\">Add agent</button></form></div></details>")


def agent_token_page(name, token, host):
    url = "http://" + host + ":" + str(AGENT_PORT)
    return """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Keephaven</title>
<style>
  body {{ font-family: sans-serif; max-width: 640px; margin: 40px auto; padding: 0 20px; line-height: 1.5; }}
  .pw {{ font-family: monospace; font-size: 1.05em; background: #f4f6f8; border: 1px solid #e2e6ea;
         border-radius: 10px; padding: 14px; margin: 12px 0; word-break: break-all; }}
  .warn {{ background: #fff8ee; border: 1px solid #f0d9b5; border-radius: 10px; padding: 14px; }}
  a {{ color: #2d6cdf; }}
</style></head><body>
<h1>{name} is added</h1>
<p>Give your agent these two values:</p>
<div class="pw">KEEPHAVEN_URL={url}<br>KEEPHAVEN_TOKEN={token}</div>
<div class="warn">This is the only time the token is shown. Keephaven keeps only a fingerprint of it.
If it's lost, revoke this agent and add it again.</div>
<p style="text-align:center"><a href="/">&#8592; Back to Settings</a></p>
</body></html>""".format(name=html.escape(name), url=html.escape(url), token=html.escape(token))


def agents_post(h, data):
    do = data.get("do", [""])[0]
    name = data.get("name", [""])[0].strip().lower()
    verdict = auth_check(data)
    if verdict != "ok":
        h._msg(auth_deny_msg(verdict, "Nothing was changed."))
        return
    if do == "add":
        quota = data.get("quota", ["1024"])[0].strip() or "1024"
        if not quota.isdigit() or not 1 <= int(quota) <= 1048576:
            h._msg("The size limit must be a whole number of MB. Nothing was changed.")
            return
        args = ["sudo", "-n", AGENT_ADMIN, "add", name, quota] + (["ro"] if data.get("ro") else [])
        r = run(args, timeout=30)
        if r is None or r.returncode != 0 or not (r.stdout or "").strip().startswith("khm_"):
            why = ((r.stderr if r is not None else "") or "").strip().replace("ERROR: ", "")
            h._msg("The agent was NOT added. " + (why or "Try again, or restart your Keephaven."))
            return
        host = (h.headers.get("Host") or "keephaven.local").split(":")[0]
        h._result(agent_token_page(name, r.stdout.strip(), host))
    elif do in ("revoke", "delete"):
        r = run(["sudo", "-n", AGENT_ADMIN, do, name], timeout=60)
        if r is None or r.returncode != 0:
            h._msg("That didn't work. Nothing was changed.")
        elif do == "revoke":
            h._msg(name + " can't reach its folder any more. Its files are still here.")
        else:
            h._msg(name + " and its files are deleted from this Keephaven.")
    else:
        h._msg("Nothing was changed.")
