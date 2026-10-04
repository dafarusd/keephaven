# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: AGPL-3.0-only
{ config, pkgs, lib, ... }:

# ============================================================================
# UPDATE ARC — U1 (trust anchor + verify gate) + U2 (detect + notify ONLY).
#
# U1 ships the trust anchor + the security gate. U2 adds detect+notify: the
# update-URL config, a poll of the vendor manifest, version comparison vs the
# baked running version, and a status file the dashboard renders. NO download,
# NO verify-of-a-real-image, NO apply yet (those are U3-U5).
#
# Trust model (locked in U0):
#   - A vendor-signed system image is verified by minisign against the PUBLIC key
#     baked below. The matching PRIVATE key NEVER ships: it lives only on the
#     owner's build machine and signs each release out-of-band.
#   - The detached minisign signature over the RAW image (prehashed, -H) is the
#     SOLE authenticity anchor. A later manifest sha256 is integrity-only, never
#     trust. An unsigned / wrong-key / tampered image MUST be rejected before it
#     can reach p2/p3 -- that gate is `cloudunit-update-verify` below.
#
# Recovery path: NOT touched by this module (no initrd, no p2/p3 writes here).
# Twin discipline: the pubkey + helper are profile-independent and byte-identical
# in dev and prod, so `nix store diff-closures dev prod` stays two-rooted
# (kh-admin key only) -- the baked pubkey is the same store path in both twins.
# ============================================================================

