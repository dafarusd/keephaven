# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Boots the setup screen in a VM and reads the screen back.
#
#   nix build .#checks.x86_64-linux.setup-screen -L --accept-flake-config
#   ls result/*.png        # what the screen looked like at each step
#
# The identity (credentials.nix), the Wi-Fi config seeding (ap.nix) and the screen
# (setup-screen.nix) are the shipped modules, unmodified, and the unit runs as root
# under systemd against root:600 files -- so this exercises privilege, the virtual
# terminal and the font logic on a real kernel of the same series as the box's.
#
# WHAT IT DOES NOT PROVE: anything about the Pi 5's HDMI output. The VM's display
# is QEMU's, not vc4. Whether a TV shows the console at all, and whether the text
# reads from a couch, is the hardware gate.
#
# hostapd and dnsmasq from ap.nix fail and retry here (the VM has no wlan0). That
# noise is expected and nothing below depends on them.
{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "setup-screen";

  nodes =
    let
      common = { pkgs, ... }: {
        imports = [
          ../modules/credentials.nix
          ../modules/ap.nix
          ../modules/setup-screen.nix
        ];
        # Stands in for the data partition mount (disk-layout.nix).
        systemd.tmpfiles.rules = [ "d /var/lib/cloudunit 0755 root root -" ];
        environment.systemPackages = [ pkgs.kbd ];
      };
    in
    {
      # A 1080p screen that is NOT there at boot: the display driver is held back
      # and loaded later, which is what a TV plugged in after boot looks like.
      tv = { ... }: {
        imports = [ common ];
        boot.kernelParams = [ "video=1920x1080" ];
        boot.blacklistedKernelModules = [ "bochs" ];
      };
      # A screen too small for the 32x64 font, to prove the step down to 16x32.
      small = { ... }: {
        imports = [ common ];
        boot.kernelParams = [ "video=800x600" ];
      };
    };

  testScript = ''
    import re

    ENV = "/var/lib/cloudunit"
    UNIT = "cloudunit-setup-screen.service"

    def creds(m):
        ssid = m.succeed(f"grep '^AP_SSID=' {ENV}/ap.env | cut -d= -f2-").strip()
        pw = m.succeed(f"grep '^AP_PASSWORD=' {ENV}/ap.env | cut -d= -f2-").strip()
        assert ssid and pw, "ap.env has no SSID or password"
        return ssid, pw

    def screen(m):
        return m.get_tty_text("7")

    def unit_log(m):
        return m.succeed(f"journalctl -b -u {UNIT} -o cat --no-pager")

    def wait_size(m, size):
        m.wait_until_succeeds(f'[ "$(stty -F /dev/tty7 size)" = "{size}" ]', timeout=60)

    def on_screen(m, text):
        m.wait_until_tty_matches("7", re.escape(text), timeout=60)

    def picture(m):
        # A fingerprint of the picture itself: what goes to the screen, not the text buffer.
        return m.succeed("md5sum < /dev/fb0").split()[0]

    def lit(m):
        return int(m.succeed("tr -d '\\0' < /dev/fb0 | wc -c").strip())

    def in_vt_memory(m, text):
        # /dev/vcs7 is the terminal's character buffer: what is on the glass.
        return m.execute(f"grep -qF -- '{text}' /dev/vcs7")[0] == 0

    start_all()

    with subtest("first boot: a real identity, and the password on the screen"):
        tv.wait_for_unit(UNIT)
        tv.wait_until_succeeds(f"test -s {ENV}/ap.env")
        ssid, pw = creds(tv)
        suffix = tv.succeed(f"grep '^UNIT_SUFFIX=' {ENV}/unit.env | cut -d= -f2-").strip()
        perms = tv.succeed(f"stat -c '%U:%G %a' {ENV}/unit.env {ENV}/ap.env").split("\n")
        assert perms[0] == "root:root 600" and perms[1] == "root:root 600", perms
        sticker = tv.succeed("cloudunit-print-identity")
        assert f"SSID={ssid}\n" in sticker and f"PASSWORD={pw}\n" in sticker, "screen source and sticker disagree"

        on_screen(tv, "KEEPHAVEN SETUP")
        on_screen(tv, pw)
        text = screen(tv)
        assert ssid in text, text
        assert "http://192.168.50.1" in text, text
        assert in_vt_memory(tv, pw), "control: the password should be findable in the terminal buffer"
        assert tv.succeed("fgconsole").strip() == "7", "tty7 is not in front"

        shown = unit_log(tv)
        assert "brought tty7 to the front" in shown, shown
        assert "kernel messages pinned to tty1" in shown, shown
        assert "showing the 'setup' screen" in shown, shown
        assert "no large font taken" in shown, shown
        assert pw not in tv.succeed("journalctl -b -o cat --no-pager"), "the password is in the journal"
        # The journal tag is the unit name, so the obvious search finds it.
        assert "showing the 'setup' screen" in tv.succeed("journalctl -b -t cloudunit-setup-screen -o cat --no-pager")
        tv.screenshot("1-setup-no-tv-at-boot")

    with subtest("kernel messages stay off the setup screen"):
        # The kernel prints to whichever terminal is in front unless told otherwise.
        tv.succeed("echo '<3>kh-scribble-check' > /dev/kmsg")
        tv.sleep(2)
        assert not in_vt_memory(tv, "kh-scribble-check"), "a kernel message printed over the setup screen"
        tv.succeed("grep -qF kh-scribble-check /dev/vcs1")  # control: it did go to a terminal, tty1

    with subtest("anything else that lands on the screen is wiped by the next repaint"):
        tv.succeed("printf '\\033[6;1Hkh-junk-check' > /dev/tty7")
        assert in_vt_memory(tv, "kh-junk-check"), "control: the junk did not reach the screen"
        tv.wait_until_fails("grep -qF kh-junk-check /dev/vcs7", timeout=60)
        on_screen(tv, pw)

    with subtest("a TV plugged in after boot gets the large font"):
        tv.succeed("modprobe bochs")
        wait_size(tv, "16 60")
        on_screen(tv, pw)
        on_screen(tv, "The password leaves this screen")
        assert "font 32x64, terminal is 16 60" in unit_log(tv), unit_log(tv)
        tv.screenshot("2-setup-tv-plugged-in-late")

    with subtest("the large font comes back after something resets it"):
        tv.succeed("setfont -C /dev/tty7")
        assert tv.succeed("stty -F /dev/tty7 size").strip() != "16 60", "control: resetting the font changed nothing"
        wait_size(tv, "16 60")
        on_screen(tv, pw)

    with subtest("setup finishes: the password leaves the screen"):
        tv.succeed(f"echo keephaven-{suffix} > /proc/sys/kernel/hostname")
        tv.succeed(f"touch {ENV}/.setup-complete")
        on_screen(tv, "Keephaven is set up.")
        on_screen(tv, f"http://keephaven-{suffix}.local")
        assert "http://192.168.50.1" in screen(tv), screen(tv)
        assert not in_vt_memory(tv, pw), "the password is still in the terminal buffer after setup"
        assert "showing the 'done' screen: old picture wiped, new one painted" in unit_log(tv), unit_log(tv)
        done_picture = picture(tv)
        tv.screenshot("3-setup-done")

    with subtest("a console that has stopped painting cannot keep the password on the screen"):
        # Seen on the test unit: setup finished, the console did not paint, the
        # password stayed on the TV. Recreate it: blank the console, so it stops
        # painting while the picture memory still holds the password screen.
        tv.succeed(f"rm -f {ENV}/.setup-complete")
        on_screen(tv, pw)
        tv.wait_until_succeeds("journalctl -b -u cloudunit-setup-screen.service -o cat | tail -1 | grep -q \"'setup' screen\"")
        tv.sleep(1)
        setup_picture = picture(tv)
        assert setup_picture != done_picture
        tv.succeed("TERM=linux setterm --blank force < /dev/tty7 > /dev/tty7")
        assert picture(tv) == setup_picture, "control: blanking should leave the password picture in memory"
        tv.succeed("printf '\\033[20;1Hnot painted' > /dev/tty7")
        assert picture(tv) == setup_picture, "control: a blanked console should not paint"
        tv.succeed(f"touch {ENV}/.setup-complete")
        tv.wait_until_succeeds("journalctl -b -u cloudunit-setup-screen.service -o cat | tail -1 | grep -q \"'done' screen\"")
        tv.sleep(1)
        assert picture(tv) != setup_picture, "the password picture is still in the picture memory after setup"
        assert picture(tv) == done_picture, "the set-up screen was not painted"
        assert lit(tv) > 0
        assert not in_vt_memory(tv, pw)

    with subtest("a set-up box that boots never shows the password"):
        tv.shutdown()
        tv.start()
        tv.wait_for_unit(UNIT)
        on_screen(tv, "Keephaven is set up.")
        shown = unit_log(tv)
        assert "showing the 'done' screen" in shown, shown
        assert "'setup' screen" not in shown, "the setup screen was drawn on a set-up box"
        assert not in_vt_memory(tv, pw)

    with subtest("factory reset: the sticker password shows again"):
        # The two files factory-reset.sh removes that this screen depends on.
        tv.succeed(f"rm -f {ENV}/.setup-complete {ENV}/ap.env")
        tv.shutdown()
        tv.start()
        tv.wait_for_unit(UNIT)
        tv.wait_until_succeeds(f"test -s {ENV}/ap.env")
        assert creds(tv) == (ssid, pw), "the reset box did not come back to its sticker identity"
        on_screen(tv, pw)

    with subtest("a changed Wi-Fi password: the screen shows the one that works"):
        tv.succeed(
            f"umask 077; printf 'AP_SSID=My-Cloud\\nAP_PASSWORD=changed.Pass-99\\n' > {ENV}/.ap.env.new"
            f" && mv -f {ENV}/.ap.env.new {ENV}/ap.env"
        )
        on_screen(tv, "changed.Pass-99")
        on_screen(tv, "My-Cloud")
        assert not in_vt_memory(tv, pw), "the old password is still on the screen"

    with subtest("no Wi-Fi config yet: a holding screen, never an empty password"):
        tv.succeed(f"mv {ENV}/ap.env {ENV}/ap.env.away")
        on_screen(tv, "Keephaven is starting...")
        assert not in_vt_memory(tv, "changed.Pass-99")
        assert "Password" not in screen(tv), screen(tv)
        assert "changed.Pass-99" not in tv.succeed("journalctl -b -o cat --no-pager")

    with subtest("a small screen steps down to the 16x32 font"):
        small.wait_for_unit(UNIT)
        small.wait_until_succeeds(f"test -s {ENV}/ap.env")
        wait_size(small, "18 50")
        _, small_pw = creds(small)
        on_screen(small, small_pw)
        assert "font 16x32, terminal is 18 50" in unit_log(small), unit_log(small)
        small.screenshot("4-setup-small-screen")
  '';
}
