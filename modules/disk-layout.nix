{ config, pkgs, lib, ... }:

let
  dataDir = "/var/lib/cloudunit";

  # ----- Final ship-forever sizes (Phase 2) -----
  #
  # The system and recovery partitions are baked into the fixed layout and
  # cannot be changed on a deployed unit, so they are sized for the worst case.
  # Basis (measured): system closure (toplevel) ~2.86 GiB + the Phase-3 Docker
  # pre-bake (gzip image tarballs ~1.93 GiB) on EVERY generation + ~3 generations
  # of kernel/package churn + /var headroom + an OTA staging reserve. 12 GiB
  # could not hold a 2nd generation plus the tarballs plus an OTA stage, so the
  # ship-forever size is 16 GiB (bumped now, before anything has shipped).
  # Recovery holds a build-time raw copy of the system partition (Phase 3 Model
  # A, tarballs included), so it matches the system size byte-for-byte. Data
  # takes the remainder of the disk.
  systemSizeGiB = 16;

  # ----- Frozen GPT *type* GUIDs (DO NOT CHANGE post-ship) -----
  #
  # systemd-repart matches existing partitions to definitions by their GPT type
  # GUID. These two values MUST NEVER change once any unit has shipped: changing
  # them would make repart fail to recognise the existing data/recovery
  # partitions on deployed units and try to recreate (and reformat) them,
  # destroying user data. They are deliberately custom (not the linux-generic
  # 0FC63DAF... type the system partition carries) so repart can never match or
  # adopt the system partition.
  recoveryTypeGuid = "15d78efc-03a8-4ec9-a5ac-784f8283ebc4";
  dataTypeGuid     = "fe2e0698-b068-43c1-8504-d7165c0d3844";

  # ----- Bake the system + recovery filesystems at build time -----
  #
  # The stock make-ext4-fs sizes the rootfs to its content. We rebuild it
  # uncompressed (`baseRootfs`), then derive two fixed-size images:
  #
  #   systemImg   - the uncompressed ext4 enlarged to the fixed system size,
  #                 label NIXOS_SD. Handed to the sd-image buildCommand (via
  #                 rootFsImage) as partition 2. The buildCommand sizes the root
  #                 partition from `du --apparent-size` of this image, so the
  #                 on-image root becomes exactly ${toString systemSizeGiB} GiB.
  #                 Root is final at build time and never grown at runtime
  #                 (autoResize stays off; the Phase-1 boot path is unchanged).
  #
  #   recoveryImg - a byte-for-byte copy of systemImg, relabelled
  #                 cloudunit-recovery (Phase 3 Model A: raw copy WITH the Docker
  #                 tarballs). Baked into partition 3 by postBuildCommands below.
  #                 The relabel is mandatory: a second NIXOS_SD-labelled fs on the
  #                 same disk would make the by-label root mount ambiguous. The
  #                 reflash (Phase 3) does raw dd p3->p2 then tune2fs -L NIXOS_SD,
  #                 so no decompressor is ever needed in the initrd.
  #
  # systemImg/recoveryImg are identical size, so the recovery restore is a pure
  # whole-partition dd.
  baseRootfs = pkgs.callPackage config.sdImage.rootFilesystemCreator ({
    inherit (config.sdImage) storePaths;
    compressImage = false;
    populateImageCommands = config.sdImage.populateRootCommands;
    volumeLabel = config.sdImage.rootVolumeLabel;
  } // lib.optionalAttrs (config.sdImage.rootPartitionUUID != null) {
    uuid = config.sdImage.rootPartitionUUID;
  });

  systemImg = pkgs.runCommand
    "nixos-system-${toString systemSizeGiB}g.img"
    { nativeBuildInputs = [ pkgs.e2fsprogs ]; }
    ''
      cp --reflink=auto ${baseRootfs} $out
      chmod +w $out
      truncate -s ${toString systemSizeGiB}G $out
      # resize2fs needs a clean fs; e2fsck returns 1/2 when it "fixes" things.
      e2fsck -fy $out || [ "$?" -le 2 ]
      resize2fs $out
      # Leave the image e2fsck-clean (the Phase-3 gate checks this on p3 too).
      e2fsck -fy $out || [ "$?" -le 2 ]
    '';

  recoveryImg = pkgs.runCommand
    "nixos-recovery-${toString systemSizeGiB}g.img"
    { nativeBuildInputs = [ pkgs.e2fsprogs ]; }
    ''
      cp --reflink=auto ${systemImg} $out
      chmod +w $out
      tune2fs -L cloudunit-recovery $out
      e2fsck -fy $out || [ "$?" -le 2 ]
    '';

  # Partition 2 payload handed to the sd-image buildCommand: compress only if the
  # sd-image module asked for a compressed image (buildCommand decompresses it).
  rootFsImage =
    if config.sdImage.compressImage
    then pkgs.runCommand "nixos-system-${toString systemSizeGiB}g.img.zst"
      { nativeBuildInputs = [ pkgs.zstd ]; }
      ''zstd -T$NIX_BUILD_CORES ${systemImg} -o $out''
    else systemImg;