let
  dataDir = "/var/lib/cloudunit";
  # The shared Immich dump producer (modules/immich-dump.nix). It lives OUTSIDE
  # keephaven.replication.enable precisely so this arc can rely on it: the
  # pre-update dump must work on every box, including customer boxes with
  # replication switched off.
  dumpWrapper = config.cloudunit.wrappers.immichDump;
  # Where the baked PUBLIC key lands in the image. Later phases read it from here.
  pubKeyPath = "/etc/cloudunit/update/keephaven-update.pub";

  # U4.1: the base64 public-key line (algorithm+keyid+ed25519 key, no comment),
  # baked as a STRING into the initrd apply-writer for in-initrd signature verify
  # via `minisign -P`. Public + profile-independent => no third diff-closures root.
  pubKeyB64 = lib.elemAt
    (lib.filter (l: l != "" && !(lib.hasPrefix "untrusted comment" l))
      (lib.splitString "\n" (builtins.readFile ../keys/keephaven-update.pub)))
    0;

  # ----- U2 detect+notify: the manifest poll -----
  # Resolves the base URL (p4 override wins over baked default), fetches
  # <base>/manifest.json, validates the version against a strict zero-padded
  # pattern (untrusted input -> sanitized before it can reach the dashboard),
  # compares lexically against the baked running version, and writes a tiny
  # status.json the dashboard renders. Fail-soft: any error -> state=error, never
  # a crash. NO download/verify/apply here.
  checkScript = pkgs.writeText "cloudunit-update-check.py" ''
    import json, os, re, sys, urllib.request

    DATA_DIR = "${dataDir}"
    UPDATE_DIR = os.path.join(DATA_DIR, "update")
    STATUS = os.path.join(UPDATE_DIR, "status.json")
    APPLY_PENDING = os.path.join(UPDATE_DIR, "apply-pending")
    OVERRIDE = os.path.join(DATA_DIR, "update.conf")
    BAKED_URL = "/etc/cloudunit/update/url"
    VERSION_FILE = "/etc/cloudunit/update/version"
    # zero-padded date version, optional -N suffix for same-day rebuilds
    VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-[0-9]+)?$")

    def write_status(obj):
        os.makedirs(UPDATE_DIR, exist_ok=True)
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
            f.write("\n")
        os.replace(tmp, STATUS)

    def read_first_line(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return ""

    def ua_request(url):
        # Identify honestly: bot walls (e.g. Cloudflare Browser Integrity Check)
        # 403 the default Python-urllib UA -- root-caused on the first real-host
        # OTA (DEVLOG 2026-07-23). Never rely on a server-side UA allowlist.
        ua = "Keephaven-Update/" + (read_first_line(VERSION_FILE) or "unknown")
        return urllib.request.Request(url, headers={"User-Agent": ua})

    def resolve_base_url():
        # p4 override wins (bench): a line UPDATE_BASE_URL=...
        try:
            with open(OVERRIDE) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("UPDATE_BASE_URL="):
                        v = line.split("=", 1)[1].strip()
                        if v:
                            return v
        except OSError:
            pass
        return read_first_line(BAKED_URL)

    def main():
        cur = read_first_line(VERSION_FILE)
        # bug-A fix: never clobber an in-flight apply/boot-prove status with a
        # version-only verdict. While apply-pending exists OR the status is mid-
        # flow, the boot-prove/rollback state must stay visible until confirm or
        # the watchdog resolves it.
        if os.path.exists(APPLY_PENDING):
            return 0
        try:
            cur_state = json.load(open(STATUS)).get("state", "")
        except Exception:
            cur_state = ""
        if cur_state in ("applying", "rolling-back", "downloading", "verifying"):
            return 0
        write_status({"state": "checking", "current": cur})
        base = resolve_base_url()
        if not base:
            write_status({"state": "error", "current": cur, "message": "no update URL configured"})
            return 0
        if not base.endswith("/"):
            base += "/"
        url = base + "manifest.json"
        try:
            with urllib.request.urlopen(ua_request(url), timeout=15) as r:
                raw = r.read(65536)
            manifest = json.loads(raw.decode("utf-8"))
        except Exception:
            write_status({"state": "error", "current": cur, "message": "could not reach update server"})
            return 0
        avail = str(manifest.get("version", "")).strip()
        if not VERSION_RE.match(avail):
            write_status({"state": "error", "current": cur, "message": "invalid manifest version"})
            return 0
        if VERSION_RE.match(cur) and avail <= cur:
            write_status({"state": "up-to-date", "current": cur})
        else:
            write_status({"state": "update-available", "current": cur, "available": avail})
        return 0

    if __name__ == "__main__":
        sys.exit(main())
  '';

  # ----- The security gate (the single most important line in the arc) -----
  # Verifies a detached minisign signature of the RAW image against the baked
  # pubkey. exit 0 = trusted; ANY non-zero = REJECT. Later-phase callers MUST
  # refuse to apply on non-zero and delete the staged candidate. Verify runs on
  # the decompressed RAW image (no decompress-then-trust gap). minisign
  # auto-detects the prehash from the signature; -H is passed explicitly to match
  # the ratified scheme. Distinct non-zero codes aid later-phase diagnostics.
  verify = pkgs.writeShellScriptBin "cloudunit-update-verify" ''
    set -u
    PUB="${pubKeyPath}"
    img="''${1:-}"
    [ -n "$img" ]         || { echo "REJECT: usage: cloudunit-update-verify <image>" >&2; exit 2; }
    [ -f "$img" ]         || { echo "REJECT: image not found: $img" >&2; exit 2; }
    [ -f "$img.minisig" ] || { echo "REJECT: missing signature: $img.minisig" >&2; exit 3; }
    [ -r "$PUB" ]         || { echo "REJECT: pubkey unreadable: $PUB" >&2; exit 4; }
    if ${pkgs.minisign}/bin/minisign -V -H -p "$PUB" -m "$img" >/dev/null 2>&1; then
      echo "VERIFY OK: $img (signature trusted by $PUB)"; exit 0
    else
      echo "REJECT: signature verification FAILED for $img" >&2; exit 1
    fi
  '';

  # ----- U3 download + stage + verify (NO apply) -----
  # On "Install now": re-read the manifest, download the image, sha256 integrity
  # pre-check, download the detached sig, decompress to the RAW candidate, run the
  # security gate (verify above), then fs/size/label constraints. On ANY failure:
  # clean up ALL staged files and surface a clear state. On success: state
  # staged-ok with the candidate + sig retained for the (future) apply phase.
  # Tools (zstd/e2fsprogs/util-linux/the verify helper) come via the service PATH,
  # so this script carries no Nix interpolation. NO reflash, NO p2/p3 write here.
  stageScript = pkgs.writeText "cloudunit-update-stage.py" ''
    import hashlib, json, os, re, shutil, subprocess, sys, urllib.parse, urllib.request

    DATA_DIR = "${dataDir}"
    UPDATE_DIR = os.path.join(DATA_DIR, "update")
    STATUS = os.path.join(UPDATE_DIR, "status.json")
    DOWNLOAD = os.path.join(UPDATE_DIR, "download.img.zst")
    CANDIDATE = os.path.join(UPDATE_DIR, "candidate.img")
    CANDIDATE_SIG = CANDIDATE + ".minisig"
    PRE_UPDATE_DUMPS = os.path.join(UPDATE_DIR, "pre-update-dumps")
    OVERRIDE = os.path.join(DATA_DIR, "update.conf")
    BAKED_URL = "/etc/cloudunit/update/url"
    VERSION_FILE = "/etc/cloudunit/update/version"
    P2_DEV = "/dev/disk/by-label/NIXOS_SD"

    VERSION_RE = re.compile(r"^[0-9]{4}\.[0-9]{2}\.[0-9]{2}(-[0-9]+)?$")
    SHA_RE = re.compile(r"^[0-9a-f]{64}$")
    DEVNULL = subprocess.DEVNULL

    def write_status(obj):
        os.makedirs(UPDATE_DIR, exist_ok=True)
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f)
            f.write("\n")
        os.replace(tmp, STATUS)

    def read_first_line(path):
        try:
            with open(path) as f:
                return f.read().strip()
        except OSError:
            return ""

    def resolve_base_url():
        try:
            with open(OVERRIDE) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("UPDATE_BASE_URL="):
                        v = line.split("=", 1)[1].strip()
                        if v:
                            return v
        except OSError:
            pass
        return read_first_line(BAKED_URL)

    def ua_request(url):
        # Same UA hardening as the check script (DEVLOG 2026-07-23).
        ua = "Keephaven-Update/" + (read_first_line(VERSION_FILE) or "unknown")
        return urllib.request.Request(url, headers={"User-Agent": ua})

    def cleanup():
        for p in (DOWNLOAD, CANDIDATE, CANDIDATE_SIG):
            try:
                os.remove(p)
            except OSError:
                pass

    def fail(cur, avail, message, state="failed"):
        cleanup()
        obj = {"state": state, "current": cur, "message": message}
        if avail:
            obj["available"] = avail
        write_status(obj)
        return 1

    def download(url, dest, cap_bytes):
        with urllib.request.urlopen(ua_request(url), timeout=30) as r:
            written = 0
            with open(dest, "wb") as f:
                while True:
                    chunk = r.read(1048576)
                    if not chunk:
                        break
                    written += len(chunk)
                    if written > cap_bytes:
                        raise IOError("download exceeded size cap")
                    f.write(chunk)
        return written

    def sha256_file(path):
        h = hashlib.sha256()
        with open(path, "rb") as f:
            for chunk in iter(lambda: f.read(1048576), b""):
                h.update(chunk)
        return h.hexdigest()

    def p2_size():
        try:
            out = subprocess.run(["blockdev", "--getsize64", P2_DEV],
                                 capture_output=True, text=True)
            s = out.stdout.strip()
            if out.returncode == 0 and s.isdigit():
                return int(s)
        except Exception:
            pass
        return None

    def validate_fs(path):
        expected = p2_size()
        if expected is None:
            return (False, "cannot read system partition size")
        if os.path.getsize(path) != expected:
            return (False, "image size does not match the system partition")
        if subprocess.run(["e2fsck", "-fn", path], stdout=DEVNULL, stderr=DEVNULL).returncode != 0:
            return (False, "image filesystem is not clean")
        lbl = subprocess.run(["e2label", path], capture_output=True, text=True).stdout.strip()
        if lbl == "NIXOS_SD":
            return (False, "image must not carry the system label while staged")
        r = subprocess.run(["debugfs", "-R", "stat /nix/store", path],
                           capture_output=True, text=True)
        if r.returncode != 0 or "Type: directory" not in r.stdout:
            return (False, "image missing /nix/store")
        return (True, "ok")

    def rel_join(base, rel):
        if "://" in rel or rel.startswith("//"):
            return None
        return urllib.parse.urljoin(base, rel)

    def main():
        cur = read_first_line(VERSION_FILE)
        try:
            st = json.load(open(STATUS))
        except Exception:
            st = {}
        if st.get("state") != "update-available":
            write_status({"state": "error", "current": cur, "message": "no update available to install"})
            return 1

        # ---- PRE-UPDATE DATABASE DUMP (the standing HARD PREREQUISITE) --------
        # decisions.md: an update that changes a service image can trigger an
        # IRREVERSIBLE database migration, and an OS rollback cannot undo it --
        # the initrd reflash writes only p2 and never touches p4. Without a dump
        # taken beforehand there is no recovery path at all.
        #
        # It happens HERE, in STAGE, not in apply. Apply arms the boot marker and
        # reboots in the same breath (applyArmScript), so a dump there would sit
        # between the owner clicking "restart now" and the restart, forcing a
        # choice between stalling a reboot already in motion and proceeding with
        # no backup. Stage is the calm moment: nothing is committed, the box is
        # already about to spend minutes downloading ~3 GB, and a failure here
        # costs the owner nothing but a retry.
        #
        # UNCONDITIONAL -- we do not try to detect whether this particular
        # candidate changes a service digest. Detection would mean reading the
        # candidate's image pins from inside the update flow, which is fiddly and
        # fails OPEN (a missed detection = an unprotected migration). A dump costs
        # a few hundred MB and ~30 s; always paying it is strictly safer.
        rc = subprocess.call(["${dumpWrapper}", PRE_UPDATE_DUMPS, "2"])
        if rc == 2:
            # Nothing to protect (no Immich env, or no database container). There
            # is no data at risk, so an update must not be blocked by its absence.
            print("pre-update dump: nothing to protect; continuing", flush=True)
        elif rc != 0:
            # A database IS present and we could not back it up. Proceeding would
            # walk into precisely the unrecoverable case this gate exists to
            # prevent, so stop -- the owner stays on a working version and can
            # retry or call support. This is the one thing worth failing an
            # update for.
            # A DISTINCT state, not the generic "failed": nothing broke and
            # nothing was changed -- the update was deliberately HELD, and the
            # owner needs to know that plus what to do. A silent or merely
            # missing banner would be its own support call.
            return fail(cur, None,
                        "could not back up the photo database before updating",
                        state="held")
        else:
            print("pre-update dump: written", flush=True)

        base = resolve_base_url()
        if not base:
            return fail(cur, None, "no update URL configured")
        if not base.endswith("/"):
            base += "/"
        try:
            with urllib.request.urlopen(ua_request(base + "manifest.json"), timeout=15) as r:
                manifest = json.loads(r.read(65536).decode("utf-8"))
        except Exception:
            return fail(cur, None, "could not reach update server")
        ver = str(manifest.get("version", "")).strip()
        img_url = manifest.get("image_url", "")
        sig_url = manifest.get("image_sig_url", "")
        sha = str(manifest.get("image_sha256", "")).strip().lower()
        if not VERSION_RE.match(ver):
            return fail(cur, None, "invalid manifest version")
        if not SHA_RE.match(sha):
            return fail(cur, ver, "invalid manifest hash")
        iu = rel_join(base, img_url) if img_url else None
        su = rel_join(base, sig_url) if sig_url else None
        if not iu or not su:
            return fail(cur, ver, "manifest image/signature url invalid")
        cap = manifest.get("image_size_compressed")
        cap = int(cap) + 16 * 1048576 if isinstance(cap, int) else 8 * 1024 * 1048576
        write_status({"state": "downloading", "current": cur, "available": ver})
        try:
            download(iu, DOWNLOAD, cap)
        except Exception:
            return fail(cur, ver, "download failed")
        if sha256_file(DOWNLOAD) != sha:
            return fail(cur, ver, "download integrity check failed")
        try:
            download(su, CANDIDATE_SIG, 1048576)
        except Exception:
            return fail(cur, ver, "signature download failed")
        write_status({"state": "verifying", "current": cur, "available": ver})
        try:
            with open(CANDIDATE, "wb") as out:
                p = subprocess.run(["zstd", "-d", "-q", "-c", DOWNLOAD], stdout=out, stderr=DEVNULL)
            if p.returncode != 0:
                raise IOError("zstd failed")
        except Exception:
            return fail(cur, ver, "decompress failed")
        try:
            os.remove(DOWNLOAD)
        except OSError:
            pass
        # THE SECURITY GATE — minisign verify of the RAW image against the baked pubkey.
        if subprocess.run(["cloudunit-update-verify", CANDIDATE], stdout=DEVNULL, stderr=DEVNULL).returncode != 0:
            return fail(cur, ver, "update could not be verified and was not installed",
                        state="failed-verification")
        ok, msg = validate_fs(CANDIDATE)
        if not ok:
            return fail(cur, ver, msg)
        write_status({"state": "staged-ok", "current": cur, "available": ver})
        return 0

    if __name__ == "__main__":
        sys.exit(main())
  '';

  # ----- U4 APPLY: userspace arming (authenticated trigger -> reboot) -----
  # Validates the staged-ok candidate, RE-verifies the signature (defense), reads
  # p2/p4 geometry from /sys (where p4 IS surfaced), records everything the
  # GPT-parser-free initrd block needs into a FIRMWARE marker, writes the p4
  # apply-pending breadcrumb (drives confirm/watchdog), then reboots. Does NOT
  # write p2/p3. p3 stays OLD known-good.
  applyArmScript = pkgs.writeText "cloudunit-update-apply-arm.py" ''
    import glob, json, os, shutil, subprocess, sys

    DATA_DIR = "${dataDir}"
    UPDATE_DIR = os.path.join(DATA_DIR, "update")
    STATUS = os.path.join(UPDATE_DIR, "status.json")
    CANDIDATE = os.path.join(UPDATE_DIR, "candidate.img")
    CANDIDATE_SIG = CANDIDATE + ".minisig"
    CAND_REL = "update/candidate.img"
    APPLY_PENDING = os.path.join(UPDATE_DIR, "apply-pending")
    VERSION_FILE = "/etc/cloudunit/update/version"
    FW_DEV = "/dev/disk/by-label/FIRMWARE"
    P2_LABEL = "/dev/disk/by-label/NIXOS_SD"
    P4_LABEL = "/dev/disk/by-label/cloudunit-data"
    FW_MNT = "/run/cloudunit-update-fw"
    CAND_MNT = "/run/cloudunit-update-cand"
    APPLY_MARKER = "cloudunit-update-apply"
    BOOTCOUNT = "cloudunit-update-bootcount"

    def write_status(obj):
        os.makedirs(UPDATE_DIR, exist_ok=True)
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f); f.write("\n")
        os.replace(tmp, STATUS)

    def read_first_line(p):
        try:
            with open(p) as f:
                return f.read().strip()
        except OSError:
            return ""

    def part_geom(label):
        dev = os.path.realpath(label)
        name = os.path.basename(dev)
        sysdir = "/sys/class/block/" + name
        start = int(read_first_line(sysdir + "/start")) * 512
        size = int(read_first_line(sysdir + "/size")) * 512
        disk = os.path.basename(os.path.dirname(os.path.realpath(sysdir)))
        return ("/dev/" + disk, dev, start, size)

    def umount_all(mounts):
        for m in reversed(mounts):
            subprocess.run(["umount", m], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def fail(cur, message, mounts=()):
        umount_all(mounts)
        write_status({"state": "failed", "current": cur, "message": message})
        return 1

    def resolve_in(root, path):
        # Resolve an absolute /nix/store symlink chain WITHIN the candidate root.
        cur = path
        for _ in range(64):
            full = root + cur
            if os.path.islink(full):
                t = os.readlink(full)
                cur = t if t.startswith("/") else os.path.normpath(os.path.join(os.path.dirname(cur), t))
            else:
                return cur
        raise RuntimeError("symlink loop")

    def regen_default(cand, top, fw_nixos):
        # Replicate kernelboot-gen-builder + install-device-tree for the NEW
        # generation into default.new, validate, then swap default<-default.new.
        new = os.path.join(fw_nixos, "default.new")
        shutil.rmtree(new, ignore_errors=True)
        os.makedirs(os.path.join(new, "overlays"), exist_ok=True)
        shutil.copyfile(cand + resolve_in(cand, top + "/kernel"), os.path.join(new, "kernel.img"))
        shutil.copyfile(cand + resolve_in(cand, top + "/initrd"), os.path.join(new, "initrd"))
        with open(cand + top + "/kernel-params") as f:
            kp = f.read().strip()
        with open(os.path.join(new, "cmdline.txt"), "w") as f:
            f.write(kp + " init=" + top + "/init\n")
        dtbs = resolve_in(cand, top + "/dtbs")
        for pat in (cand + dtbs + "/*.dtb", cand + dtbs + "/broadcom/*.dtb"):
            for src in glob.glob(pat):
                shutil.copyfile(src, os.path.join(new, os.path.basename(src)))
        for src in glob.glob(cand + dtbs + "/overlays/*"):
            if os.path.isfile(src):
                shutil.copyfile(src, os.path.join(new, "overlays", os.path.basename(src)))
        # Validate the regenerated boot dir BEFORE committing it.
        for n in ("kernel.img", "initrd", "cmdline.txt"):
            if not os.path.exists(os.path.join(new, n)):
                raise RuntimeError("missing " + n)
        if not glob.glob(os.path.join(new, "bcm2712-rpi-5-b*.dtb")):
            raise RuntimeError("missing pi5 dtb")
        with open(os.path.join(new, "cmdline.txt")) as f:
            if ("init=" + top + "/init") not in f.read():
                raise RuntimeError("cmdline init mismatch")
        default = os.path.join(fw_nixos, "default")
        bkp = os.path.join(fw_nixos, "default.bkp")
        shutil.rmtree(bkp, ignore_errors=True)
        if os.path.exists(default):
            os.rename(default, bkp)
        os.rename(new, default)
        subprocess.run(["sync"])
        shutil.rmtree(bkp, ignore_errors=True)

    def main():
        cur = read_first_line(VERSION_FILE)
        try:
            st = json.load(open(STATUS))
        except Exception:
            st = {}
        if st.get("state") != "staged-ok":
            return fail(cur, "no staged update to apply")
        ver = st.get("available", "")
        if not (os.path.exists(CANDIDATE) and os.path.exists(CANDIDATE_SIG)):
            return fail(cur, "staged update files are missing")
        if subprocess.run(["cloudunit-update-verify", CANDIDATE],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            return fail(cur, "staged update failed re-verification")
        try:
            disk, p2dev, p2start, p2size = part_geom(P2_LABEL)
            _, p4dev, p4start, p4size = part_geom(P4_LABEL)
        except Exception:
            return fail(cur, "could not read partition geometry")
        if os.path.getsize(CANDIDATE) != p2size:
            return fail(cur, "candidate size does not match the system partition")

        mounts = []
        # Mount the candidate (ro loop) to read its baked toplevel + boot files.
        os.makedirs(CAND_MNT, exist_ok=True)
        if subprocess.run(["mount", "-o", "ro,loop", CANDIDATE, CAND_MNT],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            return fail(cur, "could not open the update image")
        mounts.append(CAND_MNT)
        try:
            # gate #1: TOP is READ from the baked pointer, then cross-checked.
            link = os.path.join(CAND_MNT, "cloudunit-system")
            if not os.path.islink(link):
                return fail(cur, "update image missing system pointer", mounts)
            top = os.readlink(link)
            attest = read_first_line(CAND_MNT + top + "/cloudunit-toplevel")
            if attest != top:
                return fail(cur, "update image toplevel attestation mismatch", mounts)
            for n in ("init", "kernel", "initrd", "kernel-params", "dtbs"):
                if not os.path.exists(CAND_MNT + top + "/" + n):
                    return fail(cur, "update image incomplete (%s)" % n, mounts)

            os.makedirs(FW_MNT, exist_ok=True)
            if subprocess.run(["mount", "-t", "vfat", "-o", "rw", FW_DEV, FW_MNT],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
                return fail(cur, "could not open the boot partition", mounts)
            mounts.append(FW_MNT)
            fw_nixos = os.path.join(FW_MNT, "nixos")
            default = os.path.join(fw_nixos, "default")
            # bug-B fix: apply does NOT touch nixos/rollback. It is the IMMUTABLE
            # known-good backup (baked at build, refreshed only by promote when p3
            # advances). regen_default keeps its own default.bkp during the swap,
            # which it restores from if the regen fails -- so apply is still
            # fail-closed without clobbering the known-good rollback.
            try:
                regen_default(CAND_MNT, top, fw_nixos)
            except Exception:
                bkp = os.path.join(fw_nixos, "default.bkp")
                if not os.path.exists(default) and os.path.exists(bkp):
                    os.rename(bkp, default)
                    subprocess.run(["sync"])
                return fail(cur, "could not install boot files", mounts)

            # Arm the p2 write (initrd) + the boot-prove counter + apply-pending.
            with open(APPLY_PENDING, "w") as f:
                f.write("APPLYING_VERSION=%s\n" % ver)
            marker = ("DISK=%s\nP2=%s\nP4_OFFSET=%d\nP4_SIZE=%d\nP2_SIZE=%d\n"
                      "CANDIDATE_REL=%s\nVERSION=%s\n"
                      % (disk, p2dev, p4start, p4size, p2size, CAND_REL, ver))
            with open(os.path.join(FW_MNT, APPLY_MARKER), "w") as f:
                f.write(marker)
            with open(os.path.join(FW_MNT, BOOTCOUNT), "w") as f:
                f.write("attempts=0 version=%s\n" % ver)
            subprocess.run(["sync"])
        finally:
            umount_all(mounts)

        write_status({"state": "applying", "current": cur, "available": ver})
        subprocess.run(["systemctl", "reboot"])
        return 0

    if __name__ == "__main__":
        sys.exit(main())
  '';

  # ----- U4 confirm (good-boot) — resolve apply-pending once the milestone is met.
  # Same milestone as cloudunit-recovery-reset (docker + bootstrap + dashboard if
  # set up). On a good boot of the NEW system: applied-ok. If we actually rolled
  # back (running != applying): rolled-back. Clears apply-pending. (U5 will add the
  # p2->p3 promote here.) Does NOT edit the recovery path.
  confirmScript = pkgs.writeText "cloudunit-update-confirm.py" ''
    import json, os, shutil, subprocess

    DATA_DIR = "${dataDir}"
    UPD = os.path.join(DATA_DIR, "update")
    STATUS = os.path.join(UPD, "status.json")
    PEND = os.path.join(UPD, "apply-pending")
    CANDIDATE = os.path.join(UPD, "candidate.img")
    CANDIDATE_SIG = CANDIDATE + ".minisig"
    SETUP = os.path.join(DATA_DIR, ".setup-complete")
    VERSION_FILE = "/etc/cloudunit/update/version"
    FW_DEV = "/dev/disk/by-label/FIRMWARE"
    FW_MNT = "/run/cloudunit-update-fw-confirm"
    BOOTCOUNT = "cloudunit-update-bootcount"
    P3_DEV = "/dev/disk/by-partlabel/cloudunit-recovery"

    def active(u):
        return subprocess.run(["systemctl", "is-active", "--quiet", u]).returncode == 0

    def result_ok(u):
        r = subprocess.run(["systemctl", "show", "-p", "Result", "--value", u],
                           capture_output=True, text=True)
        return r.stdout.strip() == "success"

    def docker_running():
        # bug-A fix: a started-but-dead service must NOT count as healthy. Require
        # dockerd ACTUALLY up (ActiveState=active AND SubState=running), not a bare
        # is-active snapshot a forked-then-exited service can race through.
        r = subprocess.run(["systemctl", "show", "-p", "ActiveState", "-p", "SubState", "docker.service"],
                           capture_output=True, text=True)
        return "ActiveState=active" in r.stdout and "SubState=running" in r.stdout

    def milestone():
        if not docker_running():
            return False
        if not (active("cloudunit-unit-bootstrap.service") or result_ok("cloudunit-unit-bootstrap.service")):
            return False
        if os.path.exists(SETUP) and not active("cloudunit-dashboard.service"):
            return False
        return True

    def applying_version():
        try:
            for line in open(PEND):
                if line.startswith("APPLYING_VERSION="):
                    return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return ""

    def clear_bootcount():
        os.makedirs(FW_MNT, exist_ok=True)
        if subprocess.run(["mount", "-t", "vfat", "-o", "rw", FW_DEV, FW_MNT]).returncode == 0:
            try:
                try:
                    os.remove(os.path.join(FW_MNT, BOOTCOUNT))
                except OSError:
                    pass
                subprocess.run(["sync"])
            finally:
                subprocess.run(["umount", FW_MNT])

    def promote():
        # U5 promote (caller-gated on hardened milestone AND running==applying, so a
        # broken-but-newer image is NEVER promoted): make the proven NEW generation
        # the rescue copy, COHERENTLY. p3 <- candidate (NEW root); nixos/rollback <-
        # nixos/default (NEW boot files) so the immutable known-good backup advances
        # with p3; clear bootcount; drop the staged candidate.
        ok = os.path.exists(CANDIDATE) and os.path.exists(P3_DEV) and \
            subprocess.run(["dd", "if=" + CANDIDATE, "of=" + P3_DEV, "bs=4M", "conv=fsync"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
        if ok:
            subprocess.run(["e2fsck", "-fy", P3_DEV], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        os.makedirs(FW_MNT, exist_ok=True)
        if subprocess.run(["mount", "-t", "vfat", "-o", "rw", FW_DEV, FW_MNT]).returncode == 0:
            try:
                nx = os.path.join(FW_MNT, "nixos")
                if ok and os.path.isdir(os.path.join(nx, "default")):
                    newr = os.path.join(nx, "rollback.new")
                    oldr = os.path.join(nx, "rollback.old")
                    shutil.rmtree(newr, ignore_errors=True)
                    shutil.copytree(os.path.join(nx, "default"), newr)
                    shutil.rmtree(oldr, ignore_errors=True)
                    if os.path.exists(os.path.join(nx, "rollback")):
                        os.rename(os.path.join(nx, "rollback"), oldr)
                    os.rename(newr, os.path.join(nx, "rollback"))
                    shutil.rmtree(oldr, ignore_errors=True)
                try:
                    os.remove(os.path.join(FW_MNT, BOOTCOUNT))
                except OSError:
                    pass
                subprocess.run(["sync"])
            finally:
                subprocess.run(["umount", FW_MNT])
        if ok:
            for p in (CANDIDATE, CANDIDATE_SIG):
                try:
                    os.remove(p)
                except OSError:
                    pass

    def resolve():
        applying = applying_version()
        running = ""
        try:
            running = open(VERSION_FILE).read().strip()
        except OSError:
            pass
        if applying and applying == running:
            promote()
            state = "applied-ok"
        else:
            state = "rolled-back"
            clear_bootcount()
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"state": state, "current": running, "available": applying}, f); f.write("\n")
        os.replace(tmp, STATUS)
        try:
            os.remove(PEND)
        except OSError:
            pass

    def main():
        if not os.path.exists(PEND):
            return 0
        if not milestone():
            return 0
        resolve()
        return 0

    main()
  '';

  # ----- U4 boot-prove watchdog (timeout) — if apply-pending is STILL present
  # after the boot window, the NEW system never reached the milestone (boots-but-
  # broken). Roll back by setting the EXISTING cloudunit-reflash marker (its real
  # purpose: restore p3 OLD -> p2) and rebooting. If the milestone IS met by now
  # (slow-but-good), resolve like confirm instead. NEVER edits recovery code.
  watchdogScript = pkgs.writeText "cloudunit-update-bootprove.py" ''
    import json, os, shutil, subprocess

    DATA_DIR = "${dataDir}"
    UPD = os.path.join(DATA_DIR, "update")
    STATUS = os.path.join(UPD, "status.json")
    PEND = os.path.join(UPD, "apply-pending")
    SETUP = os.path.join(DATA_DIR, ".setup-complete")
    VERSION_FILE = "/etc/cloudunit/update/version"
    FW_DEV = "/dev/disk/by-label/FIRMWARE"
    FW_MNT = "/run/cloudunit-update-fw-wd"
    REFLASH_MARKER = "cloudunit-reflash"
    BOOTCOUNT = "cloudunit-update-bootcount"

    def active(u):
        return subprocess.run(["systemctl", "is-active", "--quiet", u]).returncode == 0

    def result_ok(u):
        r = subprocess.run(["systemctl", "show", "-p", "Result", "--value", u],
                           capture_output=True, text=True)
        return r.stdout.strip() == "success"

    def docker_running():
        r = subprocess.run(["systemctl", "show", "-p", "ActiveState", "-p", "SubState", "docker.service"],
                           capture_output=True, text=True)
        return "ActiveState=active" in r.stdout and "SubState=running" in r.stdout

    def milestone():
        if not docker_running():
            return False
        if not (active("cloudunit-unit-bootstrap.service") or result_ok("cloudunit-unit-bootstrap.service")):
            return False
        if os.path.exists(SETUP) and not active("cloudunit-dashboard.service"):
            return False
        return True

    def applying_version():
        try:
            for line in open(PEND):
                if line.startswith("APPLYING_VERSION="):
                    return line.split("=", 1)[1].strip()
        except OSError:
            pass
        return ""

    def write_status(obj):
        tmp = STATUS + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f); f.write("\n")
        os.replace(tmp, STATUS)

    def main():
        if not os.path.exists(PEND):
            return 0
        running = ""
        try:
            running = open(VERSION_FILE).read().strip()
        except OSError:
            pass
        applying = applying_version()
        if milestone():
            # slow-but-good: resolve like confirm.
            state = "applied-ok" if applying and applying == running else "rolled-back"
            write_status({"state": state, "current": running, "available": applying})
            try:
                os.remove(PEND)
            except OSError:
                pass
            return 0
        # boots-but-broken (reached userspace, milestone never met) -> GENERATION
        # rollback: revert p1 nixos/default <- nixos/rollback AND arm the existing
        # cloudunit-reflash (recovery restores p3->p2 OLD). Reverting p1 too keeps
        # the rollback coherent (else NEW p1 + OLD p2 mismatch). Same as the in-
        # initrd path, but here from userspace for the userspace-reached case.
        write_status({"state": "rolling-back", "current": running, "available": applying})
        os.makedirs(FW_MNT, exist_ok=True)
        if subprocess.run(["mount", "-t", "vfat", "-o", "rw", FW_DEV, FW_MNT]).returncode == 0:
            try:
                nx = os.path.join(FW_MNT, "nixos")
                default = os.path.join(nx, "default")
                rollback = os.path.join(nx, "rollback")
                if os.path.isdir(rollback):
                    newd = os.path.join(nx, "default.new")
                    oldd = os.path.join(nx, "default.old")
                    shutil.rmtree(newd, ignore_errors=True)
                    shutil.copytree(rollback, newd)
                    shutil.rmtree(oldd, ignore_errors=True)
                    if os.path.exists(default):
                        os.rename(default, oldd)
                    os.rename(newd, default)
                    shutil.rmtree(oldd, ignore_errors=True)
                open(os.path.join(FW_MNT, REFLASH_MARKER), "w").close()
                try:
                    os.remove(os.path.join(FW_MNT, BOOTCOUNT))
                except OSError:
                    pass
                subprocess.run(["sync"])
            finally:
                subprocess.run(["umount", FW_MNT])
            subprocess.run(["systemctl", "reboot"])
        return 0

    main()
  '';

  # Protected-surface apply trigger: a narrow no-arg wrapper the settings page
  # (cloudunit-web, via sudo -n) calls. Starts the arming unit; no user input.
  applyTrigger = pkgs.writeShellScriptBin "cloudunit-update-apply-trigger" ''
    exec ${pkgs.systemd}/bin/systemctl start --no-block cloudunit-update-apply.service
  '';

  # ----- U4 the ONE new boot-path component: additive initrd apply-writer -----
  # Runs via lib.mkBefore so it executes BEFORE the recovery health-check, which
  # then no-ops on the healthy NEW p2. Own subshell; exit 0 on EVERY abort. Reads
  # the FIRMWARE marker, applies the verified p4 candidate to p2, leaves p3 OLD.
  # NO GPT byte-parsing: offsets come from the marker. Does NOT touch any recovery
  # code; the existing reflash block is the auto-rollback.
  applyInitrd = ''
    (
      set +e
      ulog() { echo "CLOUDUNIT-UPDATE-APPLY: $*"; echo "CLOUDUNIT-UPDATE-APPLY: $*" > /dev/kmsg 2>/dev/null || true; }
      kv() { printf '%s\n' "$2" | awk -v d="$1" -F= '$1==d{print $2; exit}'; }

      udevadm settle --timeout=30 || true

      p2=$(readlink -f /dev/disk/by-label/NIXOS_SD 2>/dev/null)
      [ -n "$p2" ] && [ -b "$p2" ] || { ulog "no NIXOS_SD by-label; skip"; exit 0; }
      p2name=$(basename "$p2")
      disk=""
      for dd in /sys/block/*; do
        [ -e "$dd/$p2name" ] && disk=$(basename "$dd")
      done
      [ -n "$disk" ] && [ -b "/dev/$disk" ] || { ulog "cannot derive disk; skip"; exit 0; }

      fw=""
      for d in /sys/class/block/$disk/$disk*; do
        [ -f "$d/partition" ] || continue
        [ "$(cat $d/partition 2>/dev/null)" = "1" ] && fw=/dev/$(basename "$d")
      done
      [ -n "$fw" ] && [ -b "$fw" ] || { ulog "no firmware partition; skip"; exit 0; }

      mkdir -p /cloudunit-ufw
      mount -t vfat -o ro "$fw" /cloudunit-ufw 2>/dev/null || { ulog "fw mount failed; skip"; exit 0; }
      marker=""; bc=""
      [ -f /cloudunit-ufw/cloudunit-update-apply ] && marker=$(cat /cloudunit-ufw/cloudunit-update-apply 2>/dev/null)
      [ -f /cloudunit-ufw/cloudunit-update-bootcount ] && bc=$(cat /cloudunit-ufw/cloudunit-update-bootcount 2>/dev/null)
      umount /cloudunit-ufw 2>/dev/null || true

      # ---- generation-rollback: revert p1 nixos/default <- nixos/rollback (OLD
      # boot files), arm the EXISTING cloudunit-reflash marker (the recovery block
      # restores p3->p2 OLD), SYNC durable, then reboot so the firmware re-reads the
      # reverted p1. Gate #2 ordering: revert-p1 -> reflash -> SYNC -> reboot. ----
      gen_rollback() {
        if mount -t vfat -o rw "$fw" /cloudunit-ufw 2>/dev/null; then
          if [ -d /cloudunit-ufw/nixos/rollback ]; then
            rm -rf /cloudunit-ufw/nixos/default.new 2>/dev/null || true
            cp -a /cloudunit-ufw/nixos/rollback /cloudunit-ufw/nixos/default.new 2>/dev/null
            rm -rf /cloudunit-ufw/nixos/default.old 2>/dev/null || true
            mv /cloudunit-ufw/nixos/default /cloudunit-ufw/nixos/default.old 2>/dev/null || true
            mv /cloudunit-ufw/nixos/default.new /cloudunit-ufw/nixos/default 2>/dev/null
            rm -rf /cloudunit-ufw/nixos/default.old 2>/dev/null || true
          fi
          touch /cloudunit-ufw/cloudunit-reflash 2>/dev/null || true
          rm -f /cloudunit-ufw/cloudunit-update-bootcount 2>/dev/null || true
          sync
          umount /cloudunit-ufw 2>/dev/null || true
        fi
        ulog "generation-rollback: p1 reverted + reflash armed; rebooting to OLD"
        sync
        reboot -f
        exit 0
      }

      # ---- boot-prove counter: no apply marker but a bootcount => proving a
      # freshly-applied NEW image. If userspace never confirms (clears it) within
      # MAX boots, the NEW image is broken (incl. an initrd hang the userspace
      # watchdog can't see, since this runs in postDeviceCommands BEFORE switch_root)
      # -> generation-rollback. ----
      if [ -z "$marker" ]; then
        if [ -n "$bc" ]; then
          att=$(printf '%s\n' "$bc" | awk -F'[ =]' '{for(i=1;i<NF;i++) if($i=="attempts"){print $(i+1);exit}}')
          case "x$att" in x|x*[!0-9]*) att=0 ;; esac
          att=$(( att + 1 ))
          if [ "$att" -ge 3 ]; then
            ulog "boot-prove failed (attempt $att >= 3); rolling back generation"
            gen_rollback
          fi
          if mount -t vfat -o rw "$fw" /cloudunit-ufw 2>/dev/null; then
            printf 'attempts=%s\n' "$att" > /cloudunit-ufw/cloudunit-update-bootcount 2>/dev/null || true
            sync; umount /cloudunit-ufw 2>/dev/null || true
          fi
          ulog "boot-prove attempt $att (awaiting userspace confirm)"
          exit 0
        fi
        ulog "no apply marker; normal boot"
        exit 0
      fi

      m_p4off=$(kv P4_OFFSET "$marker"); m_p4size=$(kv P4_SIZE "$marker")
      m_p2size=$(kv P2_SIZE "$marker"); m_rel=$(kv CANDIDATE_REL "$marker")
      case "x$m_p4off$m_p4size$m_p2size" in x*[!0-9]*|x) ulog "marker offsets bad; abort"; exit 0 ;; esac
      [ -n "$m_rel" ] || { ulog "marker incomplete; abort"; exit 0; }

      p2bytes=$(blockdev --getsize64 "$p2" 2>/dev/null)
      [ "$p2bytes" = "$m_p2size" ] || { ulog "p2 size $p2bytes != marker $m_p2size; abort"; exit 0; }

      lp4=$(losetup -r -f --show -o "$m_p4off" --sizelimit "$m_p4size" /dev/$disk 2>/dev/null)
      [ -n "$lp4" ] && [ -b "$lp4" ] || { ulog "p4 losetup failed; abort"; exit 0; }
      mkdir -p /cloudunit-up4
      if ! mount -o ro,norecovery "$lp4" /cloudunit-up4 2>/dev/null; then
        losetup -d "$lp4" 2>/dev/null || true; ulog "p4 mount failed; abort"; exit 0
      fi
      cand="/cloudunit-up4/$m_rel"
      cleanup_p4() { umount /cloudunit-up4 2>/dev/null || true; losetup -d "$lp4" 2>/dev/null || true; }
      [ -f "$cand" ] || { cleanup_p4; ulog "candidate missing; abort"; exit 0; }

      # SECURITY GATE (U4.1): verify the candidate signature against the BAKED
      # pubkey BEFORE any structural check or write. The .minisig was staged on p4
      # beside the candidate. Forging this needs the OFFLINE private key -- root
      # write of p4 + the FIRMWARE marker is NOT enough (unlike the old sha-binding).
      minisign -V -H -P "${pubKeyB64}" -m "$cand" >/dev/null 2>&1 || { cleanup_p4; ulog "candidate signature verification FAILED; abort"; exit 0; }

      lc=$(losetup -r -f --show "$cand" 2>/dev/null)
      cleanup_all() { losetup -d "$lc" 2>/dev/null || true; cleanup_p4; }
      [ -n "$lc" ] && [ -b "$lc" ] || { cleanup_p4; ulog "candidate losetup failed; abort"; exit 0; }

      candbytes=$(blockdev --getsize64 "$lc" 2>/dev/null)
      [ "$candbytes" = "$m_p2size" ] || { cleanup_all; ulog "candidate size $candbytes != $m_p2size; abort"; exit 0; }
      e2fsck -fn "$lc" >/dev/null 2>&1 || { cleanup_all; ulog "candidate not e2fsck-clean; abort"; exit 0; }
      clabel=$(tune2fs -l "$lc" 2>/dev/null | awk -F: '/Filesystem volume name/{gsub(/^[ \t]+/,"",$2);print $2}')
      [ "$clabel" = "NIXOS_SD" ] && { cleanup_all; ulog "candidate has NIXOS_SD label; abort"; exit 0; }
      mkdir -p /cloudunit-ucand; nixok=1
      if mount -o ro,norecovery "$lc" /cloudunit-ucand 2>/dev/null; then
        [ -d /cloudunit-ucand/nix/store ] && nixok=0
        umount /cloudunit-ucand 2>/dev/null || true
      fi
      [ "$nixok" = "0" ] || { cleanup_all; ulog "candidate missing /nix/store; abort"; exit 0; }

      ulog "validation passed; writing p2 (version $(kv VERSION "$marker"))"
      ddok=1
      if [ "$(( m_p2size % 1048576 ))" -eq 0 ]; then
        dd if="$lc" of="$p2" bs=1M count=$(( m_p2size / 1048576 )) conv=fsync 2>/dev/null && ddok=0
      else
        dd if="$lc" of="$p2" bs=4M conv=fsync 2>/dev/null && ddok=0
      fi
      sync; blockdev --flushbufs "$p2" 2>/dev/null || true
      cleanup_all
      [ "$ddok" -eq 0 ] || { ulog "dd failed; p2 may be partial -> recovery will catch corrupt p2"; exit 0; }

      tune2fs -L NIXOS_SD "$p2" >/dev/null 2>&1 || true
      e2fsck -fy "$p2" >/dev/null 2>&1
      udevadm trigger --action=change "$p2" 2>/dev/null || true
      udevadm settle --timeout=30 2>/dev/null || true
      if [ ! -e /dev/disk/by-label/NIXOS_SD ] || [ "$(readlink -f /dev/disk/by-label/NIXOS_SD 2>/dev/null)" != "$(readlink -f $p2)" ]; then
        mkdir -p /dev/disk/by-label 2>/dev/null || true
        ln -sf "$p2" /dev/disk/by-label/NIXOS_SD 2>/dev/null || true
      fi

      # Clear the apply marker + arm the boot-prove counter (attempt 1). p1 is
      # already NEW (arm regenerated nixos/default), so switch_root into NEW p2
      # boots the matched NEW generation.
      if mount -t vfat -o rw "$fw" /cloudunit-ufw 2>/dev/null; then
        rm -f /cloudunit-ufw/cloudunit-update-apply 2>/dev/null || true
        printf 'attempts=1 version=%s\n' "$(kv VERSION "$marker")" > /cloudunit-ufw/cloudunit-update-bootcount 2>/dev/null || true
        sync; umount /cloudunit-ufw 2>/dev/null || true
      fi
      ulog "apply complete; booting NEW p2 (boot-prove attempt 1; p3 still OLD)"
      exit 0
    ) || true
  '';
in
{
  options.keephaven.imageVersion = lib.mkOption {
    type = lib.types.str;
    default = "2026.10.04";
    description = ''
      This build's update version, baked to /etc/cloudunit/update/version and
      compared (zero-padded lexical) against the vendor manifest. Owner bumps it
      per release; the SAME string names the published image + manifest. Format:
      YYYY.MM.DD, zero-padded, optional -N suffix for same-day rebuilds.
    '';
  };

  options.keephaven.updateBaseUrl = lib.mkOption {
    type = lib.types.str;
    # The real vendor host: Cloudflare R2 bucket "keephaven-updates" behind the
    # custom domain. The bench can still point at a local http.server via the p4
    # update.conf override (which wins over this baked value) — no rebuild to test.
    default = "https://updates.keephaven.co/";
    description = ''
      Baked default update base URL (serves manifest.json + image + .minisig as
      plain static files). Overridden at runtime by UPDATE_BASE_URL in
      /var/lib/cloudunit/update.conf (the bench override).
    '';
  };

  config = {
    # Ship the upstream time-wait-sync unit (not in the NixOS default set). It is
    # NOT wantedBy sysinit (would block boot offline) — only the update check
    # pulls it in via Wants above. Shared config => no third diff-closures root.
    systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];

    # Baked trust anchor. PUBLIC key only; identical in both twins => no third
    # diff-closures root. The matching private key is never in this repo/image.
    environment.etc."cloudunit/update/keephaven-update.pub".source =
      ../keys/keephaven-update.pub;

    # Baked running-version + default URL (both profile-independent => no 3rd root).
    environment.etc."cloudunit/update/version".text =
      config.keephaven.imageVersion + "\n";
    environment.etc."cloudunit/update/url".text =
      config.keephaven.updateBaseUrl + "\n";

    # Expose the verify gate on PATH (later phases call it; bench can inspect it).
    environment.systemPackages = [ verify ];

    # ----- U4-rework gate #1: DETERMINISTIC baked toplevel pointer -----
    # The generation-aware apply must write p1's cmdline.txt as `init=<TOP>/init`,
    # where TOP is THIS image's toplevel store path. A wrong TOP re-bricks. So we
    # BAKE it, never discover it:
    #  (a) a fixed symlink /cloudunit-system -> <toplevel> in every root fs, via
    #      sdImage.populateRootCommands (downstream of toplevel => cycle-free), and
    #  (b) a self-attestation file <toplevel>/cloudunit-toplevel == its own path,
    #      via system.extraSystemBuilderCmds (runs in the toplevel build, $out set).
    # arm reads /cloudunit-system from the mounted candidate and cross-checks it
    # against the self-attest file; mismatch/missing => abort (never write a bad
    # init=). Profile-independent => twin stays two-rooted.
    system.systemBuilderCommands = lib.mkAfter ''
      echo -n "$out" > "$out/cloudunit-toplevel"
    '';
    sdImage.populateRootCommands = lib.mkAfter ''
      ln -sf ${config.system.build.toplevel} ./files/cloudunit-system
    '';

    # ----- U4-rework bug-B fix: IMMUTABLE known-good boot-file backup -----
    # nixos/rollback mirrors the KNOWN-GOOD (p3) generation. It is written ONLY at
    # build (here = the flashed gen) and at promote (when p3 advances) -- NEVER at
    # apply. That is the whole fix: a second sequential apply can no longer clobber
    # the OLD backup, so generation-rollback always has the correct p1 source. The
    # generations-builder has just created ./firmware/nixos/default (the flashed
    # gen); copy it to nixos/rollback so the very first rollback is coherent.
    sdImage.populateFirmwareCommands = lib.mkAfter ''
      cp -r ./firmware/nixos/default ./firmware/nixos/rollback
    '';

    # U2: periodic detect+notify poll. oneshot writes status.json; NO apply.
    systemd.services.cloudunit-update-check = {
      description = "Cloud Unit - check vendor manifest for updates (detect+notify only)";
      # Pi 5 has no RTC: at OnBootSec=3min the clock can still be unsynced, and a
      # wrong clock fails https certificate validation against the update host.
      # time-sync.target alone is weak (reached when timesyncd STARTS, not when
      # the clock is synced) — systemd-time-wait-sync waits for kernel-confirmed
      # sync. Wants (not Requires): offline, the job just stays queued until the
      # clock syncs — an offline check could not succeed anyway.
      after = [ "network-online.target" "time-sync.target" "systemd-time-wait-sync.service" ];
      wants = [ "network-online.target" "systemd-time-wait-sync.service" ];
      unitConfig.RequiresMountsFor = dataDir;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${checkScript}";
      };
    };

    systemd.timers.cloudunit-update-check = {
      description = "Cloud Unit - periodic update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "3min";
        OnUnitActiveSec = "1d";
        Persistent = true;
      };
    };

    # U3: download + stage + verify (NO apply). Started on demand by the dashboard
    # "Install now" action; not wantedBy anything. Tools are provided via PATH so
    # the embedded script needs no Nix interpolation.
    systemd.services.cloudunit-update-stage = {
      description = "Cloud Unit - download, stage and verify a candidate update (no apply)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      unitConfig.RequiresMountsFor = dataDir;
      path = [ pkgs.zstd pkgs.e2fsprogs pkgs.util-linux verify ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${stageScript}";
      };
    };

    # U4 arming: started (no-block) by the protected settings trigger. Validates +
    # re-verifies the staged candidate, writes the FIRMWARE marker + apply-pending,
    # then reboots. Runs as root (writes FIRMWARE, reboots).
    systemd.services.cloudunit-update-apply = {
      description = "Cloud Unit - arm a staged update and reboot to apply (no p2/p3 write here)";
      unitConfig.RequiresMountsFor = dataDir;
      path = [ pkgs.util-linux pkgs.coreutils pkgs.systemd verify ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${applyArmScript}";
      };
    };

    # U4 confirm: resolve apply-pending once the confirmed-good milestone is met.
    systemd.services.cloudunit-update-confirm = {
      description = "Cloud Unit - confirm a freshly-applied update after a good boot";
      wantedBy = [ "multi-user.target" ];
      after = [ "docker.service" "cloudunit-unit-bootstrap.service" "cloudunit-dashboard.service" ];
      unitConfig.ConditionPathExists = "${dataDir}/update/apply-pending";
      path = [ pkgs.util-linux pkgs.coreutils pkgs.e2fsprogs pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${pkgs.python3}/bin/python3 ${confirmScript}";
      };
    };

    # U4 boot-prove watchdog: if apply-pending is STILL present after the window,
    # the NEW system never reached the milestone -> roll back via the existing
    # cloudunit-reflash trigger. Generous window to avoid false rollback on a slow
    # (but healthy) cold boot; tune on the dev twin.
    systemd.services.cloudunit-update-bootprove = {
      description = "Cloud Unit - roll back an update that fails to reach a healthy boot";
      unitConfig.ConditionPathExists = "${dataDir}/update/apply-pending";
      path = [ pkgs.util-linux pkgs.coreutils pkgs.systemd ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${watchdogScript}";
      };
    };
    systemd.timers.cloudunit-update-bootprove = {
      description = "Cloud Unit - update boot-prove timeout";
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; };
    };

    # The protected-surface trigger wrapper + its narrow sudo grant for the
    # settings web user (cloudunit-web). Single fixed no-arg action.
    cloudunit.wrappers.updateApply = "${applyTrigger}/bin/cloudunit-update-apply-trigger";
    security.sudo.extraRules = [{
      users = [ "cloudunit-web" ];
      commands = [{
        command = "${applyTrigger}/bin/cloudunit-update-apply-trigger";
        options = [ "NOPASSWD" ];
      }];
    }];

    # The ONE new boot-path component: the additive initrd apply-writer. mkBefore
    # so it runs BEFORE the recovery health-check (which then no-ops on healthy
    # NEW p2). sha256sum is added to stage-1 for the candidate integrity binding;
    # vfat/losetup/e2fsck/tune2fs/blockdev are already provided by disk-layout.nix.
    boot.initrd.extraUtilsCommands = ''
      # U4.1: in-initrd signature verification. minisign is a small glibc binary
      # (libsodium auto-follows; libc/ld-linux already in stage-1 via e2fsck) pulled
      # by the same copy_bin_and_libs path. Replaces the sha256 integrity binding so
      # the update channel is trustworthy-under-compromise (forging a candidate needs
      # the OFFLINE private key, not just root write of p4 + the FIRMWARE marker).
      copy_bin_and_libs ${pkgs.minisign}/bin/minisign
    '';
    boot.initrd.postDeviceCommands = lib.mkBefore applyInitrd;
  };
}
