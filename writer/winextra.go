// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only

//go:build windows

// The Windows calls the writer needs and the helper does not: which bus a disk is on, how big
// it is, whether it is writable, an unbuffered handle for the read-back, what Windows can see on
// a disk, and giving a partition a drive letter.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

const (
	ioctlStorageQueryProperty = 0x002D1400
	ioctlDiskGetLengthInfo    = 0x0007405C
	ioctlDiskIsWritable       = 0x00070024
	ioctlDiskGetGeometryEx    = 0x000700A0

	busTypeUsb = 0x07

	fileFlagNoBuffering  = 0x20000000
	fileFlagWriteThrough = 0x80000000
)

type storagePropertyQuery struct {
	PropertyId uint32
	QueryType  uint32
	Additional [1]byte
}

// openRaw opens a device with extra CreateFile flags, which openDevice (copied from the helper)
// deliberately does not take.
func openRaw(path string, access, flags uint32) (syscall.Handle, error) {
	return syscall.CreateFile(utf16ptr(path), access,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, flags, 0)
}

// diskBusAndModel asks the disk what bus it is on and what it calls itself. Bus type is the
// right question: the enclosure reports as a FIXED disk (Get-Disk BusType=USB, MediaType=SSD,
// WMI 'External hard disk media'), so the removable flag would have been useless and is what
// made Rufus hide the drive until List USB Hard Drives was ticked.
func diskBusAndModel(disk uint32) (bus uint32, model string, err error) {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), 0)
	if err != nil {
		return 0, "", err
	}
	defer syscall.CloseHandle(h)
	q := storagePropertyQuery{PropertyId: 0 /* StorageDeviceProperty */, QueryType: 0 /* PropertyStandardQuery */}
	buf := make([]byte, 1024)
	var n uint32
	err = syscall.DeviceIoControl(h, ioctlStorageQueryProperty,
		(*byte)(unsafe.Pointer(&q)), uint32(unsafe.Sizeof(q)),
		&buf[0], uint32(len(buf)), &n, nil)
	if err != nil {
		return 0, "", err
	}
	if n < 36 {
		return 0, "", fmt.Errorf("the disk described itself in %d bytes, which is too few", n)
	}
	le32 := func(off int) uint32 {
		return uint32(buf[off]) | uint32(buf[off+1])<<8 | uint32(buf[off+2])<<16 | uint32(buf[off+3])<<24
	}
	str := func(off int) string {
		o := int(le32(off))
		if o == 0 || o >= int(n) {
			return ""
		}
		end := o
		for end < int(n) && buf[end] != 0 {
			end++
		}
		return strings.TrimSpace(string(buf[o:end]))
	}
	// STORAGE_DEVICE_DESCRIPTOR: VendorIdOffset 12, ProductIdOffset 16, BusType 28.
	vendor, product := str(12), str(16)
	model = strings.TrimSpace(vendor + " " + product)
	if model == "" {
		model = "(a disk that does not say what it is)"
	}
	return le32(28), model, nil
}

// diskSectorSize asks the drive how big a sector is. Everything else here - where the GPT
// headers sit, what an unbuffered read is allowed to ask for, how the image's partition table
// was laid out - is in units of this number, and the image is built for 512. A 4Kn drive would
// take the image's bytes and read them as a table that is not there, so this is asked and not
// assumed.
func diskSectorSize(disk uint32) (int64, error) {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead)
	if err != nil {
		return 0, err
	}
	defer syscall.CloseHandle(h)
	// DISK_GEOMETRY_EX starts with DISK_GEOMETRY: Cylinders 0..7, MediaType 8..11,
	// TracksPerCylinder 12..15, SectorsPerTrack 16..19, BytesPerSector 20..23.
	buf := make([]byte, 64)
	var n uint32
	if err := syscall.DeviceIoControl(h, ioctlDiskGetGeometryEx, nil, 0,
		&buf[0], uint32(len(buf)), &n, nil); err != nil {
		return 0, err
	}
	if n < 24 {
		return 0, fmt.Errorf("the drive described its geometry in %d bytes, which is too few", n)
	}
	sec := uint32(buf[20]) | uint32(buf[21])<<8 | uint32(buf[22])<<16 | uint32(buf[23])<<24
	if sec == 0 {
		return 0, fmt.Errorf("the drive reports a sector size of zero")
	}
	return int64(sec), nil
}

