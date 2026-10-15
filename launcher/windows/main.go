// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// Keephaven.exe — runs the Keephaven that lives on THIS USB drive, on a Windows PC.
//
// It sits on the drive's small Windows-visible partition ("KEEPHAVEN") next to a
// copy of QEMU. Double-clicked, it:
//   1. asks Windows for administrator rights (one prompt);
//   2. copies itself and QEMU to %ProgramData%\Keephaven\run, a folder only an
//      administrator may write to, and continues from
//      there, because the drive is about to be taken away from Windows;
//   3. checks the PC (memory, the Windows Hypervisor Platform, free ports);
//   4. locks and dismounts every volume on the drive, so Windows neither blocks
//      writes to it nor touches it while Keephaven runs;
//   5. starts QEMU on the whole physical drive, with the PC's ports 80, 8888 and
//      2283 passed through to Keephaven;
//   6. waits. "q" + Enter shuts Keephaven down cleanly and gives the drive back.
//
// Nothing is installed. What it leaves on the PC: the folder above, holding a copy
// of this program and of QEMU, and a log. The firewall rule it adds for Keephaven's
// own ports is taken away again when Keephaven stops.
//
// Two builds come out of this source. The default one is the TEST build: it carries the
// loop the Windows test PC is driven with (a status page on the home network, starts asked
// for from the build laptop, timings, a one-byte patched copy of a downloaded QEMU). Built
// with `-tags release` none of that is compiled in: see release.go against testbed.go.

//go:build windows

package main

import (
	"bufio"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)


// qemuDigests is set at build time (-ldflags "-X main.qemuDigests=<name>:<sha256>,…") by the
// step that puts QEMU on the drive, so the helper runs only the QEMU it was built against.
// Empty in a hand build: then the hashes are logged and not enforced.
var qemuDigests string

// checkQemu reads what is about to be run as administrator and compares it with the list
// built in. Nothing else in the folder is trusted either: a file QEMU loads sits beside it.
func checkQemu(runDir string) {
	want := map[string]string{}
	for _, e := range strings.Split(qemuDigests, ",") {
		if n, h, ok := strings.Cut(e, ":"); ok {
			want[strings.ToLower(n)] = h
		}
	}
	bad, seen := 0, 0
	filepath.Walk(filepath.Join(runDir, "qemu"), func(p string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return nil
		}
		rel, _ := filepath.Rel(runDir, p)
		sum := fmt.Sprintf("%x", sha256.Sum256(b))
		if len(want) == 0 {
			if strings.EqualFold(filepath.Base(p), "qemu-system-x86_64.exe") {
				logf("QEMU: %d bytes, sha256 %s (not pinned in this build)", len(b), sum)
			}
			return nil
		}
		seen++
		if w, ok := want[strings.ToLower(filepath.ToSlash(rel))]; !ok || w != sum {
			logf("  %s does not match what this helper was built with", filepath.ToSlash(rel))
			bad++
		}
		return nil
	})
	if len(want) == 0 && releaseBuild {
		stop("this helper was built without the list of QEMU files it is meant to run. It will not run a program it cannot check.")
	}
	if len(want) > 0 {
		if bad > 0 || seen != len(want) {
			stop("the QEMU on this drive is not the one this helper was built with (%d of %d files checked, %d wrong). Nothing was started.", seen, len(want), bad)
		}
		logf("QEMU on this drive matches this helper: %d files", seen)
	}
}

// TEST BUILDS ONLY — remove before anyone else gets this program. The helper looks for a
// newer copy of itself on the build laptop, so it can be changed without carrying the drive.

const (
	fsctlLockVolume          = 0x00090018
	fsctlDismountVolume      = 0x00090020
	ioctlStorageGetDevNumber = 0x002D1080
	// Tell Windows to re-read a disk's partition table. Keephaven's first boot creates the
	// data partition, and Windows keeps the table it cached before the drive was taken away:
	// after a run it shows four partitions and the data partition's space — 897.5 GiB on the
	// test drive — as UNALLOCATED, until the drive is unplugged and plugged in again. Windows
	// offers to do something about unallocated space, and the something is a format, over the
	// owner's photos. Measured on the HP, 2026-10-12: Get-Partition 4, LargestFreeExtent
	// 897.5 GiB, while the disk's own GPT has five entries.
	ioctlDiskUpdateProperties = 0x00070140
	genericRead              = 0x80000000
	genericWrite             = 0x40000000
	guestMemMiB              = 5120
	minHostMemMiB            = 7600 // an "8 GB" PC reports a little under 8192
)

var guestPorts = []int{80, 8888, 2283}

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")

	procFindFirstVolumeW            = kernel32.NewProc("FindFirstVolumeW")
	procFindNextVolumeW             = kernel32.NewProc("FindNextVolumeW")
	procFindVolumeClose             = kernel32.NewProc("FindVolumeClose")
	procGetVolumeInformationW       = kernel32.NewProc("GetVolumeInformationW")
	procGlobalMemoryStatusEx        = kernel32.NewProc("GlobalMemoryStatusEx")
	procSetThreadExecutionState     = kernel32.NewProc("SetThreadExecutionState")
	procCreateJobObjectW            = kernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject     = kernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJob          = kernel32.NewProc("AssignProcessToJobObject")
	procSetConsoleCtrlHandler       = kernel32.NewProc("SetConsoleCtrlHandler")
	procGetConsoleWindow            = kernel32.NewProc("GetConsoleWindow")
	procGetConsoleProcessList       = kernel32.NewProc("GetConsoleProcessList")
	user32                          = syscall.NewLazyDLL("user32.dll")
	procGetSystemMenu               = user32.NewProc("GetSystemMenu")
	procDeleteMenu                  = user32.NewProc("DeleteMenu")
	procDrawMenuBar                 = user32.NewProc("DrawMenuBar")
	procGetNamedPipeServerProcessId = kernel32.NewProc("GetNamedPipeServerProcessId")
	procGetSystemDirectoryW         = kernel32.NewProc("GetSystemDirectoryW")
	procPeekNamedPipe               = kernel32.NewProc("PeekNamedPipe")
	procLocalFree                   = kernel32.NewProc("LocalFree")
	advapi32                        = syscall.NewLazyDLL("advapi32.dll")
	procGetNamedSecurityInfoW       = advapi32.NewProc("GetNamedSecurityInfoW")
	procConvertSidToStringSidW      = advapi32.NewProc("ConvertSidToStringSidW")
	procStringToSecurityDescriptor  = advapi32.NewProc("ConvertStringSecurityDescriptorToSecurityDescriptorW")
	procSecurityDescriptorToString  = advapi32.NewProc("ConvertSecurityDescriptorToStringSecurityDescriptorW")
	procSHGetKnownFolderPath        = shell32.NewProc("SHGetKnownFolderPath")
	procCoTaskMemFree               = syscall.NewLazyDLL("ole32.dll").NewProc("CoTaskMemFree")
	procIsUserAnAdmin               = shell32.NewProc("IsUserAnAdmin")
	procShellExecuteW               = shell32.NewProc("ShellExecuteW")
)

// ---------- log: screen + file + the status page ----------

var (
	logMu   sync.Mutex
	logBuf  []string
	logFile *os.File
)

func logf(format string, a ...interface{}) {
	line := time.Now().Format("15:04:05") + " " + fmt.Sprintf(format, a...)
	logMu.Lock()
	defer logMu.Unlock()
	fmt.Println(line)
	logBuf = append(logBuf, line)
	if logFile != nil {
		fmt.Fprintln(logFile, line)
	}
}

// Everything that takes something away from Windows registers here how to give it back, and
// every way out of a run goes through runExit — including stop(). The first failed start on a
// PC proved why: after six attempts the helper parked at "Press Enter to close this window"
// while still holding the drive dismounted and its firewall rule open, so the owner's drive
// had simply vanished from Explorer with nothing on screen to say so. A release that only
// happens on the happy path is not a release. HP, 2026-10-12 18:10.
var (
	onExitMu sync.Mutex
	onExit   []func()
	exitDone bool
)

func atExit(f func()) {
	onExitMu.Lock()
	defer onExitMu.Unlock()
	onExit = append(onExit, f)
}

