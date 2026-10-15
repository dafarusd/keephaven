# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Boots the PHOTOS edition as a PC (x86-64) in a VM and takes it through setup.
#
#   nix build .#checks.x86_64-linux.pc-photos -L --accept-flake-config
#   ls result/*.png
#
# Every product module is the shipped one, with keephaven.platform = "pc" and the
# amd64 app images. Left out: disk-layout.nix (the Pi image builder, the four
# partitions, recovery). The data partition is a plain folder on the VM's disk.
#
# WHAT IT DOES NOT PROVE: a UEFI boot from a real disk image, the partition
# layout, an actual update being applied, recovery, the Wi-Fi access point (the VM
# has no radio; hostapd and dnsmasq fail and retry), or anything about a real PC.
#
# It DOES now cover the update machinery short of applying: that the drive polls at
# all, that it does not wait for a clock it already has, that a version which rolled
# back is never offered again, that a staged candidate is not thrown away, and that
# the eight files the drive carries are present and say what they should. Those are
# the four things that went wrong on 2026-10-13 and the subtests are named after
# what they would have caught.
{ pkgs, productModules, launcherFiles }:
pkgs.testers.runNixOSTest {
  name = "pc-photos";

  nodes.box = { lib, ... }: {
    imports =
      builtins.filter (m: m != ../modules/disk-layout.nix) productModules
      ++ [
        # update.nix adds two hooks to the Pi image builder. There is no image
        # builder here yet; this gives those two definitions somewhere to land.
        ({ lib, ... }: {
          options.sdImage = lib.mkOption {
            type = lib.types.attrsOf lib.types.anything;
            default = { };
          };
        })
      ];

    config = {
      keephaven.platform = "pc";
      keephaven.edition = "photos";
      keephaven.profile = "dev";
      # This node is a BENCH drive. A drive a buyer gets ignores update.conf (p5 is writable
      # from Windows unprivileged - gate 4a), and without this the feed subtests below would
      # write update.conf, be ignored, and fail against the real vendor URL. What the SHIPPING
      # build does is checked separately and exactly by checks.x86_64-linux.ssd-no-url-override.
      keephaven.allowUpdateUrlOverride = true;

      # Stands in for the data partition mount (disk-layout.nix).
      systemd.tmpfiles.rules = [ "d /var/lib/cloudunit 0755 root root -" ];

      # The drive's Windows-visible files, readable inside the VM without a partition.
      virtualisation.additionalPaths = [ launcherFiles ];

      virtualisation.memorySize = 6144;
      virtualisation.cores = 4;
      virtualisation.diskSize = 30 * 1024;
    };
  };

  testScript = ''
    import json
    import re

    # The driver names a machine after its hostname, and base.nix sets that.
    box = keephaven

    start_all()

    with subtest("it is a PC build, on its own update feed"):
        box.wait_for_unit("multi-user.target", timeout=900)
        assert box.succeed("uname -m").strip() == "x86_64"
        url = box.succeed("cat /etc/cloudunit/update/url").strip()
        assert url == "https://updates.keephaven.co/pc/photos/", url
        print("version:", box.succeed("cat /etc/cloudunit/update/version").strip())

    with subtest("first boot: identity, and the setup screen on the console"):
        box.wait_for_unit("cloudunit-setup-screen.service")
        box.wait_until_succeeds("test -s /var/lib/cloudunit/unit.env")
        box.wait_until_tty_matches("7", "KEEPHAVEN SETUP", timeout=120)
        text = box.get_tty_text("7")
        pw = box.succeed("grep '^AP_PASSWORD=' /var/lib/cloudunit/ap.env | cut -d= -f2-").strip()
        assert pw and pw in text, "the setup password is not on the screen"
        # A VM: the page is on the computer that runs it. No Wi-Fi to join.
        assert "On this computer, open" in text and "http://localhost" in text, text
        assert "Wi-Fi" not in text and "192.168.50.1" not in text, text
        box.screenshot("1-setup-screen")
        title = box.wait_until_succeeds(
            "curl -sf http://localhost/ | grep -o '<title>[^<]*</title>'", timeout=300)
        assert "Keephaven Setup" in title, title
        page = box.succeed("curl -sf http://localhost/")
        assert "on this computer again" in page, "the setup page has no PC wording"
        assert "192.168.50.1" not in page and "__KH_SSID__</b> Wi-Fi" not in page, "the setup page still sends the owner to a Wi-Fi"

    with subtest("the four Photos containers come up from the baked amd64 images"):
        box.wait_until_succeeds(
            "[ \"$(docker ps --format '{{.Names}}' | grep -c '^immich')\" = 4 ]", timeout=1800)
        box.wait_until_succeeds(
            "curl -sf http://localhost:2283/api/server/ping | grep -q pong", timeout=900)
        print(box.succeed("docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'"))
        archs = box.succeed(
            "docker image inspect --format '{{.Architecture}}' $(docker images -q) | sort -u").split()
        assert archs == ["amd64"], archs

    with subtest("finish setup: the dashboard takes over and Immich is provisioned"):
        out = box.succeed(
            "curl -s -X POST -H 'Content-Type: application/json' -d '{}' http://localhost/finish")
        assert json.loads(out).get("ok") is True, out
        box.wait_until_succeeds(
            "curl -sf http://localhost/ | grep -q '<title>Keephaven</title>'", timeout=300)
        box.wait_until_succeeds(
            "curl -sf http://localhost:2283/api/server/config | grep -q '\"isInitialized\":true'",
            timeout=900)
        box.screenshot("2-after-setup")

    with subtest("no radio: the access point steps skip cleanly, nothing fails, the boot does not wait"):
        for unit in ("cloudunit-hostapd.service", "dnsmasq.service"):
            active = box.succeed(f"systemctl show -p ActiveState --value {unit}").strip()
            cond = box.succeed(f"systemctl show -p ConditionResult --value {unit}").strip()
            assert (active, cond) == ("inactive", "no"), (unit, active, cond)
        box.fail("ip link show wlan0")
        failed = box.succeed("systemctl --failed --no-legend --plain || true").strip()
        assert failed == "", "failed units:\n" + failed
        print(box.succeed("systemd-analyze || true; systemd-analyze critical-chain multi-user.target 2>/dev/null | head -14 || true"))

    with subtest("updates: the drive polls, and does not wait for a clock it already has"):
        # Both halves of 645194f, which is the morning of 2026-10-13 in two lines. The timer was
        # disabled for pc ("nothing is published for it and its install step isn't built") long
        # after both halves of that reason had expired, and the check also sat for ever behind
        # systemd-time-wait-sync, which never finishes on a drive because the docker bridges keep
        # restarting timesyncd. Between them a drive could never learn an update exists.
        # The OLD version of this subtest asserted the opposite and would have caught the fix as
        # a regression, which is exactly what it was for; it asserted the behaviour we shipped
        # away from, so it is gone.
        assert box.succeed("systemctl is-enabled cloudunit-update-check.timer").strip() == "enabled"
        box.succeed("systemctl is-active cloudunit-update-check.timer")
        # From the LIVE unit, not from the source: what the check waits on.
        wants = box.succeed("systemctl show -p Wants --value cloudunit-update-check.service").strip()
        after = box.succeed("systemctl show -p After --value cloudunit-update-check.service").strip()
        assert "network-online.target" in wants, wants
        assert "systemd-time-wait-sync" not in wants, "the drive is waiting for a clock it already has: " + wants
        assert "systemd-time-wait-sync" not in after, "the drive is ordered after a clock wait: " + after
        print("check wants:", wants, "| after:", after)
        # Proven above; now stop it, or OnBootSec=3min fires the REAL check against the baked
        # URL (unreachable here) and its "error" status lands in the middle of the subtests
        # below. is-enabled stays "enabled", which is what the polling proof rests on.
        box.succeed("systemctl stop cloudunit-update-check.timer")

    with subtest("updates: apply is the real thing, generated for a drive"):
        # 63f97f1 replaced the refusal with a real install step. The old subtest asserted the
        # refusal's words ("updates aren't built for the PC version yet") and would fail today.
        exe = box.succeed("systemctl show -p ExecStart --value cloudunit-update-apply.service").strip()
        assert "cloudunit-update-apply-arm-pc.py" in exe, exe
        # systemd prints ExecStart as "{ path=<python3> ; argv[]=<python3> <script> ; ... }",
        # so "the first word after path=" is the INTERPRETER. Take the .py itself.
        m = re.search(r"(/nix/store/\S+\.py)", exe)
        assert m, exe
        script = m.group(1)
        # python3 is NOT on the box's PATH - base.nix ships vim/git/htop/curl/wget/tmux and
        # every unit names ${pkgs.python3}/bin/python3 by store path. And py_compile writes
        # __pycache__ BESIDE the source, which is the read-only store, so compile a copy.
        box.succeed(f"cp {script} /tmp/apply.py")
        box.succeed("${pkgs.python3}/bin/python3 -m py_compile /tmp/apply.py")
        # The drive installs the one boot file the candidate carries; it does not rebuild a boot
        # folder, so nothing in its apply script may reach for device trees.
        box.fail(f"grep -q dtbs {script}")
        box.succeed(f"grep -q regen_default {script}")
        # The negative, with nothing staged: it must refuse for the RIGHT reason.
        box.succeed("mkdir -p /var/lib/cloudunit/update")
        box.fail("systemctl start cloudunit-update-apply.service")
        # fail() in update.nix writes the reason to status.json and prints nothing, so the
        # journal is the wrong place to look - the owner's page is the right one.
        st = json.loads(box.succeed("cat /var/lib/cloudunit/update/status.json"))
        assert st.get("state") == "failed", st
        assert "no staged update to apply" in st.get("message", ""), st
        box.succeed("systemctl reset-failed cloudunit-update-apply.service || true")

    with subtest("updates: a version that rolled back on this unit is never offered again"):
        # 34b48aa and ed5ce06. Without this the daily check overwrites the rolled-back status
        # with update-available for the very image that failed, the dashboard offers Install now,
        # and the owner loops: install, three failed boots, rollback, offered again tomorrow.
        feed = "/var/lib/kh-test-feed"
        box.succeed(f"mkdir -p {feed}")

        def serve(version):
            # A COMPLETE manifest: the check validates the version and the stage step needs the
            # other four fields, so a two-field stub would prove less than it looks.
            m = {
                "version": version,
                "image_url": f"candidate-{version}.img.zst",
                "image_sig_url": f"candidate-{version}.img.minisig",
                "image_sha256": "0" * 64,
                "image_size_compressed": 1024,
            }
            box.succeed("printf %s " + f"'{json.dumps(m)}' > {feed}/manifest.json")

        # systemd-run, not `... &`: a backgrounded child inherits the driver's stdin and
        # `succeed` waits for every fd to close, so the shell form hangs for ever. Seen on
        # run 3, which sat on that line until it was killed.
        box.succeed(
            "systemd-run --unit=kh-test-feed --collect "
            f"--property=WorkingDirectory={feed} "
            "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1")
        box.wait_until_succeeds("curl -sf http://127.0.0.1:8099/ >/dev/null", timeout=60)
        box.succeed("printf 'UPDATE_BASE_URL=http://127.0.0.1:8099/\\n' > /var/lib/cloudunit/update.conf")
        box.succeed("mkdir -p /var/lib/cloudunit/update")
        cur = box.succeed("cat /etc/cloudunit/update/version").strip()

        def check_state(expect, note):
            # systemd's default start rate limit is 5 in 10 s and this subtest and the next one
            # start the check eight times between them: without the reset, the later ones fail
            # with "Start request repeated too quickly" and prove nothing about the check.
            box.succeed("systemctl reset-failed cloudunit-update-check.service || true")
            box.succeed("systemctl start cloudunit-update-check.service")
            st = json.loads(box.succeed("cat /var/lib/cloudunit/update/status.json"))
            assert st.get("state") == expect, (note, st)
            return st

        serve("2999.01.02")
        box.succeed("rm -f /var/lib/cloudunit/update/rolled-back-versions /var/lib/cloudunit/update/status.json")
        check_state("update-available", "a newer version with nothing recorded")

        box.succeed("printf '2999.01.02\\n' > /var/lib/cloudunit/update/rolled-back-versions")
        st = check_state("rolled-back", "the version that rolled back must not be offered")
        assert st.get("available") == "2999.01.02", st
        assert "did not work and was undone" in st.get("message", ""), st

        serve("2999.01.03")
        check_state("update-available", "a NEWER version clears the hold by itself")

        # Fail closed: an unreadable list counts as listed. chmod 000 proves nothing here -
        # every cloudunit-update-* unit runs as root and root reads a mode-000 file, so the
        # refusal would come from the ordinary listed branch. A DIRECTORY is what open() cannot
        # read for anyone: IsADirectoryError is an OSError, which is the fail-closed branch. It
        # is empty, so "listed" cannot explain the result.
        serve("2999.01.02")
        box.succeed("rm -f /var/lib/cloudunit/update/rolled-back-versions")
        box.succeed("mkdir /var/lib/cloudunit/update/rolled-back-versions")
        check_state("rolled-back", "an unreadable list must fail CLOSED")
        box.succeed("rmdir /var/lib/cloudunit/update/rolled-back-versions")

    with subtest("updates: a staged candidate is not thrown away, but a later version still lands"):
        # The verifier's case E, found by running the generated script rather than reading it:
        # putting staged-ok in the early guard made the check return before the fetch, so a drive
        # with something staged would never hear about a later version.
        box.succeed("rm -f /var/lib/cloudunit/update/rolled-back-versions")

        def set_status(state, avail):
            box.succeed("printf %s " + f"'{json.dumps({'state': state, 'current': cur, 'available': avail})}'"
                        + " > /var/lib/cloudunit/update/status.json")

        serve("2999.01.02")
        set_status("staged-ok", "2999.01.02")
        st = check_state("staged-ok", "the manifest still offers what is staged: keep it")
        assert st.get("available") == "2999.01.02", st

        serve("2999.01.03")
        set_status("staged-ok", "2999.01.02")
        st = check_state("update-available", "a LATER version must be seen (case E)")
        assert st.get("available") == "2999.01.03", st

        serve("2000.01.01")
        set_status("staged-ok", "2999.01.02")
        st = check_state("up-to-date", "a feed OLDER than the running version")
        assert "available" not in st, st

        serve("2999.01.03")
        box.succeed("rm -f /var/lib/cloudunit/update/status.json")
        check_state("update-available", "no status at all behaves as before")

    with subtest("the drive carries eight files, plain ASCII, naming the source an owner can fetch"):
        # Read from the build that makes them, since this VM has no partitions. On a real drive
        # these sit at the ROOT, never under qemu\\: the helper refuses the drive if that folder
        # holds one file more than the sealed list it was built with.
        files = "${launcherFiles}"
        want = ["README.txt", "LICENCE.txt", "THIRD-PARTY.txt", "QEMU-SOURCE.txt",
                "QEMU-LICENCE.txt", "qemu-win32-hdev-fixed-length.patch",
                "qemu-build-recipe.nix", "qemu-build-flake.lock"]
        for f in want:
            n = int(box.succeed(f"stat -c %s {files}/{f}").strip())
            assert n > 0, f
            print(f"{f}: {n} bytes")
        # Windows draws a UTF-8 dash as two wrong characters, and these are the first thing a
        # stranger reads.
        box.fail(f"LC_ALL=C grep -qn '[^[:print:][:space:]]' {files}/*.txt")
        src = box.succeed(f"cat {files}/QEMU-SOURCE.txt")
        assert "General Public License version 2" in src, src
        assert "three years" in src, src
        # Every edition is AGPL-3.0-only (his decision, 2026-10-15, reversing 2026-10-13's
        # proprietary call: nobody was running the boxes and he needs real users). So the
        # drive's own text must say its code is free software, name the public repo and the
        # commit it was built from, and carry no proprietary or all-rights-reserved line.
        assert "not free software" not in src, "the drive still calls its own code closed"
        assert "all rights reserved" not in src.lower(), src
        assert "GNU Affero General Public License version 3" in src, src
        assert "github.com/dafarusd/keephaven" in src, src
        assert "THIRD-PARTY.txt" in src, src
        # The tag is what an owner can actually fetch: a commit id from the private tree
        # 404s on the public repo, so the text names the tag AND the build id.
        assert "${launcherFiles.publicTag}" in src, src
        lic = box.succeed(f"cat {files}/LICENCE.txt")
        assert "GNU AFFERO GENERAL PUBLIC LICENSE" in lic, lic[:200]
        assert "Version 3, 19 November 2007" in lic, lic[:200]
        assert "All rights reserved" not in lic, "a proprietary line survived the drive's licence"
        print(box.succeed(f"ls -l {files}/ | tail -9"))

    with subtest("no login prompt on the serial line"):
        assert box.succeed("systemctl is-enabled serial-getty@ttyS0.service || true").strip() in ("masked", "disabled", "masked-runtime"), "a login prompt is on the serial line"

    with subtest("what the box reports about itself (printed)"):
        print(box.succeed("curl -s http://localhost:8888/health-report | sed -e 's/<[^>]*>//g' | grep -v '^$' | head -40"))
        print(box.succeed("free -m | head -2; df -h / | tail -1"))
        box.succeed("fgconsole >/dev/null; chvt 7 || true")
        box.wait_until_tty_matches("7", "Keephaven is set up", timeout=120)
        assert "http://localhost" in box.get_tty_text("7")
        box.screenshot("3-screen-after-setup")
  '';
}
