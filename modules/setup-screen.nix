# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Setup details on the HDMI screen, so a self-flashed box -- no sticker -- can be
# set up by plugging in a TV instead of pulling the SSD.
#
# WHAT IT SHOWS. The Wi-Fi name and password come from ap.env, the same file
# hostapd reads (ap.nix), so the screen can only show credentials that work right
# now. On a fresh or factory-reset box ap.env is seeded from unit.env, so they are
# the sticker values. After a soft reset on a box whose owner changed the Wi-Fi
# password in Settings, unit.env would be the WRONG password to join with.
#
# WHEN IT SHOWS IT. That password is also the Samba password and every app
# account's password (samba.nix, provision.nix), so it is drawn ONLY while
# .setup-complete is absent. Once the flag exists the script stops reading the
# password at all. Factory reset deletes the flag and ap.env and keeps unit.env
# (factory-reset.sh), so a reset box shows its sticker password again.
#
# WHERE IT DRAWS. On its own virtual terminal (tty7), brought to the front. tty1
# carries systemd's status output and the boot log, which would print over the
# password; tty7 is outside logind's getty range (NAutoVTs=6), so nothing else
# opens it and tty1 stays exactly as it was. One thing does follow the front
# terminal wherever it goes: kernel messages (loglevel=7 here). They are pinned
# back to tty1 with setlogcons, and the screen is repainted every 30 s in case
# anything else ever lands on it.
#
# MAKING SURE THE OLD SCREEN IS GONE. On the test unit the password stayed on the
# TV after setup, twice, and could not be reproduced on demand: once the console
# had not painted the new screen, once the TV held an old frame (gate, 2026-10-01).
# So a change of screen never relies on the console repainting. The picture memory
# is zeroed directly -- on the Pi the console draws straight into the buffer that
# is scanned out, so that removes the password from the signal whatever state the
# console is in -- and the video signal is switched off and on around the redraw,
# so a TV cannot keep showing the frame it had. If the redraw then fails, the
# screen is black, not a password. Each change logs whether the wipe and the
# repaint were seen in the picture, so a sealed box can tell us what happened.
#
# A TV PLUGGED IN LATE. With no display at boot there is no framebuffer console,
# and a large font can't be set. So the script watches the terminal's size and
# picks the font again whenever it changes -- which is what a TV arriving looks
# like -- every 30 s while no font has taken, and whenever the font actually
# loaded is not the one it chose.
{ config, pkgs, lib, ... }:
let
  dataDir = "/var/lib/cloudunit";
  apEnv = "${dataDir}/ap.env";
  setupFlag = "${dataDir}/.setup-complete";
  # The box's own address on its setup Wi-Fi, read from ap.nix so the two can't drift.
  apAddress = (builtins.head config.networking.interfaces.wlan0.ipv4.addresses).address;

  # Only the two font files, not both font packages, go into the image.
  fonts = pkgs.runCommand "cloudunit-setup-screen-fonts" { } ''
    mkdir -p $out
    cp ${pkgs.spleen}/share/consolefonts/spleen-32x64.psfu $out/32x64.psfu
    cp ${pkgs.terminus_font}/share/consolefonts/ter-v32b.psf.gz $out/16x32.psf.gz
  '';

  screenScript = pkgs.writeShellScript "cloudunit-setup-screen" ''
    set -u
    VT=7
    TTY=/dev/tty$VT
    # The fixed lines need 36 columns; the layout needs 11 rows.
    MINCOLS=36
    MINROWS=11

    field() {
      ${pkgs.gnugrep}/bin/grep "^$1=" ${apEnv} 2>/dev/null | ${pkgs.coreutils}/bin/cut -d= -f2-
    }

    # "rows cols" of the terminal, or nothing if it can't be read.
    geom() {
      ${pkgs.coreutils}/bin/stty -F "$TTY" size 2>/dev/null
    }

    if ! { exec 3>"$TTY"; } 2>/dev/null; then
      echo "cannot open $TTY; nothing to draw on"
      exit 1
    fi
    if ${pkgs.coreutils}/bin/timeout 5 ${pkgs.kbd}/bin/chvt "$VT"; then
      echo "brought tty$VT to the front"
    else
      echo "could not bring tty$VT to the front (chvt exit $?); the screen may stay on the boot log"
    fi
    # Kernel messages go to the terminal in front unless pinned to one.
    if ${pkgs.kbd}/bin/setlogcons 1 2>/dev/null; then
      echo "kernel messages pinned to tty1"
    else
      echo "could not pin kernel messages to tty1 (setlogcons exit $?); they may print over the screen until the next repaint"
    fi
    # Screen blanking off, power-down off, cursor hidden.
    printf '\033[9;0]\033[14;0]\033[?25l' >&3

    # The font loaded on the terminal right now, as WIDTHxHEIGHT, or nothing.
    # systemd-vconsole-setup runs whenever a framebuffer console appears and
    # copies tty1's font over every terminal, so "it was set" is not "it is set".
    loaded() {
      local f
      f=$(${pkgs.kbd}/bin/showconsolefont -C "$TTY" -i 2>/dev/null) || return 0
      echo "''${f%x*}"
    }

    # Largest font that still leaves $1 columns and MINROWS rows. Sets $font to
    # the size now loaded, or "default" when the terminal took neither.
    font=default
    pick_font() {
      local name file g
      font=default
      for name in 32x64 16x32; do
        case "$name" in
          32x64) file=${fonts}/32x64.psfu ;;
          16x32) file=${fonts}/16x32.psf.gz ;;
        esac
        if ${pkgs.kbd}/bin/setfont -C "$TTY" "$file" 2>/dev/null && [ "$(loaded)" = "$name" ]; then
          font=$name
          g=$(geom)
          if [ -n "$g" ] && [ "''${g#* }" -ge "$1" ] && [ "''${g% *}" -ge "$MINROWS" ]; then
            return 0
          fi
        fi
      done
      return 1
    }

    # draw STATE [clear] -- paints every row of the layout, blank ones included,
    # so a repaint also wipes anything that printed over it. Text starts at
    # column 4, clear of a TV's overscan.
    draw() {
      local -a line=()
      local b=$'\033[1m' n=$'\033[0m' r
      case "$1" in
        starting)
          line[2]="''${b}Keephaven is starting...$n"
          line[4]='This screen updates by itself.'
          ;;
        setup)
          line[2]="''${b}KEEPHAVEN SETUP$n"
          line[4]="Wi-Fi name:  $b$ssid$n"
          line[5]="Password:    $b$pw$n"
          line[7]='Join that Wi-Fi, then open'
          line[8]="''${b}http://${apAddress}$n"
          if [ "$rows" -ge 13 ]; then
            line[10]='The password leaves this screen'
            line[11]='when setup is done.'
          fi
          ;;
        done)
          line[2]="''${b}Keephaven is set up.$n"
          line[4]='On your home network, open'
          line[5]="''${b}http://$host.local$n"
          line[7]="On the box's own Wi-Fi, open"
          line[8]="''${b}http://${apAddress}$n"
          ;;
      esac
      {
        if [ "''${2-}" = clear ]; then
          printf '\033[2J\033[3J'
        fi
        for r in 1 2 3 4 5 6 7 8 9 10 11; do
          printf '\033[%d;1H\033[K\033[%d;4H%s' "$r" "$r" "''${line[r]-}"
        done
        if [ "$rows" -gt 11 ]; then
          printf '\033[12;1H\033[J'
        fi
        printf '\033[1;1H'
      } >&3
    }

    FB=/sys/class/graphics/fb0

    # Size of the picture in bytes. Fails when there is no picture device, which
    # is the case until a screen has been attached.
    fb_bytes() {
      local s v
      s=$(${pkgs.coreutils}/bin/cat $FB/stride 2>/dev/null) || return 1
      v=$(${pkgs.coreutils}/bin/cat $FB/virtual_size 2>/dev/null) || return 1
      echo $(( s * ''${v#*,} ))
    }

    # Bytes of the picture ($1 bytes long) that are not black.
    lit() {
      ${pkgs.coreutils}/bin/head -c "$1" /dev/fb0 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '\0' | ${pkgs.coreutils}/bin/wc -c
    }

    # show STATE -- put STATE on the screen so that nothing of the screen before
    # it can survive (see MAKING SURE THE OLD SCREEN IS GONE above). Fails, and
    # says why, when the result could not be seen in the picture.
    show() {
      local n wiped=no after
      ${pkgs.coreutils}/bin/timeout 5 ${pkgs.kbd}/bin/chvt "$VT" || echo "could not bring tty$VT to the front (chvt exit $?)"
      n=$(fb_bytes) || n=
      if [ -n "$n" ]; then
        if ${pkgs.coreutils}/bin/head -c "$n" /dev/zero > /dev/fb0 2>/dev/null && [ "$(lit "$n")" = 0 ]; then
          wiped=yes
        fi
        echo 4 > $FB/blank 2>/dev/null || echo "could not switch the video signal off"
      fi
      if ! draw "$1" clear; then
        echo "could not write the '$1' screen to $TTY"
      fi
      if [ -n "$n" ]; then
        echo 0 > $FB/blank 2>/dev/null || echo "could not switch the video signal back on"
      fi
      printf '\033[13]' >&3
      if [ -z "$n" ]; then
        echo "showing the '$1' screen (no picture device yet: no screen has been attached)"
        return 0
      fi
      after=$(lit "$n")
      if [ "$wiped" != yes ]; then
        echo "showing the '$1' screen, but the old picture could NOT be wiped first"
        return 1
      fi
      if [ "$after" = 0 ]; then
        echo "drew the '$1' screen but the picture is black: the console is not painting"
        return 1
      fi
      echo "showing the '$1' screen: old picture wiped, new one painted"
    }

    state=none
    key=
    lastgeom=
    lastneed=0
    rows=0
    tick=0
    retry=
    while :; do
      # The setup flag wins, and once it exists the password is not even read.
      ssid=
      pw=
      if [ -e ${setupFlag} ]; then
        new=done
      else
        ssid=$(field AP_SSID)
        pw=$(field AP_PASSWORD)
        if [ -n "$ssid" ] && [ -n "$pw" ]; then
          new=setup
        else
          new=starting
          pw=
        fi
      fi
      host=$(${pkgs.coreutils}/bin/cat /proc/sys/kernel/hostname 2>/dev/null)

      # Columns the widest line needs: label (13) + value, inside the indent.
      wide=''${#ssid}
      if [ "''${#pw}" -gt "$wide" ]; then wide=''${#pw}; fi
      need=$(( 3 + 13 + wide + 1 ))
      if [ "$need" -lt "$MINCOLS" ]; then need=$MINCOLS; fi

      clear=
      g=$(geom)
      if [ "$g" != "$lastgeom" ] || [ "$need" != "$lastneed" ] \
         || { [ "$font" = default ] && [ "$tick" -eq 0 ]; } \
         || { [ "$font" != default ] && [ "$(loaded)" != "$font" ]; }; then
        was="$font $lastgeom $(loaded)"
        if pick_font "$need"; then fits=yes; else fits=no; fi
        g=$(geom)
        if [ "$font $g $(loaded)" != "$was" ]; then
          case "$font:$fits" in
            default:*) echo "no large font taken (no screen attached, or it refused both); terminal is ''${g:-unreadable} (rows cols)" ;;
            *:yes)     echo "font $font, terminal is $g (rows cols)" ;;
            *:no)      echo "font $font, terminal is ''${g:-unreadable} (rows cols) -- too small for the layout, lines may wrap" ;;
          esac
          clear=clear
        fi
        lastgeom=$g
        lastneed=$need
      fi
      rows=''${g% *}
      rows=''${rows:-0}

      # Redraw from scratch when anything shown changes. The key holds the
      # password, so it stays in memory and is never logged.
      newkey="$new|$ssid|$pw|$host"
      if [ "$newkey" != "$key" ]; then clear=clear; fi
      if [ -n "$clear" ] || { [ -n "$retry" ] && [ "$tick" -eq 0 ]; }; then
        if show "$new"; then retry=; else retry=yes; fi
        state=$new
        key=$newkey
      elif [ "$tick" -eq 0 ]; then
        draw "$state" || true
        # A black picture with a screen attached means the console stopped painting.
        if n=$(fb_bytes) && [ "$(lit "$n")" = 0 ]; then
          echo "the picture is black; showing the '$state' screen again"
          if show "$state"; then retry=; else retry=yes; fi
        fi
      fi

      tick=$(( (tick + 1) % 6 ))
      ${pkgs.coreutils}/bin/sleep 5
    done
  '';
in
{
  systemd.services.cloudunit-setup-screen = {
    description = "Cloud Unit - setup details on the HDMI screen (password only until setup is done)";
    wantedBy = [ "multi-user.target" ];
    after = [ "cloudunit-ap-bootstrap.service" "cloudunit-set-hostname.service" ];
    unitConfig = {
      RequiresMountsFor = dataDir;
      # No virtual terminals, no screen to draw on.
      ConditionPathExists = "/dev/tty0";
    };
    serviceConfig = {
      ExecStart = screenScript;
      Restart = "always";
      RestartSec = 30;
      StandardInput = "null";
      # The script's own name carries a store hash; this makes `journalctl -t`
      # match the unit name, as `-u` already does.
      SyslogIdentifier = "cloudunit-setup-screen";
    };
  };
}