func diskSize(disk uint32) (int64, error) {
	// genericRead, not 0: IOCTL_DISK_GET_LENGTH_INFO is declared FILE_READ_ACCESS and answers
	// "Access is denied" on a handle with no access, elevated or not. Measured on the HP.
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead)
	if err != nil {
		return 0, err
	}
	defer syscall.CloseHandle(h)
	var length int64
	var n uint32
	err = syscall.DeviceIoControl(h, ioctlDiskGetLengthInfo, nil, 0,
		(*byte)(unsafe.Pointer(&length)), 8, &n, nil)
	return length, err
}

func diskWritable(disk uint32) bool {
	// genericRead for the same reason as diskSize. IOCTL_DISK_IS_WRITABLE only reports whether
	// the MEDIA is write-protected, so asking it does not need write access and must not take
	// any: opening a drive for writing is what the rest of this program is careful about.
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead)
	if err != nil {
		return false
	}
	defer syscall.CloseHandle(h)
	var n uint32
	return syscall.DeviceIoControl(h, ioctlDiskIsWritable, nil, 0, nil, 0, &n, nil) == nil
}

// diskOfPath answers which physical disk a file lives on, which is how the writer refuses to
// erase the disk it is reading the image from.
func diskOfPath(path string) (uint32, bool) {
	abs, err := filepath.Abs(path)
	if err != nil {
		return 0, false
	}
	vol := filepath.VolumeName(abs) // "C:"
	if len(vol) != 2 {
		return 0, false
	}
	d, _, err := diskOf(`\\.\` + vol)
	if err != nil {
		return 0, false
	}
	return d, true
}

// pagefileDisks reads the pagefile settings and returns the disks they live on, because a disk
// holding a pagefile is in use by Windows whatever its letters say.
func pagefileDisks() map[uint32]bool {
	out := map[uint32]bool{}
	// HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PagingFiles
	// is a REG_MULTI_SZ of lines like "C:\pagefile.sys 0 0". Read it through the registry API
	// rather than shelling out: the writer runs no other program.
	k, err := syscall.UTF16PtrFromString(`SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management`)
	if err != nil {
		return out
	}
	var h syscall.Handle
	if syscall.RegOpenKeyEx(syscall.HKEY_LOCAL_MACHINE, k, 0, syscall.KEY_READ, &h) != nil {
		return out
	}
	defer syscall.RegCloseKey(h)
	name, err := syscall.UTF16PtrFromString("PagingFiles")
	if err != nil {
		return out
	}
	var typ, size uint32
	if syscall.RegQueryValueEx(h, name, nil, &typ, nil, &size) != nil || size == 0 {
		return out
	}
	buf := make([]byte, size)
	if syscall.RegQueryValueEx(h, name, nil, &typ, &buf[0], &size) != nil {
		return out
	}
	u := make([]uint16, size/2)
	for i := range u {
		u[i] = uint16(buf[i*2]) | uint16(buf[i*2+1])<<8
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(utf16Runes(u)), "\x00", "\n"), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if d, ok := diskOfPath(strings.Fields(line)[0]); ok {
			out[d] = true
		}
	}
	return out
}

func utf16Runes(u []uint16) []rune {
	out := make([]rune, 0, len(u))
	for _, c := range u {
		out = append(out, rune(c))
	}
	return out
}

// volumeInformation is syscall.GetVolumeInformation, which the standard library does not expose
// on this platform, so it goes through kernel32 like everything else here.
func volumeInformation(root string) (label, fs string, err error) {
	var nameBuf [261]uint16
	var fsBuf [261]uint16
	var serial, maxComp, flags uint32
	r, _, e := procGetVolumeInformationW.Call(
		uintptr(unsafe.Pointer(utf16ptr(root))),
		uintptr(unsafe.Pointer(&nameBuf[0])), uintptr(len(nameBuf)),
		uintptr(unsafe.Pointer(&serial)), uintptr(unsafe.Pointer(&maxComp)),
		uintptr(unsafe.Pointer(&flags)),
		uintptr(unsafe.Pointer(&fsBuf[0])), uintptr(len(fsBuf)))
	if r == 0 {
		return "", "", e
	}
	return syscall.UTF16ToString(nameBuf[:]), syscall.UTF16ToString(fsBuf[:]), nil
}

// volumeInfo is what Windows can see on a disk, so the typed confirmation is informed rather
// than blind. A brand-new drive and a drive full of someone's files must look different here.
type volumeInfo struct {
	Letter string
	Label  string
	FS     string
	UsedGB float64
	SizeGB float64
	Note   string
}

func whatIsOnDisk(disk uint32) []volumeInfo {
	var out []volumeInfo
	for c := 'A'; c <= 'Z'; c++ {
		vol := string(c) + ":"
		d, _, err := diskOf(`\\.\` + vol)
		if err != nil || d != disk {
			continue
		}
		vi := volumeInfo{Letter: vol}
		root := vol + `\`
		if label, fs, e := volumeInformation(root); e == nil {
			vi.Label, vi.FS = label, fs
		} else {
			vi.Note = "Windows cannot read this one"
		}
		var free, total, totalFree uint64
		if e := getDiskFreeSpaceEx(root, &free, &total, &totalFree); e == nil && total > 0 {
			vi.SizeGB = float64(total) / (1 << 30)
			vi.UsedGB = float64(total-totalFree) / (1 << 30)
		}
		out = append(out, vi)
	}
	return out
}

var (
	procGetVolumeInformationW = kernel32w.NewProc("GetVolumeInformationW")
	procGetDiskFreeSpaceExW   = kernel32w.NewProc("GetDiskFreeSpaceExW")
	procSetVolumeMountPointW  = kernel32w.NewProc("SetVolumeMountPointW")
	procDelVolumeMountPointW  = kernel32w.NewProc("DeleteVolumeMountPointW")
	procGetVolumePathNamesW   = kernel32w.NewProc("GetVolumePathNamesForVolumeNameW")
	procGetLogicalDrives      = kernel32w.NewProc("GetLogicalDrives")
)

func getDiskFreeSpaceEx(root string, freeToCaller, total, totalFree *uint64) error {
	r, _, err := procGetDiskFreeSpaceExW.Call(
		uintptr(unsafe.Pointer(utf16ptr(root))),
		uintptr(unsafe.Pointer(freeToCaller)),
		uintptr(unsafe.Pointer(total)),
		uintptr(unsafe.Pointer(totalFree)))
	if r == 0 {
		return err
	}
	return nil
}

// volumePaths lists the places a volume is already reachable from, so KEEPHAVEN does not end up
// with two letters: SetVolumeMountPoint ADDS a mount point, it does not move one, and a drive
// that shows up twice in Explorer is a drive the owner has to think about.
func volumePaths(volume string) []string {
	buf := make([]uint16, 1024)
	var n uint32
	r, _, _ := procGetVolumePathNamesW.Call(
		uintptr(unsafe.Pointer(utf16ptr(volume))),
		uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), uintptr(unsafe.Pointer(&n)))
	if r == 0 {
		return nil
	}
	var out []string
	for i := 0; i < len(buf); {
		j := i
		for j < len(buf) && buf[j] != 0 {
			j++
		}
		if j == i {
			break
		}
		out = append(out, syscall.UTF16ToString(buf[i:j]))
		i = j + 1
	}
	return out
}

// freeDriveLetter picks a letter nothing is using, from the end of the alphabet so it does not
// take one a customer's habits depend on.
func freeDriveLetter() string {
	r, _, _ := procGetLogicalDrives.Call()
	mask := uint32(r)
	for c := 'Z'; c >= 'E'; c-- {
		if mask&(1<<uint(c-'A')) == 0 {
			return string(c) + ":"
		}
	}
	return ""
}

// giveKeephavenALetter finds the KEEPHAVEN volume on this disk and mounts it, because Windows
// does not always do it: on the HP on 2026-10-14 a freshly written drive came up with the boot
// partition lettered and KEEPHAVEN not, so the owner saw EFI folders and no program. The image
// now also asks Windows not to letter p1 (GPT attribute bit 63), which may do nothing on an
// ESP; this is the belt for the PC the writer ran on.
// hideFirmware takes the letter off the boot partition if Windows gave it one. On the HP on
// 2026-10-14 a freshly written drive came up with p1 FIRMWARE lettered D: and KEEPHAVEN not
// lettered at all, so the owner opened their new drive and found EFI folders and no program.
// The image now also sets GPT attribute bit 63 on p1, which asks Windows not to letter it, but
// that is advice about basic-data partitions and may do nothing on an ESP - so the writer takes
// the letter away on the PC it is running on as well. It only ever removes a mount point from a
// volume labelled FIRMWARE on the drive it just wrote.
func hideFirmware(disk uint32) []string {
	var removed []string
	for _, v := range allVolumes() {
		d, _, err := diskOf(v)
		if err != nil || d != disk {
			continue
		}
		name := strings.Replace(v, `\\.\`, `\\?\`, 1) + `\`
		label, _, err := volumeInformation(name)
		if err != nil || label != "FIRMWARE" {
			continue
		}
		for _, path := range volumePaths(name) {
			if r, _, _ := procDelVolumeMountPointW.Call(uintptr(unsafe.Pointer(utf16ptr(path)))); r != 0 {
				removed = append(removed, strings.TrimSuffix(path, `\`))
			}
		}
	}
	return removed
}

func giveKeephavenALetter(disk uint32) (string, error) {
	vols := allVolumes()
	for _, v := range vols {
		d, _, err := diskOf(v)
		if err != nil || d != disk {
			continue
		}
		// v is \\.\Volume{...}; the mount-point API wants \\?\Volume{...}\
		name := strings.Replace(v, `\\.\`, `\\?\`, 1) + `\`
		label, _, err := volumeInformation(name)
		if err != nil || label != "KEEPHAVEN" {
			continue
		}
		// Windows may have lettered it already, in which case there is nothing to do and
		// adding a letter would only give it a second one.
		for _, path := range volumePaths(name) {
			if l := strings.TrimSuffix(path, `\`); len(l) == 2 && l[1] == ':' {
				return l, nil
			}
		}
		letter := freeDriveLetter()
		if letter == "" {
			return "", fmt.Errorf("every drive letter is taken")
		}
		r, _, err := procSetVolumeMountPointW.Call(
			uintptr(unsafe.Pointer(utf16ptr(letter+`\`))),
			uintptr(unsafe.Pointer(utf16ptr(name))))
		if r == 0 {
			return "", fmt.Errorf("could not give it the letter %s: %v", letter, err)
		}
		return letter, nil
	}
	return "", fmt.Errorf("no KEEPHAVEN partition turned up on drive %d", disk)
}

// unbufferedDevice serves ReadAt from a FILE_FLAG_NO_BUFFERING handle, which accepts only reads
// whose offset, length and buffer address are all multiples of the sector size. It reads the
// enclosing aligned range into an aligned buffer and copies out the part that was asked for, so
// the gpt package can go on asking for 512 bytes wherever it likes - and what comes back is the
// disk, not Windows' cache of what was just written to it.
type unbufferedDevice struct {
	f      *os.File
	sector int64
}

func (u unbufferedDevice) ReadAt(p []byte, off int64) (int, error) {
	s := u.sector
	start := off - off%s
	end := off + int64(len(p))
	if r := end % s; r != 0 {
		end += s - r
	}
	buf := aligned(int(end - start))
	if _, err := u.f.ReadAt(buf, start); err != nil {
		return 0, err
	}
	return copy(p, buf[off-start:]), nil
}

func (u unbufferedDevice) WriteAt(p []byte, off int64) (int, error) {
	return 0, fmt.Errorf("this handle was opened for reading only")
}

// sectorDevice does aligned read-modify-write on a raw drive handle, so a caller can read and
// write whatever length it likes at whatever offset it likes. A physical drive handle - buffered
// or not - accepts only offsets and lengths that are multiples of the sector size, and anything
// else comes back as "The parameter is incorrect". That is exactly how the code stamper failed on
// the HP on 2026-10-14: its 1 MiB scan window advanced by 1048490 bytes, so the second read was
// 86 bytes off a sector boundary. The gpt package never hit this because a GPT read is always a
// whole sector at a sector offset.
type sectorDevice struct {
	f      *os.File
	sector int64
}

func (d sectorDevice) span(off int64, n int) (start, end int64) {
	s := d.sector
	start = off - off%s
	end = off + int64(n)
	if r := end % s; r != 0 {
		end += s - r
	}
	return start, end
}

func (d sectorDevice) ReadAt(p []byte, off int64) (int, error) {
	start, end := d.span(off, len(p))
	buf := aligned(int(end - start))
	if _, err := d.f.ReadAt(buf, start); err != nil {
		return 0, err
	}
	return copy(p, buf[off-start:]), nil
}

func (d sectorDevice) WriteAt(p []byte, off int64) (int, error) {
	start, end := d.span(off, len(p))
	buf := aligned(int(end - start))
	// Read the enclosing sectors first: the bytes either side of what is being written belong to
	// somebody else - here, the rest of a file in a FAT filesystem - and must go back unchanged.
	if _, err := d.f.ReadAt(buf, start); err != nil {
		return 0, err
	}
	copy(buf[off-start:], p)
	if _, err := d.f.WriteAt(buf, start); err != nil {
		return 0, err
	}
	return len(p), nil
}

// deviceFile wraps a handle so the gpt package can read and write it through ReadAt/WriteAt.
type deviceFile struct{ f *os.File }

func (d deviceFile) ReadAt(p []byte, off int64) (int, error)  { return d.f.ReadAt(p, off) }
func (d deviceFile) WriteAt(p []byte, off int64) (int, error) { return d.f.WriteAt(p, off) }