// runExit gives back everything that was taken, most recent first. Safe to call twice, and
// safe to call when nothing was taken at all.
func runExit() {
	onExitMu.Lock()
	if exitDone {
		onExitMu.Unlock()
		return
	}
	exitDone = true
	fs := onExit
	onExit = nil
	onExitMu.Unlock()
	for i := len(fs) - 1; i >= 0; i-- {
		fs[i]()
	}
}

// Set the moment QEMU is actually started, so stop() can tell the truth about the drive.
var qemuWasStarted bool

// The running QEMU's process id, or 0. The console close handler cannot touch the run loop's
// own variables safely, so it asks here instead of sleeping for a fixed time and hoping.
var qemuPid atomic.Int64

// guestReset is set when QEMU says it stopped because the GUEST asked to reboot. With
// -no-reboot (below) a guest reboot makes QEMU exit instead of resetting the machine in place,
// and resetting in place is what hangs under Windows' hypervisor: on the HP, 2026-10-13 16:46:02,
// an update's restart left "WHPX: Unexpected VP exit code 4" with QEMU alive and the guest wedged,
// p2 untouched, and the owner with a dead window and no instructions. The reason comes from QMP's
// own SHUTDOWN event rather than being inferred, so a guest shutdown and a shutdown we asked for
// are never mistaken for a reboot.
var guestReset atomic.Bool

// askedToStop is the cross-check: anything that deliberately ends QEMU sets it, so an exit that
// arrives while it is false was not our doing.
var askedToStop atomic.Bool

func qemuGone() bool {
	pid := qemuPid.Load()
	if pid == 0 {
		return true
	}
	h, err := syscall.OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, uint32(pid))
	if err != nil {
		return true
	}
	defer syscall.CloseHandle(h)
	var code uint32
	if err := syscall.GetExitCodeProcess(h, &code); err != nil {
		return false
	}
	return code != 259 // STILL_ACTIVE
}

func stop(format string, a ...interface{}) {
	logf("STOPPED: "+format, a...)
	runExit()
	// "Nothing on the drive was changed" was printed unconditionally, which stopped being true
	// the first time QEMU ran: from then on Keephaven itself had the raw drive and could write
	// to it. A reassurance that is sometimes false is worse than none.
	if qemuWasStarted {
		logf("Keephaven itself was running on this drive, so it may have written to it. Nothing was changed by hand.")
	} else {
		logf("Nothing on the drive was changed by this step.")
	}
	logf("Press Enter to close this window.")
	bufio.NewReader(os.Stdin).ReadString('\n')
	os.Exit(1)
}

// baseDir is where the helper works from. It has to be a place no ordinary user can write
// to: the helper runs as administrator, and it runs QEMU out of here, so anyone who could
// change what is in it would be running their own program as administrator. ProgramData is
// that place once the folder's permissions are set; see lockFolder.
// The helper runs as administrator but was started by an ordinary user, and it inherits
// that user's environment: %ProgramData%, %SystemRoot% and %PATH% are all theirs to set.
// So ask Windows itself where things are, and name every tool by its full path.
type winGUID struct {
	A    uint32
	B, C uint16
	D    [8]byte
}

var folderProgramData = winGUID{0x62AB5D82, 0xFDC1, 0x4DC3, [8]byte{0xA9, 0xDD, 0x07, 0x0D, 0x1D, 0x49, 0x5D, 0x97}}

func knownFolder(id winGUID) (string, error) {
	var p *uint16
	if r, _, _ := procSHGetKnownFolderPath.Call(uintptr(unsafe.Pointer(&id)), 0, 0, uintptr(unsafe.Pointer(&p))); r != 0 || p == nil {
		return "", fmt.Errorf("SHGetKnownFolderPath returned 0x%x", r)
	}
	defer procCoTaskMemFree.Call(uintptr(unsafe.Pointer(p)))
	// The path is a Windows string that Windows itself allocated: read it out character by
	// character rather than reinterpreting the block as a Go array of some guessed length.
	var out []uint16
	for q := p; *q != 0; q = (*uint16)(unsafe.Add(unsafe.Pointer(q), 2)) {
		out = append(out, *q)
	}
	return syscall.UTF16ToString(out), nil
}

// sys32 is the full path of one of Windows' own programs, so nothing on %PATH% can stand
// in for it in a process running as administrator.
func sys32(name string) string {
	buf := make([]uint16, 260)
	n, _, _ := procGetSystemDirectoryW.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	if n == 0 || int(n) > len(buf) {
		return name
	}
	return filepath.Join(syscall.UTF16ToString(buf[:n]), name)
}

func baseDir() string {
	d, err := knownFolder(folderProgramData)
	if err != nil || d == "" {
		stop("Windows did not say where its ProgramData folder is (%v).", err)
	}
	return filepath.Join(d, "Keephaven")
}

// The helper's own folder: owned by this PC's administrators group, who may change anything
// in it along with the system; everyone else may read and run but not write. P so nothing is
// inherited from ProgramData, (OI)(CI) so what is made inside it gets the same. wantEntries is
// what the three permissions read back as, checked on a folder that is already there.
const (
	ownSddl     = "O:BAG:BAD:P(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)"
	wantEntries = "(A;OICI;FA;;;BA)(A;OICI;FA;;;SY)(A;OICI;0x1200a9;;;BU)"
)

// rightsAreOurs says whether a folder still carries the permissions the helper made it with.
// Windows writes back "D:PAI(" instead of "D:P(" once the folder's Security tab has been
// opened and applied, even when nothing was changed: the three entries are then identical and
// only the auto-inherited flag differs. Both spellings are ours; anything else is a change
// somebody made, and the helper refuses the folder rather than work inside it.
func rightsAreOurs(rights string) bool {
	return rights == "D:P"+wantEntries || rights == "D:PAI"+wantEntries
}

// folderOwner returns the owner of a folder as a SID string (S-1-5-32-544 for the
// administrators group), so the check doesn't depend on what the groups are called here.
func fromWide(p *uint16) string {
	var out []uint16
	for q := p; *q != 0; q = (*uint16)(unsafe.Add(unsafe.Pointer(q), 2)) {
		out = append(out, *q)
	}
	return syscall.UTF16ToString(out)
}

func folderOwner(dir string) (string, error) {
	var sid uintptr
	var sd uintptr
	r, _, _ := procGetNamedSecurityInfoW.Call(uintptr(unsafe.Pointer(utf16ptr(dir))),
		1 /* SE_FILE_OBJECT */, 1 /* OWNER_SECURITY_INFORMATION */, uintptr(unsafe.Pointer(&sid)), 0, 0, 0, uintptr(unsafe.Pointer(&sd)))
	if r != 0 || sid == 0 {
		return "", fmt.Errorf("could not read who owns %s (error %d)", dir, r)
	}
	defer procLocalFree.Call(sd)
	var str *uint16
	if ok, _, e := procConvertSidToStringSidW.Call(sid, uintptr(unsafe.Pointer(&str))); ok == 0 {
		return "", e
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(str)))
	return fromWide(str), nil
}

// folderRights returns a folder's permissions as the same kind of text they were set with.
func folderRights(dir string) (string, error) {
	var sid, sd uintptr
	r, _, _ := procGetNamedSecurityInfoW.Call(uintptr(unsafe.Pointer(utf16ptr(dir))),
		1 /* SE_FILE_OBJECT */, 4 /* DACL_SECURITY_INFORMATION */, uintptr(unsafe.Pointer(&sid)), 0, 0, 0, uintptr(unsafe.Pointer(&sd)))
	if r != 0 || sd == 0 {
		return "", fmt.Errorf("could not read the permissions on %s (error %d)", dir, r)
	}
	defer procLocalFree.Call(sd)
	var str *uint16
	var n uint32
	if ok, _, e := procSecurityDescriptorToString.Call(sd, 1, 4, uintptr(unsafe.Pointer(&str)), uintptr(unsafe.Pointer(&n))); ok == 0 {
		return "", e
	}
	defer procLocalFree.Call(uintptr(unsafe.Pointer(str)))
	return fromWide(str), nil
}

