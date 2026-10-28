# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Two Agent Memory edition boxes and a private Tailscale (headscale): "boxa" is the main box
# with an agent, "boxb" is set up as its backup. The real pairing wrappers pair them, the
# real nightly sync sends the backup, the real promote turns boxb into the main box, and the
# real factory reset (minus its final reboot) wipes it.
#
#   nix build .#checks.x86_64-linux.agentmem-backup-pair -L --accept-flake-config
#
# Asserts END STATE, not step output (verifier, 2026-10-24):
#   - after the sync: the agent's folder is in boxb's landing area, and boxb's newest-backup
#     time comes from apps-off.list, because an edition with no Immich sends no dump;
#   - in backup mode: 8790 refuses on boxb and the unit's condition is the reason;
#   - after promote: the files sit under /var/lib/cloudunit/agent-memory owned by kh-memory,
#     the agent's token from boxa works on boxb, /v1/health answers, the promoted marker
#     exists, and the done message was said;
#   - after factory reset: no agents/ folder and no agents.json.
#
# WHAT IT DOES NOT PROVE: real hardware, a real tailnet (headscale stands in for Tailscale's
# coordination server), the Settings pages that drive pairing and promote (their wrappers
# are what run here), a reboot, or the Pi build (this is the PC build: same modules, x86-64).
{ pkgs, productModules, switchable ? false }:
let
  tls-cert = pkgs.runCommand "headscale-test-cert" { buildInputs = [ pkgs.openssl ]; } ''
    openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes -out cert.pem -keyout key.pem \
      -subj '/CN=headscale' -addext "subjectAltName=DNS:headscale"
    mkdir -p $out && cp key.pem cert.pem $out
  '';
  box = name: { lib, ... }: {
    imports =
      builtins.filter (m: m != ../modules/disk-layout.nix) productModules
      ++ [
        # update.nix adds two hooks to the Pi image builder; give them somewhere to land.
        ({ lib, ... }: {
          options.sdImage = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = { }; };
        })
      ];
    config = {
      keephaven.platform = "pc";
      keephaven.edition = "agent-memory";
      keephaven.profile = "dev";
      # switchable = the Home box's owner switch (agentmem-switch-pair), on the same pair.
      keephaven.agentMemory.switchable = switchable;
      # Two boxes in one test: the driver names machines by hostname, and base.nix gives
      # every box the same one.
      networking.hostName = lib.mkForce name;
      systemd.tmpfiles.rules = [ "d /var/lib/cloudunit 0755 root root -" ];
      security.pki.certificateFiles = [ "${tls-cert}/cert.pem" ];
      environment.systemPackages = [ pkgs.jq pkgs.curl ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      # The receiver keeps 10 GiB free (replication.nix minFreeKiB); a smaller disk is refused as full.
      virtualisation.diskSize = 16 * 1024;
    };
  };
