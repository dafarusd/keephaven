def regen_default(cand, top, fw_nixos):
    # PC: the finished boot file travels INSIDE the candidate — pc-hardware.nix builds
    # linux.efi once and puts the same artifact on p1 and at /boot/linux.efi in the system
    # partition — so this is a copy, a check and a swap. No kernel is reassembled on the
    # owner's PC, which is the one moment that decides whether their Keephaven starts
    # again. Everything else about apply is the Pi's, unchanged.
    #
    # Column 0, like the shipped script's own `def regen_default`. Indented by four spaces
    # this still parsed — as a function NESTED inside the one before it, which main() can
    # never reach. The builder now checks where the function lands, not just that it parses.
    #
    # nixos/rollback is NOT touched here, for the same reason it is not on the Pi (see the
    # call site): it is the known-good slot, baked at build and refreshed only by promote.
    # default.bkp is this function's own safety net during the swap.
    new = os.path.join(fw_nixos, "default.new")
    shutil.rmtree(new, ignore_errors=True)
    os.makedirs(new, exist_ok=True)
    src = cand + "/boot/linux.efi"
    if not os.path.isfile(src):
        raise RuntimeError("the update carries no boot file at /boot/linux.efi")
    blob = open(src, "rb").read()
    if blob[:2] != b"MZ":
        raise RuntimeError("the update's boot file is not an EFI binary")
    # The check that matters, and the PC's equivalent of the Pi's cmdline.txt check. A boot
    # file built against a different system copies and swaps perfectly well, and the drive
    # then comes up running the OLD insides under a NEW starter with nothing to notice. It
    # has to name the very system this update just wrote.
    #
    # A whole-file search on purpose, not a parse of the .cmdline PE section: the kernel and
    # the initrd inside the file are compressed, so the only place this path can appear in
    # the clear is the command line the stub will pass to the kernel.
    want = ("init=" + top + "/init").encode()
    if want not in blob:
        raise RuntimeError("the update's boot file does not start the system it ships")
    dst = os.path.join(new, "linux.efi")
    with open(dst, "wb") as f:
        f.write(blob)
        f.flush()
        os.fsync(f.fileno())
    if os.path.getsize(dst) != len(blob):
        raise RuntimeError("short write installing the boot file")
    # The same swap the Pi does, for the same reason: one rename, so a power cut leaves
    # either the old slot or the new one and never half of either.
    default = os.path.join(fw_nixos, "default")
    bkp = os.path.join(fw_nixos, "default.bkp")
    shutil.rmtree(bkp, ignore_errors=True)
    if os.path.exists(default):
        os.rename(default, bkp)
    os.rename(new, default)
    subprocess.run(["sync"])
    shutil.rmtree(bkp, ignore_errors=True)