// safeFolder makes sure the helper's own folder is one only an administrator can change.
// An ordinary user can create C:\ProgramData\Keephaven before the helper ever runs, and
// whoever owns a folder can always put its permissions back and may have left files and
// links inside it. Rather than try to take such a folder over — which would mean walking a
// tree someone else built, as administrator — the helper refuses it and says so. Its own
// folder is made in one step with the permissions already on it, so there is no moment
// when it exists with any others.
func safeFolder(dir string) error {
	attrs, err := syscall.GetFileAttributes(utf16ptr(dir))
	if err == nil {
		if attrs&syscall.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return fmt.Errorf("%s is a link to somewhere else", dir)
		}
		if attrs&syscall.FILE_ATTRIBUTE_DIRECTORY == 0 {
			return fmt.Errorf("%s is a file, not a folder", dir)
		}
		owner, err := folderOwner(dir)
		if err != nil {
			return err
		}
		if owner != "S-1-5-32-544" && owner != "S-1-5-18" {
			return fmt.Errorf("%s already exists and belongs to %s, not to this PC's administrators. Delete that folder and start Keephaven again", dir, owner)
		}
		rights, err := folderRights(dir)
		if err != nil {
			return err
		}
		if !rightsAreOurs(rights) {
			return fmt.Errorf("%s already exists and its permissions have been changed (%s). Delete that folder and start Keephaven again", dir, rights)
		}
		return nil
	}
	var sd uintptr
	if ok, _, e := procStringToSecurityDescriptor.Call(uintptr(unsafe.Pointer(utf16ptr(ownSddl))), 1, uintptr(unsafe.Pointer(&sd)), 0); ok == 0 {
		return fmt.Errorf("could not prepare the folder's permissions: %v", e)
	}
	defer procLocalFree.Call(sd)
	sa := syscall.SecurityAttributes{SecurityDescriptor: sd}
	sa.Length = uint32(unsafe.Sizeof(sa))
	if err := syscall.CreateDirectory(utf16ptr(dir), &sa); err != nil {
		return fmt.Errorf("could not make %s: %v", dir, err)
	}
	return nil
}

func waitForKeephaven(tStart time.Time, done chan error, quietLimit time.Duration, cut bool) (up, quiet, exited bool) {
	for time.Since(tStart) < 15*time.Minute {
		c := http.Client{Timeout: 3 * time.Second}
		if resp, err := c.Get("http://127.0.0.1/"); err == nil {
			b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			if i := strings.Index(string(b), "<title>"); i >= 0 {
				title := string(b)[i+7:]
				if j := strings.Index(title, "</title>"); j >= 0 {
					title = title[:j]
				}
				logf("Keephaven answers %d s after QEMU started: %q", int(time.Since(tStart).Seconds()), title)
				return true, false, false
			}
		}
		if quietLimit > 0 && testQuietFor() > quietLimit {
			return false, true, false
		}
		if cut && len(nextRun) > 0 {
			return false, false, false // TEST: the build laptop has already asked for the next start
		}
		select {
		case err := <-done:
			logf("  QEMU stopped (%v)", errStr(err))
			return false, false, true
		case <-time.After(3 * time.Second):
		}
	}
	return false, false, false
}

// ---------- small Windows helpers ----------

func utf16ptr(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

func isAdmin() bool {
	r, _, _ := procIsUserAnAdmin.Call()
	return r != 0
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

func openDevice(path string, access uint32) (syscall.Handle, error) {
	return syscall.CreateFile(utf16ptr(path), access,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, 0, 0)
}

type storageDeviceNumber struct {
	DeviceType      uint32
	DeviceNumber    uint32
	PartitionNumber uint32
}

// diskOf returns the physical drive number a volume (\\.\E: or \\?\Volume{…}) sits on.
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

// rereadPartitions makes Windows pick up a partition table that changed while the drive was
// ours. Without it the data partition Keephaven creates on its first boot stays invisible to
// Windows — shown as unallocated space — until the drive is physically reconnected.
func rereadPartitions(disk uint32) error {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead|genericWrite)
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(h)
	var n uint32
	return syscall.DeviceIoControl(h, ioctlDiskUpdateProperties, nil, 0, nil, 0, &n, nil)
}

func volumeLabel(root string) string {
	name := make([]uint16, 261)
	fs := make([]uint16, 261)
	var serial, maxComp, flags uint32
	r, _, _ := procGetVolumeInformationW.Call(
		uintptr(unsafe.Pointer(utf16ptr(root))),
		uintptr(unsafe.Pointer(&name[0])), uintptr(len(name)),
		uintptr(unsafe.Pointer(&serial)), uintptr(unsafe.Pointer(&maxComp)), uintptr(unsafe.Pointer(&flags)),
		uintptr(unsafe.Pointer(&fs[0])), uintptr(len(fs)))
	if r == 0 {
		return ""
	}
	return syscall.UTF16ToString(name)
}

// allVolumes lists every volume Windows knows, as \\?\Volume{guid} (no trailing slash).
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

type memoryStatusEx struct {
	Length               uint32
	MemoryLoad           uint32
	TotalPhys            uint64
	AvailPhys            uint64
	TotalPageFile        uint64
	AvailPageFile        uint64
	TotalVirtual         uint64
	AvailVirtual         uint64
	AvailExtendedVirtual uint64
}

func hostMemMiB() (total, avail uint64) {
	var m memoryStatusEx
	m.Length = uint32(unsafe.Sizeof(m))
	procGlobalMemoryStatusEx.Call(uintptr(unsafe.Pointer(&m)))
	return m.TotalPhys / (1024 * 1024), m.AvailPhys / (1024 * 1024)
}

// whpxPresent asks Windows whether the Hypervisor Platform is usable right now.
func whpxPresent() (bool, string) {
	dll := syscall.NewLazyDLL("WinHvPlatform.dll")
	if err := dll.Load(); err != nil {
		return false, "WinHvPlatform.dll is not on this PC (the Windows Hypervisor Platform feature is off)"
	}
	proc := dll.NewProc("WHvGetCapability")
	if err := proc.Find(); err != nil {
		return false, "WHvGetCapability not found"
	}
	var present uint32
	var written uint32
	hr, _, _ := proc.Call(0, uintptr(unsafe.Pointer(&present)), 4, uintptr(unsafe.Pointer(&written)))
	if hr != 0 {
		return false, fmt.Sprintf("WHvGetCapability failed (0x%x)", hr)
	}
	if present == 0 {
		return false, "the feature is installed but the hypervisor is not running (virtualization may be off in the PC's setup menu, or a restart is pending)"
	}
	return true, "present"
}

func portFree(p int) (bool, string) {
	l, err := net.Listen("tcp", fmt.Sprintf(":%d", p))
	if err != nil {
		return false, err.Error()
	}
	l.Close()
	return true, ""
}

func lanAddress() string {
	conn, err := net.Dial("udp", "192.0.2.1:9") // no packet is sent; this only picks the outgoing interface
	if err != nil {
		return ""
	}
	defer conn.Close()
	return conn.LocalAddr().(*net.UDPAddr).IP.String()
}

func run(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func copyFile(src, dst string) error {
	si, err := os.Stat(src)
	if err != nil {
		return err
	}
	// No skipping: an old file of the same size would be run as administrator.
	_ = si
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func copyTree(src, dst string) (int, error) {
	n := 0
	err := filepath.Walk(src, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(src, p)
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0755)
		}
		n++
		return copyFile(p, target)
	})
	return n, err
}

// ---------- step 1: started from the drive ----------