in
pkgs.testers.runNixOSTest {
  name = if switchable then "agentmem-switch-pair" else "agentmem-backup-pair";

  nodes = {
    boxa = box "boxa";
    boxb = box "boxb";
    headscale = {
      services.headscale = {
        enable = true;
        port = 8080;
        settings = {
          server_url = "https://headscale";
          ip_prefixes = [ "100.64.0.0/10" ];
          derp = {
            server = { enabled = true; region_id = 999; stun_listen_addr = "0.0.0.0:3478"; };
            urls = [ ];
          };
          dns = { base_domain = "tailnet"; override_local_dns = false; };
        };
      };
      services.nginx = {
        enable = true;
        virtualHosts.headscale = {
          addSSL = true;
          sslCertificate = "${tls-cert}/cert.pem";
          sslCertificateKey = "${tls-cert}/key.pem";
          locations."/" = { proxyPass = "http://127.0.0.1:8080"; proxyWebsockets = true; };
        };
      };
      networking.firewall.allowedTCPPorts = [ 80 443 ];
      networking.firewall.allowedUDPPorts = [ 3478 ];
      environment.systemPackages = [ pkgs.headscale ];
    };
  };

  testScript = { nodes, ... }:
    let
      w = n: nodes.${n}.cloudunit.wrappers;
      admin = n: nodes.${n}.keephaven.agentMemory.adminWrapper;
      set = n: nodes.${n}.keephaven.agentMemory.setWrapper;
    in ''
    import json

    SW = ${if switchable then "True" else "False"}

    D = "/var/lib/cloudunit"

    def suffix(m):
        return m.succeed("awk -F= '/^UNIT_SUFFIX=/{print $2; exit}' " + D + "/unit.env").strip()

    start_all()
    headscale.wait_for_unit("headscale")
    headscale.wait_for_open_port(443)
    # The CLI talks to headscale's own socket, which can lag the open port on a busy host.
    headscale.wait_until_succeeds("headscale users list", timeout=120)
    headscale.succeed("headscale users create keephaven")
    authkey = headscale.succeed("headscale preauthkeys -u 1 create --reusable").strip().splitlines()[-1]

    with subtest("both boxes boot as the Agent Memory edition and are set up"):
        for m in (boxa, boxb):
            m.wait_for_unit("multi-user.target", timeout=900)
            m.wait_until_succeeds("test -s " + D + "/unit.env", timeout=300)
            m.wait_until_succeeds("curl -sf http://localhost/ | grep -q 'Keephaven Setup'", timeout=300)
            assert m.succeed("docker ps -q 2>/dev/null | wc -l").strip() == "0"
        out = boxa.succeed("curl -s -X POST -H 'Content-Type: application/json' -d '{}' http://localhost/finish")
        assert json.loads(out).get("ok") is True, out
        out = boxb.succeed("curl -s -X POST -H 'Content-Type: application/json' -d '{\"role\":\"backup\"}' http://localhost/finish")
        assert json.loads(out).get("ok") is True, out
        boxb.wait_until_succeeds("test -f " + D + "/.backup-mode", timeout=120)
        if SW:
            # Off until the owner turns it on: the unit's condition is the reason, nothing listens.
            assert boxa.succeed("${set "boxa"} status").strip() == "off"
            boxa.succeed("systemctl start keephaven-agent-memory.service || true")
            assert boxa.succeed("systemctl show -p ConditionResult --value keephaven-agent-memory").strip() == "no"
            code = boxa.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost:8790/v1/health || true").strip()
            assert code == "000", code
            assert boxa.succeed("${set "boxa"} on").strip() == "ok"
            assert boxa.succeed("${set "boxa"} status").strip() == "on"
            boxa.succeed("test -f /var/lib/cloudunit/apps/agent-memory.on")
        boxa.wait_for_unit("keephaven-agent-memory.service")
        boxa.wait_for_open_port(8790)

    with subtest("in backup mode, agent memory is off and 8790 refuses on boxb"):
        boxb.succeed("systemctl start keephaven-agent-memory.service || true")
        assert boxb.succeed("systemctl show -p ConditionResult --value keephaven-agent-memory").strip() == "no"
        assert boxb.succeed("systemctl is-active keephaven-agent-memory || true").strip() == "inactive"
        code = boxb.succeed("curl -s -o /dev/null -w '%{http_code}' http://localhost:8790/v1/health || true").strip()
        assert code == "000", code
        if SW:
            assert boxb.succeed("${set "boxb"} status").strip() == "backup-mode"
            boxb.fail("${set "boxb"} on")
            boxb.succeed("test ! -e /var/lib/cloudunit/apps/agent-memory.on")

    with subtest("an agent on boxa writes a file and a journal entry"):
        token = boxa.succeed("${admin "boxa"} add scout").strip()
        assert token.startswith("khm_"), "no token"
        H = "-H 'Authorization: Bearer " + token + "'"
        boxa.succeed("curl -sf -X PUT " + H + " --data-binary 'kept across boxes' http://localhost:8790/v1/files/notes/pair.md")
        boxa.succeed("curl -sf -X POST " + H + " -d '{\"did\":\"wrote before the backup\"}' http://localhost:8790/v1/journal")
        if SW:
            # Off keeps every agent's files and token; on again, the same agent works.
            assert boxa.succeed("${set "boxa"} off").strip() == "ok"
            assert boxa.succeed("systemctl is-active keephaven-agent-memory || true").strip() == "inactive"
            boxa.succeed("test ! -e /var/lib/cloudunit/apps/agent-memory.on")
            boxa.succeed("test -f " + D + "/agent-memory/agents/scout/notes/pair.md")
            assert boxa.succeed("${set "boxa"} on").strip() == "ok"
            body = boxa.succeed("curl -sf " + H + " http://localhost:8790/v1/files/notes/pair.md")
            assert body == "kept across boxes", body

    with subtest("both boxes join the private tailnet"):
        for m, n in ((boxa, "boxa"), (boxb, "boxb")):
            m.succeed("touch /run/cloudunit-remote-access.requested")
            m.succeed("systemctl start tailscaled.service")
            m.wait_until_succeeds("tailscale status --json >/dev/null 2>&1", timeout=60)
            m.succeed("tailscale up --login-server https://headscale --auth-key " + authkey + " --hostname " + n)
        boxa.wait_until_succeeds("tailscale ping -c 1 boxb", timeout=120)

    with subtest("pairing with the real wrappers"):
        pub = boxa.succeed("${(w "boxa").pairInit}").strip()
        boxb.succeed("printf '%s\\n' '" + pub + "' | ${(w "boxb").pairAccept} " + suffix(boxa))
        nodeid = boxa.succeed("tailscale status --json | jq -r '.Peer[] | select(.HostName==\"boxb\") | .ID'").strip()
        assert nodeid, "boxb not in boxa's peer list"
        boxa.succeed("${(w "boxa").pairRecord} " + suffix(boxb) + " " + nodeid)

    with subtest("the nightly sync sends the agent's folder although there is no photo database"):
        boxa.succeed("systemctl start cloudunit-replica-sync.service")
        st = json.loads(boxa.succeed("cat " + D + "/replication/sync-status.json"))
        assert st.get("state") == "ok", st
        L = D + "/replication/landing"
        boxb.succeed("test -f " + L + "/agent-memory/agents/scout/notes/pair.md")
        boxb.succeed("test -f " + L + "/agent-memory/agents.json")
        boxb.succeed("test -f " + L + "/apps-off.list")
        if SW:
            assert "agent-memory.on" in boxb.succeed("cat " + L + "/apps-off.list").split(), "switch not in apps-off.list"
        assert boxb.succeed("find " + L + "/dump -name 'immich-*' | wc -l").strip() == "0"

    with subtest("boxb's newest backup is the time apps-off.list arrived"):
        status = boxb.succeed("${(w "boxb").replicaTargetStatus}").strip()
        want = boxb.succeed("date -u -r " + L + "/apps-off.list '+%Y-%m-%dT%H:%M:%SZ'").strip()
        assert ("newest=" + want) in status, status

    with subtest("promote: boxb becomes the main box with the agent's memory"):
        boxb.succeed("systemctl start cloudunit-promote.service")
        ps = json.loads(boxb.succeed("cat " + D + "/replication/promote-status.json"))
        assert ps.get("state") == "done", ps
        assert "Everything from your backup is here" in ps.get("message", ""), ps
        boxb.succeed("test -f " + D + "/replication/.promoted")
        boxb.succeed("test ! -f " + D + "/.backup-mode")
        if SW:
            # The takeover keeps the owner's choice: on there, on here.
            boxb.succeed("test -f /var/lib/cloudunit/apps/agent-memory.on")
            assert boxb.succeed("${set "boxb"} status").strip() == "on"
        owner = boxb.succeed("stat -c %U " + D + "/agent-memory/agents/scout/notes/pair.md").strip()
        assert owner == "kh-memory", owner
        boxb.wait_for_unit("keephaven-agent-memory.service")
        boxb.wait_for_open_port(8790)
        boxb.succeed("curl -sf http://localhost:8790/v1/health | grep -q '\"ok\": true'")
        H = "-H 'Authorization: Bearer " + token + "'"
        body = boxb.succeed("curl -sf " + H + " http://localhost:8790/v1/files/notes/pair.md")
        assert body == "kept across boxes", body
        j = json.loads(boxb.succeed("curl -sf " + H + " http://localhost:8790/v1/journal"))
        assert j["entries"][0]["entry"]["did"] == "wrote before the backup", j

    with subtest("factory reset leaves nothing of the agents behind"):
        boxb.succeed("sed 's/^\\$SYSTEMCTL reboot$/echo would-reboot/' \"$(command -v cloudunit-factory-reset)\" > /tmp/fr.sh")
        assert boxb.succeed("grep -c would-reboot /tmp/fr.sh").strip() == "1"
        boxb.succeed("bash /tmp/fr.sh")
        boxb.succeed("test ! -e " + D + "/agent-memory/agents")
        boxb.succeed("test ! -e " + D + "/agent-memory/agents.json")
        assert boxb.succeed("systemctl is-active keephaven-agent-memory || true").strip() != "active"
        if SW:
            boxb.succeed("test ! -e /var/lib/cloudunit/apps/agent-memory.on")
  '';
}
