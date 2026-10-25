# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Agent memory in two VMs: "box" runs the shipped module, "agent" is another machine on
# the network using the API.
#
#   nix build .#checks.x86_64-linux.agent-memory -L --accept-flake-config
#
# Proves, on a real kernel under systemd: the service runs as kh-memory and can't read
# the box's root-only secrets; Settings' user (cloudunit-web) reaches the owner commands
# only through the sudo wrapper, which refuses bad names; ownership after add lets the
# service write; the port is open to the network; an agent writes, reads, journals and
# searches its own folder; revoke cuts it off at once; delete removes its files; files
# survive a service restart.
#
# WHAT IT DOES NOT PROVE: anything on a Pi 5 (aarch64, the real data partition on NVMe),
# the Settings page itself (its Python is compile-checked separately), or the box-to-box
# backup of the memory folder. Those are the hardware gate.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "agent-memory";

  nodes = {
    box = { pkgs, ... }: {
      imports = [ ../modules/agent-memory.nix ];
      keephaven.agentMemory.enable = true;
      # Stands in for the data partition mount (disk-layout.nix).
      systemd.tmpfiles.rules = [
        "d /var/lib/cloudunit 0755 root root -"
        "f /var/lib/cloudunit/unit.env 0600 root root - UNIT_PASSWORD=sticker-secret"
      ];
      # The settings app's identity and its one grant for this feature, as settings.nix declares them.
      users.users.cloudunit-web = { isSystemUser = true; group = "cloudunit-web"; };
      users.groups.cloudunit-web = { };
      security.sudo.extraRules = [{
        users = [ "cloudunit-web" ];
        commands = [{ command = "/run/current-system/sw/bin/keephaven-agent-memory-admin"; options = [ "NOPASSWD" ]; }];
      }];
      environment.systemPackages = [ pkgs.curl ];
    };
    agent = { pkgs, ... }: {
      environment.systemPackages = [ pkgs.curl pkgs.jq ];
    };
  };

  testScript = ''
    import json

    W = "sudo -u cloudunit-web sudo -n /run/current-system/sw/bin/keephaven-agent-memory-admin"
    URL = "http://box:8790"

    start_all()
    box.wait_for_unit("keephaven-agent-memory.service")
    box.wait_for_open_port(8790)

    with subtest("service identity and sandbox"):
        user = box.succeed("systemctl show -p User --value keephaven-agent-memory").strip()
        assert user == "kh-memory", user
        pid = box.succeed("systemctl show -p MainPID --value keephaven-agent-memory").strip()
        assert box.succeed(f"stat -c %U /proc/{pid}").strip() == "kh-memory"
        box.fail("sudo -u kh-memory cat /var/lib/cloudunit/unit.env")
        props = box.succeed("systemctl show keephaven-agent-memory -p ProtectSystem -p NoNewPrivileges -p CapabilityBoundingSet")
        assert "ProtectSystem=strict" in props and "NoNewPrivileges=yes" in props, props

    with subtest("health over the network, refusals without a token"):
        agent.wait_until_succeeds(f"curl -sf {URL}/v1/health")
        out = json.loads(agent.succeed(f"curl -s {URL}/v1/health"))
        assert out["ok"] is True
        code = agent.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {URL}/v1/me").strip()
        assert code == "401", code

    with subtest("owner adds an agent through the settings user's sudo grant"):
        box.fail("sudo -u cloudunit-web /run/current-system/sw/bin/agent-memory add --data /var/lib/cloudunit/agent-memory x")
        for bad in ["../evil", "'a;touch /tmp/pwned'", "UPPER", "a" * 40]:
            box.fail(f"{W} add {bad}")
        box.fail("test -e /tmp/pwned")
        token = box.succeed(f"{W} add scout 2").strip()
        assert token.startswith("khm_") and "\n" not in token, token
        ro = box.succeed(f"{W} add watcher 10 ro").strip()
        assert box.succeed("stat -c '%U:%G %a' /var/lib/cloudunit/agent-memory/agents.json").strip() == "root:kh-memory 640"
        assert box.succeed("stat -c '%U' /var/lib/cloudunit/agent-memory/agents/scout").strip() == "kh-memory"
        assert token not in box.succeed("cat /var/lib/cloudunit/agent-memory/agents.json")
        box.succeed("journalctl -t keephaven-agent-memory-admin | grep -q 'added agent scout'")

    H = f"-H 'Authorization: Bearer {token}'"
    with subtest("the agent writes, reads, journals and searches its own folder"):
        agent.succeed(f"curl -sf -X PUT {H} --data-binary 'my human builds Keephaven' {URL}/v1/files/people/human.md")
        assert agent.succeed(f"curl -sf {H} {URL}/v1/files/people/human.md") == "my human builds Keephaven"
        agent.succeed(f"curl -sf -X POST {H} -d '{{\"did\":\"booted on a real kernel\"}}' {URL}/v1/journal")
        j = json.loads(agent.succeed(f"curl -sf {H} {URL}/v1/journal"))
        assert j["entries"][-1]["entry"]["did"] == "booted on a real kernel", j
        s = json.loads(agent.succeed(f"curl -sf {H} '{URL}/v1/search?q=keephaven'"))
        assert s["hits"] and s["hits"][0]["path"] == "people/human.md", s
        jf = j["entries"][-1]
        code = agent.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X DELETE {H} {URL}/v1/files/journal/" + jf["ts"][:10] + ".jsonl").strip()
        assert code == "403", code
        me = json.loads(agent.succeed(f"curl -sf {H} {URL}/v1/me"))
        assert me["agent"] == "scout" and me["quota_bytes"] == 2 * 1024 * 1024, me
        code = agent.succeed(f"head -c 3000000 /dev/zero > /tmp/big; curl -s -o /dev/null -w '%{{http_code}}' -X PUT {H} --data-binary @/tmp/big {URL}/v1/files/big.bin").strip()
        assert code == "507", code
        code = agent.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' -X PUT -H 'Authorization: Bearer {ro}' --data-binary x {URL}/v1/files/x.md").strip()
        assert code == "403", code
        assert box.succeed("stat -c '%U' /var/lib/cloudunit/agent-memory/agents/scout/people/human.md").strip() == "kh-memory"

    with subtest("files survive a service restart"):
        box.succeed("systemctl restart keephaven-agent-memory")
        box.wait_for_open_port(8790)
        agent.wait_until_succeeds(f"curl -sf {H} {URL}/v1/files/people/human.md | grep -q Keephaven")

    with subtest("listing for Settings"):
        lst = json.loads(box.succeed(f"{W} list"))
        names = {a["name"]: a for a in lst}
        assert set(names) == {"scout", "watcher"} and names["scout"]["files"] >= 2, lst

    with subtest("revoke cuts it off at once, files stay; delete removes them"):
        box.succeed(f"{W} revoke scout")
        code = agent.succeed(f"curl -s -o /dev/null -w '%{{http_code}}' {H} {URL}/v1/me").strip()
        assert code == "401", code
        box.succeed("test -f /var/lib/cloudunit/agent-memory/agents/scout/people/human.md")
        box.succeed(f"{W} delete scout")
        box.fail("test -e /var/lib/cloudunit/agent-memory/agents/scout")
        assert "scout" not in box.succeed("cat /var/lib/cloudunit/agent-memory/agents.json")
  '';
}