func fromDrive() {
	exe, _ := os.Executable()
	exe, _ = filepath.Abs(exe)
	srcDir := filepath.Dir(exe)
	if !isAdmin() {
		fmt.Println("Keephaven needs administrator rights to use the drive. Windows will ask once.")
		if err := relaunchAsAdmin(strings.Join(os.Args[1:], " ")); err != nil {
			fmt.Println("Could not ask for administrator rights:", err)
			fmt.Println("Right-click Keephaven.exe and choose 'Run as administrator'. Press Enter to close.")
			bufio.NewReader(os.Stdin).ReadString('\n')
		}
		return
	}
	// The folder is checked, or made with its own permissions, before one byte is written
	// inside it. This used to be an os.MkdirAll, which on Windows leaves ProgramData's
	// inherited permissions on the new folder — any user may create files in it — and the
	// safeFolder check forty lines further down then refused the helper's own folder. Every
	// PC's first start ended there, with the log that proved it sitting inside the folder the
	// helper had just made, and deleting the folder only repeated it. Nothing may create this
	// folder except safeFolder, which makes it in one step with the permissions already on it.
	if err := safeFolder(baseDir()); err != nil {
		stop("%s is not a folder this helper can trust (%v). It will not run QEMU out of a folder anyone else can change.", baseDir(), err)
	}
	logFile, _ = os.OpenFile(filepath.Join(baseDir(), "helper.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
	logf("Keephaven helper %s, started from %s", version, exe)

	vol := filepath.VolumeName(exe) // "E:"
	if len(vol) != 2 || vol[1] != ':' || !strings.EqualFold(volumeLabel(vol+`\`), "KEEPHAVEN") {
		// Not started from the drive (a downloaded copy, say): find the drive by its label.
		vol = ""
		for c := 'A'; c <= 'Z'; c++ {
			v := string(c) + ":"
			if strings.EqualFold(volumeLabel(v+`\`), "KEEPHAVEN") {
				if _, err := os.Stat(v + `\qemu\qemu-system-x86_64.exe`); err == nil {
					vol = v
					break
				}
			}
		}
		if vol == "" {
			stop("no Keephaven drive found. Plug the Keephaven drive in (it shows up as a drive named KEEPHAVEN) and start this again.")
		}
		logf("started from %s; the Keephaven drive is %s", srcDir, vol)
		srcDir = vol + `\`
	}
	disk, part, err := diskOf(`\\.\` + vol)
	if err != nil {
		stop("could not find which physical drive %s is on: %v", vol, err)
	}
	sysVol := os.Getenv("SystemDrive")
	if sysVol == "" {
		sysVol = "C:"
	}
	sysDisk, _, err := diskOf(`\\.\` + sysVol)
	if err != nil {
		stop("could not find which physical drive Windows (%s) is on: %v", sysVol, err)
	}
	logf("the Keephaven drive is physical drive %d (this partition is number %d); Windows runs from physical drive %d", disk, part, sysDisk)
	if disk == sysDisk {
		stop("the Keephaven partition is on the same physical drive as Windows. Refusing to touch it.")
	}

	runDir := filepath.Join(baseDir(), "run")
	os.MkdirAll(runDir, 0755)
	logf("copying the helper and QEMU to %s (only an administrator may write there; the drive is about to be handed over) …", runDir)
	n, err := copyTree(filepath.Join(srcDir, "qemu"), filepath.Join(runDir, "qemu"))
	// TEST BUILDS ONLY: our own QEMU builds, when the drive carries them, for side-by-side starts.
	for _, extra := range testExtraQemuDirs() {
		if _, e := os.Stat(filepath.Join(srcDir, extra)); e == nil && err == nil {
			var m int
			m, err = copyTree(filepath.Join(srcDir, extra), filepath.Join(runDir, extra))
			n += m
		}
	}
	if err != nil {
		stop("could not copy QEMU from the drive: %v", err)
	}
	logf("copied %d QEMU files", n)

	extra := ""
	for _, a := range os.Args[1:] {
		extra += " " + a
	}
	// This helper, unless a test build is told to take a newer one from the build laptop.
	newest, _ := os.ReadFile(exe)
	newest = testNewerHelper(newest)
	if err := os.WriteFile(filepath.Join(runDir, "Keephaven.exe"), newest, 0755); err != nil {
		stop("could not write the helper to %s: %v", runDir, err)
	}
	if onDrive, err := os.ReadFile(filepath.Join(srcDir, "Keephaven.exe")); err != nil || sha256.Sum256(onDrive) != sha256.Sum256(newest) {
		if err := os.WriteFile(filepath.Join(srcDir, "Keephaven.exe"), newest, 0755); err == nil {
			logf("the drive's own Keephaven.exe was replaced with this newer helper")
		} else {
			logf("could not refresh the drive's own Keephaven.exe (%v); carrying on", err)
		}
	}

	// The copy gets its own console window and runs from the PC's own disk.
	args := append([]string{"--run", strconv.Itoa(int(disk))}, os.Args[1:]...)
	cmd := exec.Command(filepath.Join(runDir, "Keephaven.exe"), args...)
	cmd.Dir = runDir
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x00000010} // CREATE_NEW_CONSOLE
	if err := cmd.Start(); err != nil {
		stop("could not start the copy: %v", err)
	}
	logFile.Close()
}

// ---------- step 2: running from the PC's own disk ----------

type lockedVolume struct {
	name string
	h    syscall.Handle
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

func takeDrive(disk uint32) []lockedVolume {
	var held []lockedVolume
	names := allVolumes()
	for c := 'A'; c <= 'Z'; c++ {
		names = append(names, `\\.\`+string(c)+":")
	}
	seen := map[uint32]bool{}
	for _, v := range names {
		d, part, err := diskOf(v)
		if err != nil || d != disk || seen[part] {
			continue
		}
		seen[part] = true
		h, err := openDevice(v, genericRead|genericWrite)
		if err != nil {
			logf("  partition %d (%s): could not open: %v", part, v, err)
			continue
		}
		var n uint32
		first := lockVolume(h, 3)
		dism := syscall.DeviceIoControl(h, fsctlDismountVolume, nil, 0, nil, 0, &n, nil)
		// A forced dismount invalidates other programs' handles, so the lock usually works now.
		final := first
		if first != nil {
			final = lockVolume(h, 5)
		}
		for final != nil {
			logf("  partition %d (%s): Windows still has it open (%v).", part, v, final)
			logf("  Close any File Explorer window showing the Keephaven drive, then press Enter here.")
			bufio.NewReader(os.Stdin).ReadString('\n')
			syscall.DeviceIoControl(h, fsctlDismountVolume, nil, 0, nil, 0, &n, nil)
			final = lockVolume(h, 5)
		}
		logf("  partition %d (%s): first lock=%v dismount=%v locked=ok", part, v, errStr(first), errStr(dism))
		held = append(held, lockedVolume{v, h})
	}
	return held
}

// ---------- QEMU dies with the helper ----------

type jobBasicLimit struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type jobExtendedLimit struct {
	Basic                 jobBasicLimit
	IoInfo                [6]uint64
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

// newKillOnCloseJob returns a job: every process put in it is ended when this helper
// goes away, however it goes away. Without it, closing this window would leave QEMU
// writing to a drive Windows has just taken back.
func newKillOnCloseJob() uintptr {
	job, _, _ := procCreateJobObjectW.Call(0, 0)
	if job == 0 {
		return 0
	}
	var info jobExtendedLimit
	info.Basic.LimitFlags = 0x2000 // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	procSetInformationJobObject.Call(job, 9, uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info))
	return job
}

func putInJob(job uintptr, pid int) error {
	if job == 0 {
		return fmt.Errorf("no job object")
	}
	h, err := syscall.OpenProcess(0x1F0FFF, false, uint32(pid))
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(h)
	r, _, e := procAssignProcessToJob.Call(job, uintptr(h))
	if r == 0 {
		return e
	}
	return nil
}

func serialHas(path, text string) bool {
	b, err := os.ReadFile(path)
	return err == nil && strings.Contains(string(b), text)
}

func errStr(err error) string {
	if err == nil {
		return "ok"
	}
	return err.Error()
}

type attempt struct {
	accel, cpu, display string
	smp                 int
	cache               string // QEMU's cache mode for the drive ("" = its default, writeback)
	iothread            bool   // the drive's requests on a thread of their own
	power               string // "full": tell Windows not to treat QEMU as a background program
	prio                string // "high": run QEMU above normal priority
	trace               string // TEST: "blk" logs each drive request with a time stamp; "deep" every step of it; "locks" every lock too
	nodisplay           bool   // TEST: no QEMU window
	nomerge             bool   // TEST: virtio-blk hands requests on one at a time
	pool                int    // TEST: most worker threads QEMU may use for the drive (0 = its default, 64)
	fixedLen            bool   // TEST: run the copy of QEMU that does not re-ask the drive for its size (see fixedLenQemu)
	build               string // TEST: which QEMU on the drive: "" the downloaded one, "kh" our own build, "khfix" ours with the fix
	pull                bool   // TEST: end the running Keephaven like a pulled plug before this start
	awake               bool   // TEST: keep one processor busy so the chip never dozes
	quiet               int    // TEST starts: give up after this many seconds of console silence (0 = never)
}

// TEST BUILDS ONLY: a start asked for by the build laptop (see /again).

func defaultSmp() int {
	if n := runtime.NumCPU(); n < 4 {
		return n
	}
	return 4
}

// QEMU's control channel. It can stop the machine and read and write its memory, and QEMU
// here runs as administrator with the raw drive, so it must not be reachable by anything
// else on this PC. It is a Windows pipe, not a socket: QEMU creates it with the default
// security of an elevated process, which gives no other user the write access a command
// needs. The name is random per run so nothing can sit on it first, and the helper checks
// the process at the other end is the QEMU it started before it says a word.
var (
	qmpName string
	qmpPid  int
	qmpMu   sync.Mutex
	qmpConn syscall.Handle
)

func newQmpName() string {
	b := make([]byte, 16)
	rand.Read(b)
	return fmt.Sprintf("keephaven-%x", b)
}

// connectQmp opens QEMU's control pipe and keeps it open for the whole run. It has to:
// QEMU waits at start-up until something connects (chardev/char-pipe.c waits on
// ConnectNamedPipe), and it takes exactly one connection, so holding it both lets the
// machine boot and leaves nothing for anything else to connect to.
func connectQmp(pid int, gone <-chan struct{}) {
	name := `\\.\pipe\` + qmpName
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		h, err := syscall.CreateFile(utf16ptr(name), genericRead|genericWrite, 0, nil, syscall.OPEN_EXISTING, 0, 0)
		if err != nil {
			select {
			case <-gone:
				return
			case <-time.After(200 * time.Millisecond):
			}
			continue
		}
		var owner uint32
		r, _, e := procGetNamedPipeServerProcessId.Call(uintptr(h), uintptr(unsafe.Pointer(&owner)))
		if r == 0 || int(owner) != pid {
			syscall.CloseHandle(h)
			logf("  the control channel is not this QEMU's (owner %d, QEMU %d, %v); a clean shutdown will not be possible", owner, pid, e)
			return
		}
		qmpMu.Lock()
		qmpConn = h
		qmpMu.Unlock()
		// QMP takes no command until this.
		qmpWrite(h, `{"execute":"qmp_capabilities"}`+"\n")
		// QEMU's own events have to be taken out of the pipe or it stops writing, but a read
		// left parked on this handle would hold up the shutdown command: the handle is a
		// plain one, and Windows runs one operation at a time on such a handle. So look
		// first and read only what is already there.
		go func() {
			for {
				select {
				case <-gone:
					// QEMU writes its SHUTDOWN event and THEN exits, and the waiter closes
					// `gone` BEFORE it reports the exit - so this goroutine can get here with
					// the reason still sitting unread in the pipe. Returning now loses it, a
					// reboot then looks like a stop, the relaunch never fires and the drive is
					// left down mid-update: the exact failure the relaunch exists to prevent.
					// Drain once before letting go. Found by the verifier reading e8a0f84.
					drainQmp(h)
					return
				case <-time.After(250 * time.Millisecond):
				}
				if !drainQmp(h) {
					return
				}
			}
		}()
		return
	}
	logf("  QEMU's control channel never opened; a clean shutdown will not be possible")
}

// drainQmp takes whatever is already in QEMU's control pipe and looks for the reason it is
// stopping. QEMU's SHUTDOWN event carries that reason: guest-reset for a reboot the GUEST asked
// for, guest-shutdown or host-qmp-system-powerdown otherwise. Only the first earns a relaunch.
// Reads only what Peek says is there: a read left parked on this handle would hold up the
// shutdown command, because the handle is a plain one and Windows runs one operation at a time
// on it. Returns false when the reader should stop for good.
func drainQmp(h syscall.Handle) bool {
	buf := make([]byte, 64*1024)
	for {
		qmpMu.Lock()
		if qmpConn != h {
			qmpMu.Unlock()
			return false
		}
		var avail uint32
		ok, _, _ := procPeekNamedPipe.Call(uintptr(h), 0, 0, 0, uintptr(unsafe.Pointer(&avail)), 0)
		if ok == 0 || avail == 0 {
			qmpMu.Unlock()
			return true
		}
		n := uint32(len(buf))
		if avail < n {
			n = avail
		}
		var got uint32
		err := syscall.ReadFile(h, buf[:n], &got, nil)
		qmpMu.Unlock()
		if err != nil {
			return false
		}
		if got > 0 && strings.Contains(string(buf[:got]), `"guest-reset"`) {
			guestReset.Store(true)
		}
	}
}

func qmpWrite(h syscall.Handle, line string) error {
	b := []byte(line)
	var n uint32
	return syscall.WriteFile(h, b, &n, nil)
}

func closeQmp() {
	qmpMu.Lock()
	h := qmpConn
	qmpConn = 0
	qmpMu.Unlock()
	if h != 0 {
		syscall.CloseHandle(h)
	}
}

// qmp sends commands on the held control channel. The write is given a limit of its own:
// if QEMU has stopped reading, the caller falls back to ending the process.
func qmp(cmds ...string) error {
	done := make(chan error, 1)
	go func() {
		qmpMu.Lock()
		defer qmpMu.Unlock()
		if qmpConn == 0 {
			done <- fmt.Errorf("no control channel")
			return
		}
		for _, c := range cmds {
			b, _ := json.Marshal(map[string]string{"execute": c})
			if err := qmpWrite(qmpConn, string(b)+"\n"); err != nil {
				done <- err
				return
			}
		}
		done <- nil
	}()
	select {
	case err := <-done:
		return err
	case <-time.After(5 * time.Second):
		return fmt.Errorf("the control channel did not take the command within 5 s")
	}
}

// takeAwayTheCloseButton greys out this window's X (and Alt+F4 with it) so the only way to
// stop Keephaven is typing q, which is what the window has always told people to do.
//
// His call, 2026-10-13, after the close button was tested twice. It cannot be made safe:
// Windows allows a console program about five seconds after the X before killing it, a clean
// Keephaven stop measured 4 s and 5 s, and the drive still has to be given back and Windows
// told to re-read it afterwards. The second attempt got as far as "Unmounting file systems"
// and was cut half a second short, with the helper announcing the drive safe while Keephaven
// was still writing to it. A door that cannot be made safe is better not there.
//
// Only if this console is ours alone. Someone running the helper from a command prompt they
// already had open would otherwise find we had disabled the close button on THEIR window.
// The ctrl handler stays registered either way: the X is not the only way a console dies —
// a sign-out, a shutdown, or Task Manager all still arrive there.
func takeAwayTheCloseButton() {
	var pids [4]uint32
	n, _, _ := procGetConsoleProcessList.Call(uintptr(unsafe.Pointer(&pids[0])), uintptr(len(pids)))
	if n != 1 {
		logf("this window was already open before Keephaven started, so its close button is left alone. Type q to stop.")
		return
	}
	hwnd, _, _ := procGetConsoleWindow.Call()
	if hwnd == 0 {
		return
	}
	menu, _, _ := procGetSystemMenu.Call(hwnd, 0)
	if menu == 0 {
		return
	}
	if ok, _, _ := procDeleteMenu.Call(menu, 0xF060 /* SC_CLOSE */, 0 /* MF_BYCOMMAND */); ok != 0 {
		procDrawMenuBar.Call(hwnd)
		logf("this window's close button is switched off on purpose: closing it cannot stop Keephaven safely. Type q and press Enter.")
	}
}

func runMode(disk uint32, slow bool) {
	// This copy was started by the first step with no input or output attached (Go gives a
	// child the null device unless told otherwise). It has its own console window: use it.
	if f, err := os.OpenFile("CONOUT$", os.O_RDWR, 0); err == nil {
		os.Stdout, os.Stderr = f, f
	}
	if f, err := os.OpenFile("CONIN$", os.O_RDWR, 0); err == nil {
		os.Stdin = f
	}
	takeAwayTheCloseButton()
	// Same rule here as in the first step: never make this folder with a plain MkdirAll. The
	// first step has already made and checked it, so this is a check that costs nothing and
	// cannot leave an unsafe folder behind if anything has changed underneath.
	if err := safeFolder(baseDir()); err != nil {
		stop("%s is not a folder this helper can trust (%v).", baseDir(), err)
	}
	if b, err := os.ReadFile(filepath.Join(baseDir(), "helper.log")); err == nil {
		for _, l := range strings.Split(strings.TrimSpace(strings.ReplaceAll(string(b), "\r", "")), "\n") {
			logBuf = append(logBuf, l) // the first step's lines, so the status page shows the whole run
		}
	}
	logFile, _ = os.OpenFile(filepath.Join(baseDir(), "helper.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0644)
	testServe()
	exe, _ := os.Executable()
	runDir := filepath.Dir(exe)
	qdir := filepath.Join(runDir, "qemu")
	qemu := filepath.Join(qdir, "qemu-system-x86_64.exe")
	os.Chdir(runDir) // a working directory on the drive would keep its volume open
	logf("Keephaven helper %s running from %s, for physical drive %d", version, runDir, disk)
	if b, err := os.ReadFile(exe); err == nil {
		logf("this helper: %d bytes, sha256 %x", len(b), sha256.Sum256(b))
	}
	if d, _, err := diskOf(`\\.\` + filepath.VolumeName(exe)); err == nil && d == disk {
		stop("this copy of the helper is running from the Keephaven drive itself, so the drive cannot be handed over. Start Keephaven.exe from the drive by double-clicking it; it copies itself to this PC first.")
	}

	// ---- the PC ----
	osName, _ := run(sys32("cmd.exe"), "/c", "ver")
	total, avail := hostMemMiB()
	logf("this PC: %s | %d processors | memory %d MB, %d MB free", osName, runtime.NumCPU(), total, avail)
	if out, err := run(sys32("reg.exe"), "query", `HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0`, "/v", "ProcessorNameString"); err == nil {
		if i := strings.Index(out, "REG_SZ"); i >= 0 {
			logf("processor: %s", strings.TrimSpace(out[i+6:]))
		}
	}
	if total < minHostMemMiB {
		stop("this PC has %d MB of memory. Keephaven Photos needs a PC with 8 GB.", total)
	}
	checkQemu(runDir)
	ver, _ := run(qemu, "--version")
	logf("QEMU: %s", firstLine(ver))
	accels, _ := run(qemu, "-accel", "help")
	for _, extra := range testExtraQemuDirs() {
		x := filepath.Join(runDir, extra, "qemu-system-x86_64.exe")
		if b, err := os.ReadFile(x); err == nil {
			v, verr := run(x, "--version")
			a, _ := run(x, "-accel", "help")
			logf("%s: %d bytes, sha256 %x | %s (%s) | accelerators: %s", extra, len(b), sha256.Sum256(b), firstLine(v), errStr(verr), strings.Join(strings.Fields(a), " "))
		}
	}
	logf("QEMU accelerators: %s", strings.Join(strings.Fields(accels), " "))
	hv, why := whpxPresent()
	logf("Windows Hypervisor Platform: %v (%s)", hv, why)
	if !hv && !slow {
		logf("")
		logf("Keephaven needs the Windows Hypervisor Platform to run at a usable speed, and it is not available:")
		logf("  %s", why)
		logf("To switch it on, type YES and press Enter. Windows will need a restart afterwards.")
		logf("(To try it anyway, very slowly, close this and start Keephaven.exe with --slow.)")
		fmt.Print("> ")
		ans, _ := bufio.NewReader(os.Stdin).ReadString('\n')
		if strings.EqualFold(strings.TrimSpace(ans), "YES") {
			out, err := run(sys32("dism.exe"), "/online", "/Enable-Feature", "/FeatureName:HypervisorPlatform", "/All", "/NoRestart")
			logf("dism: %s (%v)", lastLines(out, 3), errStr(err))
			stop("Restart Windows, then start Keephaven.exe again. If it still says this after a restart, virtualization is switched off in the PC's own setup menu.")
		}
		stop("not started.")
	}
	for _, p := range guestPorts {
		if ok, why := portFree(p); !ok {
			holder, _ := run(sys32("cmd.exe"), "/c", fmt.Sprintf("netstat -ano | findstr LISTENING | findstr :%d", p))
			stop("port %d on this PC is already in use (%s). In use by: %s", p, why, firstLine(holder))
		}
	}
	logf("ports %v are free", guestPorts)

	// ---- the firewall: let other devices on the home network in ----
	run(sys32("netsh.exe"), "advfirewall", "firewall", "delete", "rule", "name=Keephaven")
	ports := strings.Join(append([]string{"80", "8888", "2283"}, testFirewallPorts()...), ",")
	// Named for QEMU alone, so the opening belongs to this program and not to whatever else
	// might listen on those ports later. It is taken away again when Keephaven stops.
	out, err := run(sys32("netsh.exe"), "advfirewall", "firewall", "add", "rule", "name=Keephaven", "dir=in", "action=allow",
		"protocol=TCP", "localport="+ports, "profile=private,domain", "program="+qemu)
	logf("firewall rule for ports %s on private networks, for %s: %s (%v)", ports, filepath.Base(qemu), firstLine(out), errStr(err))
	atExit(func() {
		run(sys32("netsh.exe"), "advfirewall", "firewall", "delete", "rule", "name=Keephaven")
		logf("the firewall rule is gone")
	})
	prof, _ := run(sys32("netsh.exe"), "advfirewall", "show", "currentprofile", "state")
	logf("this PC's network is treated as: %s", firstLine(prof))
	if strings.Contains(strings.ToLower(prof), "public") {
		logf("  NOTE: on a network Windows calls Public, other devices cannot reach Keephaven on this PC.")
		logf("  Mark your home network as Private in Windows' network settings to let your phone in.")
	}

	// ---- take the drive away from Windows ----
	logf("taking the drive away from Windows while Keephaven runs (it comes back when Keephaven stops):")
	held := takeDrive(disk)
	atExit(func() {
		// QEMU goes FIRST, before a single handle is let go. It holds the raw disk, so while it
		// lives the partition re-read fails ("being used by another process") and — far worse —
		// the lines below would announce the drive as safe to unplug while Keephaven was still
		// writing to its root. That is exactly what happened on the HP at 22:43 when the window
		// was closed: the guest got as far as unmounting, Windows' five seconds ran out, and
		// this ran with QEMU alive. Releasing is not releasing until the thing holding it is gone.
		if !qemuGone() {
			logf("  Keephaven has not finished stopping; ending it now so the drive can be given back.")
			if pid := qemuPid.Load(); pid != 0 {
				if h, err := syscall.OpenProcess(0x0001 /* PROCESS_TERMINATE */, false, uint32(pid)); err == nil {
					syscall.TerminateProcess(h, 1)
					syscall.CloseHandle(h)
				}
			}
			for i := 0; i < 30 && !qemuGone(); i++ {
				time.Sleep(100 * time.Millisecond)
			}
		}
		n := len(held)
		for _, v := range held {
			syscall.CloseHandle(v.h)
		}
		held = nil
		// Only after every volume handle is closed, or Windows re-reads the table while it
		// still thinks the volumes are locked.
		if n > 0 {
			// Say so either way. The whole point of this call is a thing you cannot see in the
			// log afterwards — whether Windows went and looked again — so it has to be written
			// down, not inferred from the absence of a complaint.
			reread := rereadPartitions(disk)
			procSetThreadExecutionState.Call(0x80000000)
			if reread == nil {
				logf("the drive is back with Windows (%d partitions released) and Windows has re-read it, so it sees every partition. It is SAFE TO UNPLUG.", n)
			} else {
				// Say the true thing. An owner who is told "safe to unplug" and then finds ~900 GB
				// of their drive showing as unallocated is one Format away from losing the lot.
				logf("the drive is back with Windows (%d partitions released), but Windows would not re-read it (%v).", n, reread)
				logf("  Unplug the drive and plug it in again before you look at it: until you do, Windows will show part of it as empty space. Do not format anything.")
			}
		} else {
			procSetThreadExecutionState.Call(0x80000000)
		}
	})
	if len(held) == 0 {
		logf("  no mounted volumes found on physical drive %d", disk)
	}
	defer func() {
		for _, v := range held {
			syscall.CloseHandle(v.h)
		}
	}()

	testHostChecks(disk)

	procSetThreadExecutionState.Call(0x80000001) // don't idle-sleep while this runs

	// ---- start QEMU, trying the likely settings in order ----
	vars := filepath.Join(baseDir(), "vars.fd")
	if err := func() error {
		os.Remove(vars)
		in, err := os.Open(filepath.Join(qdir, "OVMF_VARS.fd"))
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.Create(vars)
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	}(); err != nil {
		stop("could not prepare the firmware settings file: %v", err)
	}
	serial := filepath.Join(baseDir(), "keephaven-serial.log")
	os.Remove(serial)
	testTail(serial)
	var tries []attempt
	if hv {
		tries = append(tries, testFirstAttempts()...)
		for _, cpu := range []string{"Haswell-noTSX", "qemu64", "max"} {
			// sdl only. Our stripped QEMU has no GTK — "Parameter 'type' does not accept value
			// 'gtk'" on the HP, 2026-10-12 — so every gtk attempt died in under a second and
			// wasted half the ladder in the log. Nothing is lost: they never once started.
			for _, disp := range []string{"sdl,window-close=off"} {
				tries = append(tries, attempt{accel: "whpx,kernel-irqchip=off", cpu: cpu, display: disp, smp: defaultSmp()})
			}
		}
	}
	if slow || !hv {
		tries = append(tries,
			attempt{accel: "tcg,thread=multi", cpu: "max", display: "sdl,window-close=off", smp: defaultSmp()})
	}
	var cmd *exec.Cmd
	var done chan error
	var tStart time.Time
	job := newKillOnCloseJob()
	// Closing this window: ask Keephaven to shut down in the few seconds Windows allows.
	procSetConsoleCtrlHandler.Call(syscall.NewCallback(func(ctrl uint32) uintptr {
		// Windows gives a console program about five seconds here and then kills it, so this
		// is best effort and `q` is still the way that cannot run out of time. A clean stop
		// took 4 s and 5 s on the two typed stops measured on the HP, so it usually fits.
		logf("the window was closed; asking Keephaven to shut down. Typing q is the sure way.")
		qmp("system_powerdown")
		deadline := time.Now().Add(4500 * time.Millisecond)
		for time.Now().Before(deadline) {
			if qemuGone() {
				logf("Keephaven shut down before the window closed.")
				break
			}
			time.Sleep(100 * time.Millisecond)
		}
		if !qemuGone() {
			logf("Keephaven did not finish shutting down in the time Windows allows. Start it again and let it come up before stopping it.")
		}
		runExit()
		return 0
	}), 1)

	// endQemu ends a QEMU that is not wanted any more, without waiting for Keephaven.
	endQemu := func() {
		askedToStop.Store(true)
		qmp("quit")
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			cmd.Process.Kill()
			<-done
		}
	}
	// startQemu starts QEMU once and waits for Keephaven's kernel. On false, QEMU is gone again.
	// Started means: QEMU is alive AND the firmware has handed over to the kernel. A wrong CPU
	// model under the hypervisor freezes in the firmware; it doesn't exit.
	startQemu := func(label string, t attempt) bool {
		// The control pipe's name goes into the args below, so it has to exist BEFORE they are
		// built. It used to be generated thirty lines further down, after the args, and that
		// cost us the whole first run on a PC: the first attempt passed "path=" with nothing
		// after it and QEMU refused to start ("Failed CreateNamedPipe"), and every later
		// attempt passed the PREVIOUS attempt's name while the helper waited on the new one, so
		// the control channel could never open and a clean shutdown was never possible. The
		// name and the args have to be made in that order, in one place. HP, 2026-10-12 18:09.
		closeQmp()
		qemuPid.Store(0)
		askedToStop.Store(false)
		guestReset.Store(false)
		qmpName, qmpPid = newQmpName(), 0
		args := []string{
			"-name", "Keephaven", "-machine", "q35", "-accel", t.accel, "-cpu", t.cpu,
			// A guest reboot EXITS QEMU instead of resetting the machine in place. Resetting in
			// place hangs under WHPX (see guestReset above); the loop below starts it again.
			"-no-reboot",
			"-m", strconv.Itoa(guestMemMiB), "-smp", strconv.Itoa(t.smp),
			"-drive", "if=pflash,format=raw,readonly=on,file=" + filepath.Join(qdir, "OVMF_CODE.fd"),
			"-drive", "if=pflash,format=raw,file=" + vars,
			"-nic", "user,model=virtio-net-pci,hostfwd=tcp::80-:80,hostfwd=tcp::8888-:8888,hostfwd=tcp::2283-:2283",
			"-display", map[bool]string{false: t.display, true: "none"}[t.nodisplay], "-vga", "std",
			"-serial", "file:" + serial,
			"-chardev", "pipe,id=khqmp,path=" + qmpName, "-mon", "chardev=khqmp,mode=control",
			"-L", filepath.Join(qdir, "share"),
		}
		drive := fmt.Sprintf(`file=\\.\PhysicalDrive%d,format=raw,discard=unmap`, disk)
		if t.cache != "" {
			drive += ",cache=" + t.cache
		}
		switch {
		case t.iothread || t.nomerge:
			dev := "virtio-blk-pci,drive=khdrive,bootindex=0"
			if t.iothread {
				args = append(args, "-object", "iothread,id=khio")
				dev += ",iothread=khio"
			}
			if t.nomerge {
				dev += ",request-merging=off"
			}
			args = append(args, "-drive", drive+",if=none,id=khdrive", "-device", dev)
		default:
			args = append(args, "-drive", drive+",if=virtio")
		}
		if t.pool > 0 {
			args = append(args, "-object", fmt.Sprintf("main-loop,id=khmain,thread-pool-min=1,thread-pool-max=%d", t.pool))
		}
		args = testTraceArgs(t, args)
		exe, share, ok := testPickQemu(t, label, runDir, qemu, filepath.Join(qdir, "share"))
		if !ok {
			return false
		}
		for i, a := range args {
			if a == "-L" && i+1 < len(args) {
				args[i+1] = share
			}
		}
		logf("%s: accel=%s cpu=%s smp=%d display=%s%s", label, t.accel, t.cpu, t.smp, t.display, testSettings(t))
		os.Remove(serial)
		testMark(fmt.Sprintf("%s: accel=%s cpu=%s smp=%d", label, t.accel, t.cpu, t.smp))
		cmd = exec.Command(exe, args...)
		cmd.Dir = qdir
		// QEMU gets no console of its own and, more to the point, is NOT attached to this
		// helper's console. Closing the helper's window sends CTRL_CLOSE_EVENT to every
		// process on that console, and QEMU's own handler (os-win32.c) exits at once — so on
		// 2026-10-12 the X killed Keephaven where it stood, 22 minutes in, with its database
		// mid-write: 0 shutdown lines in Keephaven's console against 17 for a typed stop. The
		// request to shut down never got a chance to work. Out of the console, only this
		// helper hears the close, and it can ask Keephaven to stop properly.
		cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: 0x08000000} // CREATE_NO_WINDOW
		errPipe, _ := cmd.StderrPipe()
		outPipe, _ := cmd.StdoutPipe()
		if err := cmd.Start(); err != nil {
			logf("  could not start QEMU: %v", err)
			return false
		}
		qemuWasStarted = true // Keephaven has had the raw drive from here on
		qemuPid.Store(int64(cmd.Process.Pid))
		tStart = time.Now()
		qmpPid = cmd.Process.Pid
		for _, p := range []io.Reader{errPipe, outPipe} {
			go func(r io.Reader) {
				sc := bufio.NewScanner(r)
				for sc.Scan() {
					if !strings.Contains(sc.Text(), "host doesn't support requested feature") {
						logf("  qemu: %s", sc.Text())
					}
				}
			}(p)
		}
		if err := putInJob(job, cmd.Process.Pid); err != nil {
			logf("  note: QEMU is not tied to this window (%v)", err)
		}
		testTune(t, cmd.Process.Pid)
		done = make(chan error, 1)
		gone := make(chan struct{})
		go func(c *exec.Cmd, d chan error) {
			err := c.Wait()
			close(gone)
			d <- err
		}(cmd, done)
		// QEMU is waiting for this before it does anything else.
		go connectQmp(cmd.Process.Pid, gone)
		testWhileRunning(t, gone)
		limit := 40 * time.Second
		if strings.HasPrefix(t.accel, "tcg") {
			limit = 180 * time.Second
		}
		deadline := time.Now().Add(limit)
		for time.Now().Before(deadline) {
			select {
			case err := <-done:
				logf("  QEMU stopped (%v)", errStr(err))
				return false
			case <-time.After(time.Second):
				if serialHas(serial, "EFI stub") || serialHas(serial, "Linux version") {
					logf("QEMU is running and Keephaven's kernel has started after %d s", int(time.Since(tStart).Seconds()))
					return true
				}
			}
		}
		logf("  no sign of Keephaven's kernel after %d s with these settings; stopping this attempt", int(limit.Seconds()))
		endQemu()
		if b, err := os.ReadFile(serial); err == nil && len(b) > 0 {
			logf("  serial log of that attempt: %s", lastLines(string(b), 3))
		}
		return false
	}
	// untilUp waits for the dashboard, logging how busy QEMU is meanwhile.
	untilUp := func(quietLimit time.Duration, cut bool) (up, quiet, exited bool) {
		stopCPU := make(chan struct{})
		testWatch(cmd.Process.Pid, stopCPU)
		defer close(stopCPU)
		return waitForKeephaven(tStart, done, quietLimit, cut)
	}
	shutdown := func() {
		askedToStop.Store(true)
		logf("asking Keephaven to shut down …")
		if err := qmp("system_powerdown"); err != nil {
			// Nothing heard the request, so there is nothing to wait for.
			logf("  Keephaven could not be asked to shut down (%v); stopping it instead", err)
			cmd.Process.Kill()
			select {
			case <-done:
			case <-time.After(10 * time.Second):
			}
			return
		}
		select {
		case <-done:
			logf("Keephaven shut down cleanly.")
		case <-time.After(150 * time.Second):
			logf("Keephaven did not stop within 150 s; stopping QEMU.")
			qmp("quit")
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				cmd.Process.Kill()
			}
		}
	}

	started := false
	var won attempt // the settings that worked, for a relaunch after the guest reboots itself
	for i, t := range tries {
		if startQemu(fmt.Sprintf("start attempt %d of %d", i+1, len(tries)), t) {
			started = true
			won = t
			break
		}
		time.Sleep(time.Second)
	}
	if !started {
		stop("QEMU would not start with any of the settings tried. The lines above marked 'qemu:' say why.")
	}

	// ---- wait for Keephaven itself ----
	up, _, exited := untilUp(0, false)
	if exited {
		stop("QEMU stopped while Keephaven was starting. See the 'qemu:' lines above and %s", serial)
	}
	if !up {
		logf("Keephaven has not answered on port 80 after 15 minutes. It may still be starting; the QEMU window shows its screen.")
	}
	ip := lanAddress()
	logf("")
	logf("KEEPHAVEN IS RUNNING.")
	logf("  On this PC:                 http://localhost")
	if ip != "" {
		logf("  On your phone (home Wi-Fi): http://%s", ip)
	}
	// Not "the setup password": there is no password anywhere in setup — the page is a few
	// buttons and no fields at all. What that screen draws is the password from ap.env, which
	// is the Wi-Fi password a box on its own hands out AND the file-sharing and app-account
	// password (setup-screen.nix, samba.nix, provision.nix). Calling it a setup password sent
	// him hunting the HP's screen for something that does not exist, and it would send an
	// owner hunting too.
	logf("  The other window is Keephaven's own screen. Setup asks for no password: open the")
	logf("  address above and tap through it. The password on that screen is the one for file")
	logf("  sharing and for the apps inside Keephaven.")
	logf("")
	logf("To stop: type q and press Enter here. Wait for 'safe to unplug' before pulling the drive.")

	// One reader for this window's keyboard, so a line typed here is never taken by the wrong wait.
	lines := make(chan string)
	go func() {
		r := bufio.NewReader(os.Stdin)
		for {
			s, err := r.ReadString('\n')
			if err != nil {
				close(lines)
				return
			}
			lines <- strings.TrimSpace(s)
		}
	}()
	running := true
	relaunches := 0
	const maxRelaunch = 3
loop:
	for {
		var gone chan error // only watched while QEMU is running
		if running {
			gone = done
		}
		select {
		case <-gone:
			// A reboot the GUEST asked for is not a stop: an update restarts Keephaven, and
			// with -no-reboot that arrives here as an exit. Start it again with the settings
			// that already worked. Only on QMP's own guest-reset reason, only while nothing
			// asked it to stop, and only a few times, so a guest that reboots in a loop cannot
			// keep this window alive for ever.
			if guestReset.Swap(false) && !askedToStop.Load() && relaunches < maxRelaunch {
				relaunches++
				logf("")
				logf("Keephaven restarted itself - an update, most likely. Starting it again (%d of %d).", relaunches, maxRelaunch)
				logf("  Leave the drive in and leave this window open. This can take a few minutes.")
				// `-serial file:` truncates on each start, so without this the boot that
				// explains the restart is erased by the boot that follows it - and that log is
				// the only record of what the drive did.
				if err := os.Rename(serial, fmt.Sprintf("%s.%d", serial, relaunches)); err != nil {
					logf("  note: could not keep the previous serial log (%v)", err)
				}
				if startQemu(fmt.Sprintf("restart %d of %d after Keephaven rebooted itself", relaunches, maxRelaunch), won) {
					if up, _, exited := untilUp(0, false); exited {
						logf("  Keephaven stopped again while it was starting; the lines above say why.")
					} else if !up {
						logf("  Keephaven has not answered on port 80 yet. It may still be installing.")
					} else {
						logf("KEEPHAVEN IS RUNNING AGAIN.")
						logf("  On this PC:                 http://localhost")
						if ip := lanAddress(); ip != "" {
							logf("  On your phone (home Wi-Fi): http://%s", ip)
						}
						logf("To stop: type q and press Enter here.")
					}
					continue loop
				}
				logf("  it would not start again with the same settings; the lines above say why.")
				running = false
				break loop
			}
			// "by itself (ok)" was printed here whatever happened, including the 2026-10-12
			// run where the window's close button cut Keephaven off 22 minutes in with no
			// shutdown at all. Nobody asked it to stop, so say that rather than "ok".
			logf("Keephaven stopped without being asked to. If you did not shut it down,")
			logf("  it was cut off rather than closed down; the lines above say what happened.")
			running = false
			break loop
		case s, ok := <-lines:
			if !ok {
				lines = nil // no keyboard: only the window's close button stops it now
			} else if strings.EqualFold(s, "q") {
				break loop
			}
		case <-remoteStop:
			logf("a stop was asked for from the build laptop")
			break loop
		case t := <-nextRun:
			// TEST BUILDS ONLY. The drive stays held throughout.
			logf("")
			logf("TEST: the build laptop asked for a restart with other settings. Leave the drive in.")
			if running {
				if t.pull {
					logf("TEST: ending Keephaven like a pulled plug first (no shutdown), as asked.")
					endQemu()
				} else {
					shutdown()
				}
				running = false
				time.Sleep(2 * time.Second)
			}
			if startQemu("TEST start", t) {
				up, quiet, exited := untilUp(time.Duration(t.quiet)*time.Second, true)
				switch {
				case exited:
					logf("TEST: QEMU stopped before Keephaven answered.")
				case quiet:
					logf("TEST: Keephaven's console was silent for %d s and it has not answered; ending this start.", t.quiet)
					endQemu()
				case !up && len(nextRun) > 0 && !serialHas(serial, "verdict="):
					// Still inside the read-only check: nothing is mounted for writing, so ending QEMU here is safe.
					logf("TEST: the next start is already queued and this one is still in its read-only check; ending it.")
					endQemu()
				default:
					running = true
					if !up {
						logf("TEST: Keephaven has not answered yet; QEMU is still running.")
					}
				}
			}
			if running {
				logf("TEST: Keephaven is running again. To stop: type q and press Enter here.")
			} else {
				logf("TEST: Keephaven is NOT running. The drive is still held; do not unplug. Type q and press Enter to finish.")
			}
		}
	}
	if running {
		shutdown()
	}
	runExit()
	testCleanup()
	logf("Press Enter to close this window.")
	if lines != nil {
		<-lines
	}
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimSpace(strings.ReplaceAll(s, "\r", "")), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, " | ")
}

func main() {
	slow := false
	disk := -1
	for i := 1; i < len(os.Args); i++ {
		switch os.Args[i] {
		case "--slow":
			slow = true
		case "--run":
			if i+1 < len(os.Args) {
				disk, _ = strconv.Atoi(os.Args[i+1])
				i++
			}
		}
	}
	if disk >= 0 {
		runMode(uint32(disk), slow)
		return
	}
	fromDrive()
}
