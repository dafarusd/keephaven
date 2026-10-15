# SPDX-FileCopyrightText: 2026 Keephaven LLC
# SPDX-License-Identifier: GPL-2.0-only
#
# This file is the script that controls the compilation of the QEMU binary Keephaven
# redistributes, which GPL-2.0 section 3 counts as part of that binary's corresponding
# source. It therefore cannot be withheld or licensed on Keephaven's own terms, whoever
# wrote it. It travels on every drive beside the patch and flake.lock.
#
# QEMU for 64-bit Windows, cross-built from the same package set the images use: only what the
# Keephaven helper needs (x86-64 system emulation, the Windows Hypervisor Platform, user
# networking, one SDL window). Source is the upstream release tarball, by hash.
#
# `patched = true` adds win32-hdev-fixed-length.patch. Without it a Linux guest reading a raw
# USB drive on Windows waits about 3.5 ms for every read, because QEMU asks the drive for its
# geometry three times per request; measured on the test PC, it is the difference between a
# 149 s start-up check and a 15.6 s one.
#
# 11.1.0 and not the package set's own 10.1.5: 10.1.5 stops at the first firmware access under
# the Windows Hypervisor Platform ("WHPX: Failed to emulate MMIO access"), seen on the test PC.
#
# Nothing here is referenced unless keephaven.platform = "pc", so the Pi images are untouched.

{ nixpkgs, patched ? false }:
let
  host = import nixpkgs { system = "x86_64-linux"; };
  p = import nixpkgs {
    system = "x86_64-linux";
    crossSystem = host.lib.systems.examples.mingwW64;
    config.allowUnsupportedSystem = true;
    overlays = [
      (final: prev: {
        # glib for Windows as packaged wants a Windows Python and sysprof; it needs neither.
        glib = (prev.glib.override {
          python3 = final.buildPackages.python3;
          python3Packages = final.buildPackages.python3Packages;
          libsysprof-capture = null;
        }).overrideAttrs (o: { mesonFlags = (o.mesonFlags or [ ]) ++ [ "-Dsysprof=disabled" ]; });
      })
    ];
  };
  b = p.buildPackages;
  lib = host.lib;
in
p.stdenv.mkDerivation {
  pname = "keephaven-qemu-windows" + lib.optionalString patched "-fixedlen";
  version = "11.1.0";
  src = host.fetchurl {
    url = "https://download.qemu.org/qemu-11.1.0.tar.xz";
    hash = "sha256-buHRph9oISR2snEIwm2l9EncCbYm1C+CeboNwuCPqFg=";
  };

  depsBuildBuild = [ b.stdenv.cc ];
  # setuptools, wheel and pip: 11.x's setup step checks for them and would fetch them otherwise.
  nativeBuildInputs = [
    b.pkg-config b.flex b.bison b.meson b.ninja b.perl b.dtc
    b.python3 b.python3Packages.distlib b.python3Packages.setuptools b.python3Packages.wheel b.python3Packages.pip
  ];
  # windows.pthreads: QEMU's source uses clock_gettime(), which on Windows lives in winpthreads;
  # this toolchain's own threads are a different library and its pthread_time.h is an empty stub.
  buildInputs = [ p.glib p.zlib p.pixman p.libslirp p.SDL2 p.dtc p.windows.pthreads ];
  NIX_LDFLAGS = "-lwinpthread";

  patches = lib.optional patched ./win32-hdev-fixed-length.patch;

  dontUseMesonConfigure = true;
  dontAddStaticConfigureFlags = true;
  dontStrip = true; # stripped in launcher.nix, where the hash list is made

  preConfigure = ''
    unset CPP
    chmod +x ./scripts/shaderinclude.py
    patchShebangs .
    mv VERSION QEMU_VERSION
    substituteInPlace configure --replace-fail '$source_path/VERSION' '$source_path/QEMU_VERSION'
    substituteInPlace meson.build --replace-fail "'VERSION'" "'QEMU_VERSION'"
    # The installer target asks glib's pkg-config file for a "bindir" it does not carry here.
    # We never build the installer; give it the folder so the setup step gets past it.
    substituteInPlace meson.build --replace-fail "glib_pc.get_variable('bindir')" "'${lib.getBin p.glib}/bin'"
  '';

  preBuild = "cd build";

  # Windows finds a program's libraries next to it: gather every DLL the emulator needs, and
  # those DLLs' own, from what it was linked against. Windows' own DLLs are not in those places
  # and are left alone.
  postInstall = ''
    exe=$(find $out -name 'qemu-system-x86_64.exe' | head -1)
    dest=$(dirname "$exe")
    search=""
    for l in $(echo $NIX_LDFLAGS | tr ' ' '\n' | sed -n 's/^-L//p'); do
      search="$search $l $(dirname $l)/bin"
    done
    for d in ${lib.concatMapStringsSep " " (d: "${lib.getBin d}/bin") [ p.glib p.zlib p.pixman p.libslirp p.dtc ]} ${lib.getDev p.SDL2}/bin ${p.sdl3.out}/bin; do
      search="$search $d"
    done
    for n in libgcc_s_seh-1.dll libwinpthread-1.dll libssp-0.dll; do
      f=$(${p.stdenv.cc.targetPrefix}gcc -print-file-name=$n); [ -e "$f" ] && search="$search $(dirname $f)"
    done
    # SDL2 here is a thin layer that loads SDL3.dll by name when it starts; nothing imports it.
    cp -L ${p.sdl3.out}/bin/SDL3.dll "$dest/SDL3.dll"; chmod u+w "$dest/SDL3.dll"
    todo="$exe $dest/SDL3.dll"; seen="SDL3.dll"
    while [ -n "$todo" ]; do
      next=""
      for f in $todo; do
        for dll in $(${p.stdenv.cc.targetPrefix}objdump -p "$f" | sed -n 's/^[[:space:]]*DLL Name: //p'); do
          case " $seen " in *" $dll "*) continue ;; esac
          seen="$seen $dll"
          hit=""
          for d in $search; do
            [ -e "$d/$dll" ] && { hit="$d/$dll"; break; }
          done
          if [ -n "$hit" ]; then
            cp -L "$hit" "$dest/$dll"; chmod u+w "$dest/$dll"; next="$next $dest/$dll"
          else
            echo "not gathered (Windows' own, or missing): $dll"
          fi
        done
      done
      todo="$next"
    done
    echo "gathered next to the emulator:"; ls "$dest" | grep -i '\.dll$'
  '';

  configureFlags = [
    "--cross-prefix=${p.stdenv.cc.targetPrefix}"
    "--target-list=x86_64-softmmu"
    "--without-default-features"
    "--enable-system"
    "--enable-tcg"
    "--enable-whpx"
    "--enable-sdl"
    "--enable-slirp"
    "--enable-pixman"
    "--enable-fdt=system" # the x86 machine set includes one that needs libfdt
    "--disable-docs"
    "--disable-tools"
    "--disable-guest-agent"
    "--disable-werror"
    "--disable-strip"
  ];
}
