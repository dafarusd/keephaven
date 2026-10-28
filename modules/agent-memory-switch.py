# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Settings > Agent memory: the owner's on/off switch. Spliced into the settings app
# (modules/settings.nix) ONLY when keephaven.agentMemory.switchable is true, AFTER the
# Agents code (agent-memory-settings.py), whose card and form it wraps: they work only
# while agent memory is on. With switchable off, the settings app is byte-identical.
# Every change goes through the one sudo wrapper (@SET@), which re-validates input.

AGENT_SET = "@SET@"


def memory_state():
    r = run(["sudo", "-n", AGENT_SET, "status"], timeout=10)
    if r is None or r.returncode != 0:
        return "unknown"
    return (r.stdout or "").strip() or "unknown"


def memory_card():
    if not setup_done():
        return ""
    st = memory_state()
    if st == "backup-mode":
        body = "<p class=\"sub\">This Keephaven is a backup box. Agent memory stays off until it takes over.</p>"
    elif st not in ("on", "off"):
        body = "<p class=\"sub\">Couldn't read whether agent memory is on just now. Restart your Keephaven if this stays.</p>"
    else:
        on = st == "on"
        body = ("<p class=\"sub\">Agent memory is <b>" + ("on" if on else "off") + "</b>. "
                + ("AI agents you add below can keep their memory on this Keephaven, on port "
                   + str(AGENT_PORT) + " of your home network."
                   if on else
                   "Turn it on to give AI agents a place on this Keephaven to keep their memory. "
                   "Nothing listens for them while it's off.")
                + "</p><form method=\"POST\" action=\"/agent-memory\">"
                + "<input type=\"hidden\" name=\"state\" value=\"" + ("off" if on else "on") + "\">"
                + PW_FIELD
                + "<button type=\"submit\">" + ("Turn agent memory off" if on else "Turn agent memory on") + "</button>"
                + "</form>"
                + ("<p class=\"sub\">Turning it off keeps every agent's files. Turn it on again and the same agents work.</p>"
                   if on else ""))
    return ("<details class=\"section\"><summary>Agent memory</summary><div class=\"card\">"
            "<h2>Agent memory</h2>" + body + "</div></details>")


_agents_card_any = agents_card
_agents_post_any = agents_post


def agents_card():
    return _agents_card_any() if memory_state() == "on" else ""


def agents_post(h, data):
    if memory_state() != "on":
        h._msg("Agent memory is off. Turn it on first. Nothing was changed.")
        return
    _agents_post_any(h, data)


def memory_post(h, data):
    verdict = auth_check(data)
    if verdict != "ok":
        h._msg(auth_deny_msg(verdict, "Nothing was changed."))
        return
    want = data.get("state", [""])[0]
    if want not in ("on", "off"):
        h._msg("Nothing was changed.")
        return
    r = run(["sudo", "-n", AGENT_SET, want], timeout=90)
    if r is None or r.returncode != 0:
        why = ((r.stderr if r is not None else "") or "").strip()
        h._msg("Agent memory was NOT turned " + want + ". " + (why[:1].upper() + why[1:] + "." if why else "Restart your Keephaven and try again."))
    elif want == "on":
        h._msg("Agent memory is on. Add an agent below to give it a folder and a key.")
    else:
        h._msg("Agent memory is off. Every agent's files are still here.")