in
{
  # ----- Phase 1: emit a GPT image -----
  #
  # The stock sd-image module hardcodes an MBR/DOS table. Convert the freshly
  # built image to GPT as a post-build step, leaving the rest of the proven
  # build byte-identical. GPT is required so first-boot systemd-repart can manage
  # partitions, and the Pi 5 EEPROM bootloader reads GPT directly. The boot chain
  # is table-agnostic (root mounts by FS label, not PARTUUID), and FS labels
  # survive the conversion.
  #
  # Expand-on-boot stays off: root is baked at its final size above, so there is
  # nothing to grow. Phase 2 only ADDS partitions (below).
  sdImage.expandOnBoot = false;
  sdImage.rootFilesystemImage = rootFsImage;

  sdImage.postBuildCommands = ''
    # GPT keeps its backup header in the last 33 sectors of the disk, but the
    # root partition fills the image to its end. Add 1 MiB of slack so the
    # backup header has somewhere to live without clobbering the rootfs.
    truncate -s +1M "$img"

    # --mbrtogpt: in-place MBR->GPT conversion (writes a protective MBR).
    # -t1:0700: Microsoft basic data. Pi 5 firmware fails to read a FAT
    # partition typed ef00 (ESP) per rpi-eeprom #558; 0700 has no such report.
    ${pkgs.buildPackages.gptfdisk}/bin/sgdisk --mbrtogpt -t1:0700 "$img"

    # ----- Phase 3: bake the recovery copy into partition 3 -----
    #
    # Grow the image and carve a partition 3 sized byte-for-byte equal to the
    # recovery image, then dd the recovery copy into it. p3 == p2 size makes the
    # Phase-3 reflash a pure whole-partition dd p3->p2 (no decompressor). The
    # recovery fs is already relabelled cloudunit-recovery, so it never collides
    # with the NIXOS_SD by-label root mount.
    #
    # Two consequences of the byte-for-byte raw copy (image-verified on the 3a
    # artifact) that the Phase-3d reflash MUST account for:
    #   - p3's ext4 fs-label truncates to "cloudunit-recove" (ext4's 16-char
    #     label limit; "cloudunit-recovery" is 18). The GPT *partition name*
    #     (partlabel) stays the full "cloudunit-recovery".
    #   - p3 shares p2's ext4 UUID (it is a raw copy of the NIXOS_SD fs), so the
    #     UUID is NOT unique on the disk.
    # => The 3d reflash MUST locate p3 by its GPT type GUID
    #    (${recoveryTypeGuid}) or by GPT partlabel (cloudunit-recovery), and
    #    NEVER by ext4 fs-label or fs-UUID — both are truncated/non-unique by
    #    design. (Root stays unambiguous because p3's fs-label differs from
    #    NIXOS_SD, which is the only reason p3 is relabelled at all.)
    recBytes=$(stat -c %s ${recoveryImg})
    recSectors=$((recBytes / 512))

    # Add the recovery payload plus 2 MiB: 1 MiB covers sgdisk's 1 MiB start
    # alignment of p3, the rest leaves room for the relocated GPT backup header.
    truncate -s +$((recBytes + 2 * 1024 * 1024)) "$img"

    # -e relocates the GPT backup header to the new true device end (it was left
    # mid-image by the truncate); then carve p3 right after p2: start 0 = first
    # aligned free sector, end +recSectors = exactly recSectors sectors.
    ${pkgs.buildPackages.gptfdisk}/bin/sgdisk \
      -e \
      -n 3:0:+$recSectors \
      -t 3:${recoveryTypeGuid} \
      -c 3:cloudunit-recovery \
      "$img"

    # Read back p3's real start/length and dd the recovery image into place.
    eval $(${pkgs.buildPackages.util-linux}/bin/partx -o START,SECTORS --nr 3 --pairs "$img")
    dd conv=notrunc,sparse if=${recoveryImg} of="$img" \
      bs=4M seek=$((START * 512)) oflag=seek_bytes

    # Verify the resulting GPT is consistent (backup header at device end, no
    # overlaps). sgdisk -v exits non-zero on problems, failing the build.
    ${pkgs.buildPackages.gptfdisk}/bin/sgdisk -v "$img"
  '';

  # ----- First-boot data partition -----
  #
  # The flashed image now carries firmware + 16 GiB root + 16 GiB recovery (baked
  # above); the SSD is larger, so free space follows partition 3. systemd-repart
  # (normal boot, NOT initrd) ADDS the data partition into that free space online.
  # We do NOT grow the in-use root, so there is no need for systemd-initrd or a
  # boot-path change; the Phase-1 scripted-initrd boot path is preserved.
  #
  # Recovery is NO LONGER created here: it is part of the flashed image (Phase 3
  # Model A), so repart would only ever see it already present. repart matches by
  # type GUID, so on every boot the existing data partition is adopted (never
  # reformatted) and the run is a no-op. The first run also rewrites the GPT to
  # span the whole device, relocating the backup header to the true device end.
  systemd.repart = {
    enable = true;
    partitions = {
      # Last partition, no size cap -> grows to fill the rest of the disk.
      "20-data" = {
        Type = dataTypeGuid;
        Label = "cloudunit-data";
        Format = "ext4";
      };
    };
  };

  # systemd-repart execs `mkfs.ext4` to Format= the new partitions; the upstream
  # unit carries no PATH for it, so add e2fsprogs (rendered as a drop-in onto the
  # upstream systemd-repart.service).
  systemd.services.systemd-repart.path = [ pkgs.e2fsprogs ];

  # ----- Persistent data partition -----
  #
  # Mounted only after repart has created+formatted+labelled it. BOTH
  # x-systemd.requires (pull the dep in) and x-systemd.after (order after it) are
  # needed; requires alone does not guarantee ordering. No nofail: a missing data
  # partition must fail loudly into emergency rather than silently boot degraded
  # and let the bootstraps write onto the system partition.
  fileSystems."${dataDir}" = {
    device = "/dev/disk/by-label/cloudunit-data";
    fsType = "ext4";
    autoResize = false;
    options = [
      "x-systemd.requires=systemd-repart.service"
      "x-systemd.after=systemd-repart.service"
    ];
  };

  # ----- Phase 3c: observe-only recovery health-check (scripted initrd) -----
  #
  # Runs in postDeviceCommands (after udev has settled, before root is mounted).
  # It DETECTS p2 (NIXOS_SD/system) health, READS the FIRMWARE markers, and LOGS
  # what a future 3d reflash WOULD do. It is strictly read-only: NO dd, NO
  # reflash, NO partition write, NO marker mutation. 3d arms the action later;
  # 3c only earns trust in the verdict.
  #
  # Device binding: the unit disk is identified solely by OUR recovery partition
  # type GUID (unique to this appliance, so this never misfires on a non-unit
  # disk / CI / VM). p2 and p1 are then taken by partition NUMBER on that disk
  # via sysfs - never by ext4 fs-label or fs-UUID (3a finding: p3's label is
  # truncated to "cloudunit-recove" and it shares p2's UUID, so label/UUID are
  # ambiguous; the read path must address partitions unambiguously so 3d inherits
  # correct logic).
  #
  # The recovery partition is found by a PURE dd+od GPT parser, NOT blkid/udev.
  # Empirically (two failed Pi gates) the stage-1 initrd does not surface the
  # recovery/data partitions via `blkid -p`, `/dev/disk/by-partlabel`, or even
  # their /dev/<disk>pN nodes - though the binary supports -p, the udev rules are
  # present, and udev settles first (all verified by inspecting the built initrd).
  # So we sidestep that unobservable quirk entirely: read the WHOLE-disk node's
  # primary GPT with dd and compute partition type/name/number from raw bytes.
  # This depends only on busybox dd/od/cut/printf and the whole-disk node (which
  # must exist - root mounts off it), never on per-partition nodes/blkid/udev.
  # mount is util-linux (honors ro,norecovery -> no journal replay -> write-free).
  #
  # Bias: any ambiguity, tool error, or absent device -> verdict that takes NO
  # action. The ONLY path to "would reflash" is an unambiguously
  # unreadable/unmountable p2. A clean fs always exits e2fsck 0 -> healthy. The
  # whole block runs in a `( set +e; ... ) || true` subshell so a non-zero probe
  # (e2fsck returns 4/8 on a damaged fs) can NEVER abort the boot.
  #
  # vfat+nls are added to the initrd ONLY so FIRMWARE (vfat) can be mounted
  # read-only to read the markers; the stock initrd ships ext4 only.
  boot.initrd.supportedFilesystems.vfat = true;
  # nls_* let FIRMWARE (vfat) mount for the markers/breadcrumb. The loop driver the
  # 3d reflash uses to map the p3 region is BUILTIN in the Pi kernel, so it needs no
  # kernelModules entry.
  boot.initrd.kernelModules = [ "nls_cp437" "nls_iso8859-1" ];

  # The 3d reflash maps the p3 recovery region as a read-only loop device (losetup)
  # and flushes p2's buffer cache after the dd (blockdev --flushbufs). Both are
  # pulled into the scripted-initrd extra-utils bundle so they are guaranteed
  # present in stage-1 -- not best-effort.
  boot.initrd.extraUtilsCommands = ''
    copy_bin_and_libs ${pkgs.util-linux}/bin/losetup
    copy_bin_and_libs ${pkgs.util-linux}/bin/blockdev
  '';

  boot.initrd.postDeviceCommands = ''
    (
      set +e
      log() {
        echo "CLOUDUNIT-RECOVERY: $*"
        echo "CLOUDUNIT-RECOVERY: $*" > /dev/kmsg 2>/dev/null || true
      }

      # ----- Pure dd+od GPT reader (no blkid, no udev, no per-partition nodes) -----
      # Reads the WHOLE-disk primary GPT and derives type/name/number from raw
      # bytes, so it is immune to the stage-1 quirk that hides blkid -p /
      # by-partlabel / p3 device nodes. Byte math only -> identical under busybox.
      hexat() { printf '%s' "$1" | cut -c"$(( $2 * 2 + 1 ))-$(( ($2 + $3) * 2 ))"; }
      le32() {
        h="$1"
        b0=$(printf %s "$h" | cut -c1-2); b1=$(printf %s "$h" | cut -c3-4)
        b2=$(printf %s "$h" | cut -c5-6); b3=$(printf %s "$h" | cut -c7-8)
        printf '%d' "0x$b3$b2$b1$b0"
      }
      guid_canon() {
        h=$(printf %s "$1" | tr 'A-F' 'a-f')
        printf '%s%s%s%s-%s%s-%s%s-%s%s-%s%s%s%s%s%s' \
          "$(printf %s "$h" | cut -c7-8)"   "$(printf %s "$h" | cut -c5-6)" \
          "$(printf %s "$h" | cut -c3-4)"   "$(printf %s "$h" | cut -c1-2)" \
          "$(printf %s "$h" | cut -c11-12)" "$(printf %s "$h" | cut -c9-10)" \
          "$(printf %s "$h" | cut -c15-16)" "$(printf %s "$h" | cut -c13-14)" \
          "$(printf %s "$h" | cut -c17-18)" "$(printf %s "$h" | cut -c19-20)" \
          "$(printf %s "$h" | cut -c21-22)" "$(printf %s "$h" | cut -c23-24)" \
          "$(printf %s "$h" | cut -c25-26)" "$(printf %s "$h" | cut -c27-28)" \
          "$(printf %s "$h" | cut -c29-30)" "$(printf %s "$h" | cut -c31-32)"
      }
      name_decode() {
        h="$1"; out=""
        while [ -n "$h" ]; do
          lo=$(printf %s "$h" | cut -c1-2); hi=$(printf %s "$h" | cut -c3-4)
          h=$(printf %s "$h" | cut -c5-)
          [ "$lo" = "00" ] && [ "$hi" = "00" ] && break
          [ "$hi" = "00" ] || continue
          out="$out$(printf "\\$(printf '%o' "0x$lo")")"
        done
        printf '%s' "$out"
      }
      # Emit "<partnum> <type-guid> <name>" per non-empty GPT entry on whole-disk $1.
      gpt_entries() {
        dev="$1"
        hdr=$(dd if="$dev" bs=512 skip=1 count=1 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
        [ "$(printf %s "$hdr" | cut -c1-16)" = "4546492050415254" ] || return 1
        pe_lba=$(le32 "$(hexat "$hdr" 72 4)")
        num=$(le32 "$(hexat "$hdr" 80 4)")
        esz=$(le32 "$(hexat "$hdr" 84 4)")
        [ "$num" -gt 0 ] && [ "$num" -le 256 ] || return 1
        [ "$esz" -ge 128 ] || return 1
        cnt=$(( (num * esz + 511) / 512 ))
        arr=$(dd if="$dev" bs=512 skip="$pe_lba" count="$cnt" 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
        i=0
        while [ "$i" -lt "$num" ]; do
          off=$(( i * esz ))
          typ=$(hexat "$arr" "$off" 16)
          case "$typ" in
            00000000000000000000000000000000) i=$(( i + 1 )); continue ;;
          esac
          printf '%s %s %s\n' "$(( i + 1 ))" "$(guid_canon "$typ")" "$(name_decode "$(hexat "$arr" $(( off + 56 )) 72)")"
          i=$(( i + 1 ))
        done
      }

      udevadm settle --timeout=30 || true

      # Identify the unit disk: the whole disk whose on-disk GPT contains our
      # recovery partition (type GUID OR partlabel "cloudunit-recovery"). dd reads
      # the WHOLE-disk node /dev/<disk>, never a /dev/<disk>pN partition node.
      disk=""; entries=""; recovnum=""
      for dpath in /sys/block/*; do
        [ -e "$dpath" ] || continue
        dname=$(basename "$dpath")
        case "$dname" in loop*|ram*|zram*|dm-*|md*|sr*) continue ;; esac
        ddev=/dev/$dname
        [ -b "$ddev" ] || continue
        e=$(gpt_entries "$ddev") || continue
        [ -n "$e" ] || continue
        m=$(printf '%s\n' "$e" | awk -v g="${recoveryTypeGuid}" '($2==g)||($3=="cloudunit-recovery"){print $1; exit}')
        if [ -n "$m" ]; then disk=$dname; entries=$e; recovnum=$m; break; fi
      done
      if [ -z "$disk" ]; then
        log "no recovery partition (type=${recoveryTypeGuid} / name=cloudunit-recovery) found on any disk -> not a provisioned unit, skipping"
        exit 0
      fi
      log "unit disk=$disk recovery=p$recovnum (resolved via on-disk GPT parse, no blkid/udev)"

      # System partition (p2) type, from the SAME GPT parse - guards against ever
      # pointing the health check at our own data/recovery partition.
      p2type=$(printf '%s\n' "$entries" | awk '$1=="2"{print $2; exit}')

      # Resolve p2 (system) + p1 (firmware) device nodes by partition NUMBER on the
      # unit disk. These nodes are present (root mounts off p2); only p3/p4 are the
      # suspected stage-1 casualty, and the lookup above never needed them.
      p2=""; fw=""
      for d in /sys/class/block/$disk/$disk*; do
        [ -f "$d/partition" ] || continue
        n=$(cat "$d/partition" 2>/dev/null)
        [ "$n" = "2" ] && p2=/dev/$(basename "$d")
        [ "$n" = "1" ] && fw=/dev/$(basename "$d")
      done

      # ----- Health verdict for p2 (read-only) -----
      verdict=unknown; ec=-1; sb=-1; mok=-1
      if [ -z "$p2" ] || [ ! -b "$p2" ]; then
        verdict=absent
      else
        # Never point the check at our own data/recovery partitions (type from GPT).
        if [ "$p2type" = "${recoveryTypeGuid}" ] || [ "$p2type" = "${dataTypeGuid}" ]; then
          log "refusing to check $p2: type=$p2type is data/recovery, not system -> skipping"
          exit 0
        fi
        e2fsck -fn "$p2" >/dev/null 2>&1; ec=$?
        tune2fs -l "$p2" >/dev/null 2>&1; sb=$?
        mkdir -p /cloudunit-probe
        # ro,norecovery: util-linux mount suppresses journal replay -> write-free.
        if mount -o ro,norecovery "$p2" /cloudunit-probe 2>/dev/null; then
          mok=0; umount /cloudunit-probe 2>/dev/null || true
        else
          mok=1
        fi
        if [ "$ec" -eq 0 ]; then
          verdict=healthy
        elif [ "$ec" -eq 16 ] || [ "$ec" -eq 128 ]; then
          # e2fsck tool/usage/lib error -> fail safe, take no action.
          verdict=inconclusive
        else
          # Errors present (4/8/combos). With -n, e2fsck never "corrects", so the
          # corrective codes 1/2 (the existing repair-in-place tier, run -y by the
          # stock root fsck) cannot appear here. Split fixable vs corrupt, biased
          # to no-action: only an unreadable superblock OR a failed read-only
          # mount is corrupt; an errored-but-readable-and-mountable fs is the
          # repair-in-place tier (NOT reflash).
          if [ "$sb" -ne 0 ] || [ "$mok" -ne 0 ]; then
            verdict=corrupt
          else
            verdict=fixable
          fi
        fi
      fi

      # ----- Marker read (FIRMWARE vfat, read-only) -----
      reflash=absent; state=none; fwread=ok
      if [ -n "$fw" ] && [ -b "$fw" ]; then
        mkdir -p /cloudunit-fw
        if mount -t vfat -o ro "$fw" /cloudunit-fw 2>/dev/null; then
          [ -e /cloudunit-fw/cloudunit-reflash ] && reflash=present
          if [ -f /cloudunit-fw/cloudunit-recovery.state ]; then
            state=$(cat /cloudunit-fw/cloudunit-recovery.state 2>/dev/null | tr -d '\r\n')
            [ -z "$state" ] && state=empty
          fi
          umount /cloudunit-fw 2>/dev/null || true
        else
          fwread=fail
        fi
      else
        fwread=nodev
      fi

      # ----- Log verdict + marker (greppable) -----
      log "disk=$disk p2=$p2 e2fsck=$ec sb=$sb mount=$mok verdict=$verdict"
      log "marker reflash=$reflash state=$state firmware=$fwread"

      # ===================== Phase 3d: live p3 -> p2 reflash =====================
      # Fail-safe before destructive: p3 is validated through a REAL e2fsck-able
      # losetup handle (STEP-0-proven) BEFORE any byte is written to p2. The dd
      # source p3 is read-only (losetup -r); ONLY p2 is ever written -- p4 (data) is
      # never read or touched. Anti-storm: one reflash per fault regardless of
      # trigger; a crashed mid-dd attempt (phase=started seen on entry) or a prior
      # attempt that still triggers -> emergency, no retry. Forcing another requires
      # clearing cloudunit-recovery.state from the helper.
      #
      # End-state on ABORT: every abort/fail path is `exit 0`, leaving this subshell
      # so stage-1 init continues with p2 left exactly as found. If p2 is corrupt the
      # downstream by-label root mount fails and the scripted initrd drops to its
      # interactive rescue shell (a reachable recovery prompt, NOT a hang); if p2 is
      # healthy the box simply boots. We never block boot ourselves.

      # ----- A. helpers (no shell brace param-expansion: it collides with Nix) -----
      kv() { printf '%s\n' "$2" | awk -v d="$1" '{for(i=1;i<=NF;i++){n=index($i,"=");if(n>0&&substr($i,1,n-1)==d){print substr($i,n+1);exit}}}'; }
      le64lo() {  # $1=hex(16 chars,8 bytes LE) -> low-32 decimal; "OVER" if high 32 != 0
        hh="$1"; hi=$(printf %s "$hh" | cut -c9-16)
        [ "$hi" = "00000000" ] || { printf 'OVER'; return 0; }
        le32 "$(printf %s "$hh" | cut -c1-8)"
      }
      gpt_range() {  # $1=whole-disk dev $2=partnum -> "<startLBA> <sectors>"
        d="$1"; want="$2"
        h=$(dd if="$d" bs=512 skip=1 count=1 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
        [ "$(printf %s "$h" | cut -c1-16)" = "4546492050415254" ] || return 1
        pe=$(le32 "$(hexat "$h" 72 4)"); es=$(le32 "$(hexat "$h" 84 4)")
        a=$(dd if="$d" bs=512 skip="$pe" count=$(( (256*es+511)/512 )) 2>/dev/null | od -An -tx1 -v | tr -d ' \n')
        o=$(( (want - 1) * es ))
        s=$(le64lo "$(hexat "$a" $(( o + 32 )) 8)"); e=$(le64lo "$(hexat "$a" $(( o + 40 )) 8)")
        { [ "$s" = OVER ] || [ "$e" = OVER ] || [ -z "$s" ] || [ -z "$e" ]; } && return 1
        printf '%s %s' "$s" "$(( e - s + 1 ))"
      }
      fw_rw() { [ -n "$fw" ] && [ -b "$fw" ] || return 1; mkdir -p /cloudunit-fw; mount -t vfat -o rw "$fw" /cloudunit-fw 2>/dev/null; }
      write_state() { if fw_rw; then printf 'phase=%s attempt=%s\n' "$1" "$2" > /cloudunit-fw/cloudunit-recovery.state 2>/dev/null || true; sync; umount /cloudunit-fw 2>/dev/null || true; fi; }
      crumb() { if fw_rw; then printf '%s\n' "$*" >> /cloudunit-fw/cloudunit-recovery.last 2>/dev/null || true; sync; umount /cloudunit-fw 2>/dev/null || true; fi; log "$*"; }

      # ----- B. breadcrumb header (overwrite) + reflash decision -----
      ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null); [ -z "$ts" ] && ts="uptime$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
      if fw_rw; then
        printf 'ts=%s disk=%s p2=%s e2fsck=%s sb=%s mount=%s verdict=%s reflash=%s state=%s firmware=%s\n' \
          "$ts" "$disk" "$p2" "$ec" "$sb" "$mok" "$verdict" "$reflash" "$state" "$fwread" \
          > /cloudunit-fw/cloudunit-recovery.last 2>/dev/null || true
        sync; umount /cloudunit-fw 2>/dev/null || true
      fi
      phase=$(kv phase "$state"); [ -n "$phase" ] || phase=clean
      attempt=$(kv attempt "$state"); case "$attempt" in ""|*[!0-9]*) attempt=0 ;; esac
      log "verdict=$verdict reflash=$reflash phase=$phase attempt=$attempt"
      do_reflash=no; reason=
      if   [ "$phase" = started ];   then reason="prior attempt crashed mid-dd (phase=started) -> emergency, no retry"
      elif [ "$reflash" = present ]; then do_reflash=yes; reason="deliberate (request marker present)"
      elif [ "$verdict" = corrupt ]; then do_reflash=yes; reason="auto (verdict=corrupt)"
      else reason="no trigger (verdict=$verdict, no marker)"
      fi
      if [ "$do_reflash" = yes ] && [ "$attempt" -ge 1 ]; then
        do_reflash=no; reason="attempt=$attempt already tried, still triggering -> emergency, no retry"
      fi
      if [ "$do_reflash" != yes ]; then crumb "ACTION=none reason=$reason"; exit 0; fi

      # ----- C. validate p3 (read-only) BEFORE touching p2 -----
      crumb "REFLASH begin reason=$reason"
      newattempt=$(( attempt + 1 ))
      abort_emergency() { write_state failed "$newattempt"; crumb "ABORT $* -- emergency, p2 left untouched"; exit 0; }
      r3=$(gpt_range /dev/$disk "$recovnum") || abort_emergency "p3 GPT range unreadable"
      r2=$(gpt_range /dev/$disk 2)           || abort_emergency "p2 GPT range unreadable"
      p3start=$(printf '%s' "$r3" | cut -d' ' -f1); p3sectors=$(printf '%s' "$r3" | cut -d' ' -f2)
      p2start=$(printf '%s' "$r2" | cut -d' ' -f1); p2sectors=$(printf '%s' "$r2" | cut -d' ' -f2)
      [ -n "$p2" ] && [ -b "$p2" ] || abort_emergency "p2 node missing"
      { [ "$p2type" != "${recoveryTypeGuid}" ] && [ "$p2type" != "${dataTypeGuid}" ]; } || abort_emergency "p2 type=$p2type is data/recovery"
      [ "$recovnum" != "2" ] || abort_emergency "recovery==p2"
      [ -n "$p3start" ] && [ -n "$p3sectors" ] && [ -n "$p2sectors" ] || abort_emergency "offsets unreadable"
      [ "$p3sectors" = "$p2sectors" ] || abort_emergency "size mismatch p3=$p3sectors p2=$p2sectors"
      [ "$p3start" -ge "$(( p2start + p2sectors ))" ] || abort_emergency "p3/p2 overlap"
      lp=$(losetup -r -f --show -o $(( p3start * 512 )) --sizelimit $(( p3sectors * 512 )) /dev/$disk 2>/dev/null)
      [ -n "$lp" ] && [ -b "$lp" ] || abort_emergency "no e2fsck-able p3 handle (losetup failed)"
      e2fsck -fn "$lp" >/dev/null 2>&1; p3ec=$?
      tune2fs -l "$lp" >/dev/null 2>&1; p3sb=$?
      p3mnt=1; p3sent=missing; mkdir -p /cloudunit-p3probe
      if mount -o ro,norecovery "$lp" /cloudunit-p3probe 2>/dev/null; then
        p3mnt=0; [ -d /cloudunit-p3probe/nix/store ] && p3sent=found; umount /cloudunit-p3probe 2>/dev/null || true
      fi
      crumb "p3valid e2fsck=$p3ec tune2fs=$p3sb mount=$p3mnt sentinel=$p3sent"
      if [ "$p3ec" -ne 0 ] || [ "$p3sb" -ne 0 ] || [ "$p3mnt" -ne 0 ] || [ "$p3sent" != found ]; then
        losetup -d "$lp" 2>/dev/null || true
        [ "$verdict" = corrupt ] && abort_emergency "p2 corrupt, p3 invalid -- on-device recovery exhausted"
        abort_emergency "p3 invalid (source not restorable)"
      fi

      # ----- D. destructive: p3 -> p2 (phase=started synced to FIRMWARE BEFORE dd) -
      write_state started "$newattempt"
      crumb "phase=started attempt=$newattempt -- writing p2 now"
      ddok=1
      if [ "$(( (p3sectors*512) % 1048576 ))" -eq 0 ]; then
        dd if="$lp" of="$p2" bs=1M count=$(( p3sectors*512/1048576 )) conv=fsync 2>/dev/null && ddok=0
      else
        dd if="$lp" of="$p2" bs=512 count="$p3sectors" conv=fsync 2>/dev/null && ddok=0
      fi
      sync; blockdev --flushbufs "$p2" 2>/dev/null || true; losetup -d "$lp" 2>/dev/null || true
      [ "$ddok" -eq 0 ] || { write_state failed "$newattempt"; crumb "ABORT dd failed -- p2 may be partial, emergency"; exit 0; }

      # ----- E. relabel restored p2 back to NIXOS_SD + verify -----
      # (p3's ext4 carries the recovery label; the raw copy lands it on p2, so put
      # the system label back before the by-label root mount can resolve it.)
      tune2fs -L NIXOS_SD "$p2" >/dev/null 2>&1 || true
      e2fsck -fy "$p2" >/dev/null 2>&1; fyec=$?
      e2fsck -fn "$p2" >/dev/null 2>&1; rvec=$?
      rvmnt=1; mkdir -p /cloudunit-probe2
      mount -o ro,norecovery "$p2" /cloudunit-probe2 2>/dev/null && { rvmnt=0; umount /cloudunit-probe2 2>/dev/null || true; }

      # ----- F. republish by-label NIXOS_SD (load-bearing: root mounts by label) ---
      udevadm trigger --action=change "$p2" 2>/dev/null || true
      udevadm settle --timeout=30 2>/dev/null || true
      lblok=0; lblsrc=udev
      if [ -e /dev/disk/by-label/NIXOS_SD ] && [ "$(readlink -f /dev/disk/by-label/NIXOS_SD 2>/dev/null)" = "$(readlink -f "$p2")" ]; then lblok=1; fi
      if [ "$lblok" -ne 1 ]; then
        # Verify-item B fallback: stage-1 udev did not republish the by-label symlink.
        # Create it by hand pointing at the known-good restored node so the downstream
        # by-label root mount resolves -- never wait on stage-1 udev.
        mkdir -p /dev/disk/by-label 2>/dev/null || true
        ln -sf "$p2" /dev/disk/by-label/NIXOS_SD 2>/dev/null || true
        if [ -e /dev/disk/by-label/NIXOS_SD ] && [ "$(readlink -f /dev/disk/by-label/NIXOS_SD 2>/dev/null)" = "$(readlink -f "$p2")" ]; then
          lblok=1; lblsrc=manual
        fi
      fi
      crumb "reflash-verify fsck_fy=$fyec fsck_fn=$rvec mount=$rvmnt label_resolves=$lblok label_src=$lblsrc"

      if [ "$rvec" -eq 0 ] && [ "$rvmnt" -eq 0 ] && [ "$lblok" -eq 1 ]; then
        write_state ok "$newattempt"
        if [ "$reflash" = present ]; then
          if fw_rw; then rm -f /cloudunit-fw/cloudunit-reflash 2>/dev/null || true; sync; umount /cloudunit-fw 2>/dev/null || true; fi
          crumb "request marker cleared (deliberate reflash done)"
        fi
        crumb "phase=ok attempt=$newattempt action=restored p3->p2 (label_src=$lblsrc) -- continuing boot into restored system"
      else
        write_state failed "$newattempt"
        crumb "phase=failed attempt=$newattempt fsck_fn=$rvec mount=$rvmnt label=$lblok -- restore did not verify -> emergency"
      fi
      exit 0
      # =================== end Phase 3d live reflash ===================
    ) || true
  '';

  # Verify-item A -- abort end-state. Every abort/failed-restore path above is
  # `exit 0`, which hands the (untouched/corrupt) p2 back to the scripted-initrd
  # root mount. That mount fscks p2 and, if it is still corrupt, calls stage-1
  # `fail`. Without shell_on_fail, fail() prints an error and blocks on `read -n1`
  # offering only reboot/continue -- no shell, an effective hang on a headless
  # unit. shell_on_fail makes fail() offer a reachable interactive recovery shell
  # on the console instead. Either way the FIRMWARE breadcrumb is already written,
  # so the verdict is recoverable from the SD/helper with zero console interaction.
  boot.kernelParams = [ "boot.shell_on_fail" ];

  # Loop-guard reset (Q5). A reflash bumps `attempt` and arms the anti-storm guard
  # (one reflash per fault); this late-boot oneshot clears the guard back to
  # `phase=clean attempt=0` ONLY once the restored system has proven itself, so a
  # healthy unit can accept a future legitimate reflash. Milestone (decision #2):
  # docker + unit-bootstrap is the always-required foundation; an already-set-up
  # unit (.setup-complete present) must ALSO show the dashboard live, but un-set-up
  # units are not held hostage to a dashboard that intentionally isn't running yet.
  systemd.services.cloudunit-recovery-reset = {
    description = "Reset recovery loop-guard state after a confirmed-good boot";
    wantedBy = [ "multi-user.target" ];
    after = [ "docker.service" "cloudunit-unit-bootstrap.service" "cloudunit-dashboard.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -u
      # Foundation: docker up AND unit-bootstrap succeeded (active now or exited ok).
      ${pkgs.systemd}/bin/systemctl is-active --quiet docker.service || exit 0
      ${pkgs.systemd}/bin/systemctl is-active --quiet cloudunit-unit-bootstrap.service \
        || [ "$(${pkgs.systemd}/bin/systemctl show -p Result --value cloudunit-unit-bootstrap.service)" = success ] \
        || exit 0
      # Conditional dashboard signal: only gate on it once the unit is set up.
      if [ -e ${dataDir}/.setup-complete ]; then
        ${pkgs.systemd}/bin/systemctl is-active --quiet cloudunit-dashboard.service || exit 0
      fi
      # Milestone met -> clear the loop guard. FIRMWARE is noauto; mount it just long
      # enough to rewrite the state file, and only if it isn't already clean (avoid a
      # needless vfat write every boot).
      fw=/dev/disk/by-label/FIRMWARE
      [ -b "$fw" ] || exit 0
      mnt=/run/cloudunit-recovery-reset.mnt
      ${pkgs.coreutils}/bin/mkdir -p "$mnt"
      if ${pkgs.util-linux}/bin/mount -t vfat -o rw "$fw" "$mnt" 2>/dev/null; then
        cur=$(${pkgs.coreutils}/bin/cat "$mnt/cloudunit-recovery.state" 2>/dev/null | ${pkgs.coreutils}/bin/tr -d '\r\n')
        if [ "$cur" != "phase=clean attempt=0" ]; then
          printf 'phase=clean attempt=0\n' > "$mnt/cloudunit-recovery.state" 2>/dev/null || true
          ${pkgs.coreutils}/bin/sync
        fi
        ${pkgs.util-linux}/bin/umount "$mnt" 2>/dev/null || true
      fi
      ${pkgs.coreutils}/bin/rmdir "$mnt" 2>/dev/null || true
    '';
  };
}
