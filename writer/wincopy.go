// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only

//go:build windows

// COPIED VERBATIM FROM launcher/windows/main.go. Do not edit here.
//
// The writer needs the same Windows glue the helper uses to find, lock and dismount a drive,
// and that glue is hardware-proven: it has taken the drive on the HP a dozen times. Two ways to
// share it were rejected. Moving it into a shared package touches the proven helper and changes
// its binary for no behavioural reason. Making the writer a mode of Keephaven.exe would put
// disk-erasing code on every drive the helper copies itself onto (main.go:749), which is a tool
// that wipes USB disks sitting on the product. So it is copied - and because "copied, see the
// comment" rots, the build FAILS if these functions ever differ from the helper's: see
// writer/drift-check.sh, which the writer's derivation runs before it compiles anything.
package main

import (
	"fmt"
	"os"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const (
	fsctlLockVolume           = 0x00090018
	fsctlDismountVolume       = 0x00090020
	ioctlStorageGetDevNumber  = 0x002D1080
	ioctlDiskUpdateProperties = 0x00070140
	genericRead               = 0x80000000
	genericWrite              = 0x40000000
)

type storageDeviceNumber struct {
	DeviceType      uint32
	DeviceNumber    uint32
	PartitionNumber uint32
}

var (
	shell32              = syscall.NewLazyDLL("shell32.dll")
	procIsUserAnAdmin    = shell32.NewProc("IsUserAnAdmin")
	procShellExecuteW    = shell32.NewProc("ShellExecuteW")
	kernel32w            = syscall.NewLazyDLL("kernel32.dll")
	procFindFirstVolumeW = kernel32w.NewProc("FindFirstVolumeW")
	procFindNextVolumeW  = kernel32w.NewProc("FindNextVolumeW")
	procFindVolumeClose  = kernel32w.NewProc("FindVolumeClose")
)

func utf16ptr(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func isAdmin() bool {
	r, _, _ := procIsUserAnAdmin.Call()
	return r != 0
}

func openDevice(path string, access uint32) (syscall.Handle, error) {
	return syscall.CreateFile(utf16ptr(path), access,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, 0, 0)
}

func diskOf(volume string) (uint32, uint32, error) {
	h, err := openDevice(volume, 0)
	if err != nil {
		return 0, 0, err
	}
	defer syscall.CloseHandle(h)
	var sdn storageDeviceNumber
	var n uint32
	err = syscall.DeviceIoControl(h, ioctlStorageGetDevNumber, nil, 0,
		(*byte)(unsafe.Pointer(&sdn)), uint32(unsafe.Sizeof(sdn)), &n, nil)
	return sdn.DeviceNumber, sdn.PartitionNumber, err
}

func rereadPartitions(disk uint32) error {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead|genericWrite)
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(h)
	var n uint32
	return syscall.DeviceIoControl(h, ioctlDiskUpdateProperties, nil, 0, nil, 0, &n, nil)
}

func lockVolume(h syscall.Handle, tries int) error {
	var n uint32
	var err error
	for i := 0; i < tries; i++ {
		if err = syscall.DeviceIoControl(h, fsctlLockVolume, nil, 0, nil, 0, &n, nil); err == nil {
			return nil
		}
		time.Sleep(500 * time.Millisecond)
	}
	return err
}

func allVolumes() []string {
	var out []string
	buf := make([]uint16, 512)
	h, _, _ := procFindFirstVolumeW.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if h == 0 || h == ^uintptr(0) {
		return out
	}
	defer procFindVolumeClose.Call(h)
	for {
		out = append(out, strings.TrimRight(syscall.UTF16ToString(buf), `\`))
		r, _, _ := procFindNextVolumeW.Call(h, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
		if r == 0 {
			break
		}
	}
	return out
}

func relaunchAsAdmin(args string) error {
	exe, _ := os.Executable()
	r, _, err := procShellExecuteW.Call(0,
		uintptr(unsafe.Pointer(utf16ptr("runas"))),
		uintptr(unsafe.Pointer(utf16ptr(exe))),
		uintptr(unsafe.Pointer(utf16ptr(args))),
		0, 1)
	if r <= 32 {
		return fmt.Errorf("ShellExecute returned %d (%v)", r, err)
	}
	return nil
}
