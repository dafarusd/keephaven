// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// TEST BUILDS ONLY — everything in this file is compiled out by `-tags release`.
// It is the rig the Windows test PC is driven with from the build laptop:
//   - a status page on port 8899 (the helper's log, Keephaven's console, QEMU's request
//     log) and, from the build laptop only, starts with other settings and a clean stop;
//   - the helper taking a newer copy of itself from the build laptop over plain http;
//   - timings of the drive and of QEMU, and a one-byte patched copy of a downloaded QEMU.
// None of it may ever reach a drive that leaves the house: the page is unauthenticated and
// the http fetch would run whatever answered at that address. release.go holds the stubs
// that take its place, and every seam below is named test*.

//go:build windows && !release

package main

import (
	"bytes"
	"crypto/sha256"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	statusPort   = 8899
	releaseBuild = false
	// The same date as release.go, marked, so a log says which build wrote it.
	version      = "test-2026.10.12a"
)

var (
	// user32 lives in main.go now — the close button needs it in both builds.
	ntdll = syscall.NewLazyDLL("ntdll.dll")

	procGetProcessIoCounters   = kernel32.NewProc("GetProcessIoCounters")
	procSetProcessInformation  = kernel32.NewProc("SetProcessInformation")
	procSetPriorityClass       = kernel32.NewProc("SetPriorityClass")
	procGetSystemPowerStatus   = kernel32.NewProc("GetSystemPowerStatus")
	procGetForegroundWindow    = user32.NewProc("GetForegroundWindow")
	procGetWindowThreadProcId  = user32.NewProc("GetWindowThreadProcessId")
	procNtQueryTimerResolution = ntdll.NewProc("NtQueryTimerResolution")
)

// ---------- the seams main.go calls ----------

func testServe() { serveStatus() }

// testFirewallPorts: the status page, so the build laptop can read it. TEST ONLY.
func testFirewallPorts() []string { return []string{strconv.Itoa(statusPort)} }

// testNewerHelper lets a change to the helper reach the test PC without carrying the drive
// back. TEST ONLY: it runs whatever the build laptop's address answers with.
func testNewerHelper(cur []byte) []byte {
	u := devUpdateURL()
	if u == "" {
		return cur
	}
	c := http.Client{Timeout: 8 * time.Second}
	resp, err := c.Get(u)
	if err != nil {
		logf("TEST BUILD: build laptop not reachable for a newer helper (%v); using this one", err)
		return cur
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != 200 || len(b) < 1000000 || string(b[:2]) != "MZ" {
		return cur
	}
	if sha256.Sum256(b) != sha256.Sum256(cur) {
		logf("TEST BUILD: using a newer helper from %s (%d bytes, sha256 %x)", u, len(b), sha256.Sum256(b))
	}
	return b
}

// testExtraQemuDirs: QEMU builds of our own that a test drive carries beside the shipped one.
func testExtraQemuDirs() []string { return []string{"qemu-kh", "qemu-kh-fixed"} }

// testSettings: the rest of a start's settings, for the log line. Only test starts change them.
func testSettings(t attempt) string {
	return fmt.Sprintf(" cache=%q iothread=%v power=%q prio=%q trace=%q awake=%v nodisplay=%v nomerge=%v pool=%d fixedlen=%v qemu=%q",
		t.cache, t.iothread, t.power, t.prio, t.trace, t.awake, t.nodisplay, t.nomerge, t.pool, t.fixedLen, t.build)
}

func testHostChecks(disk uint32) {
	plan, _ := run("powercfg", "/getactivescheme")
	logf("power: %s | plan: %s | timer %.1f ms", powerSource(), firstLine(plan), timerMs())
	logf("the drive reads at %s", readSpeed(disk))
	logf("asking the drive for its geometry, as QEMU does before every read: %s", geometryQueries(disk))
	logf("reads past Windows' buffering:    scattered 4 KB %s | 16 KB %s | 64 KB %s | 4 KB in runs of 8: %s",
		scatteredReads(disk, 4096, true, 88172645463325252, 1), scatteredReads(disk, 16384, true, 2685821657736338717, 1),
		scatteredReads(disk, 65536, true, 1181783497276652981, 1), scatteredReads(disk, 4096, true, 3202034522624059733, 8))
	logf("reads through Windows' buffering: scattered 4 KB %s | 16 KB %s | 4 KB in runs of 8: %s | 4 KB one long run: %s",
		scatteredReads(disk, 4096, false, 6364136223846793005, 1), scatteredReads(disk, 16384, false, 1442695040888963407, 1),
		scatteredReads(disk, 4096, false, 4768777513237032717, 8), scatteredReads(disk, 4096, false, 7046029254386353131, 1500))
}

func testTail(serial string)      { go tailSerial(serial) }
func testMark(text string)        { serialMark(text) }
func testQuietFor() time.Duration { return serialQuietFor() }

func testWatch(pid int, stop <-chan struct{}) { go watchCPU(pid, stop) }

func testFirstAttempts() []attempt {
	// Start on the copy of the downloaded QEMU that does not re-ask the drive for its size
	// (proven on the test PC, run 9). A first start does gigabytes of drive work; on the
	// unchanged QEMU that is many minutes. If the copy can't be made, the next attempt is
	// the unchanged one.
	return []attempt{{accel: "whpx,kernel-irqchip=off", cpu: "Haswell-noTSX", display: "sdl,window-close=off", smp: defaultSmp(), fixedLen: true}}
}

func testTraceArgs(t attempt, args []string) []string {
	if t.trace == "" {
		return args
	}
	os.Remove(traceFile())
	events := []string{"virtio_blk_handle_read", "virtio_blk_rw_complete", "file_paio_submit"}
	if t.trace == "deep" || t.trace == "locks" {
		events = append(events, "virtio_queue_notify", "virtqueue_pop", "blk_co_preadv", "bdrv_co_preadv_part",
			"thread_pool_submit_aio", "thread_pool_complete_aio", "virtio_blk_req_complete", "virtqueue_fill",
			"virtqueue_flush", "virtio_notify", "qemu_aio_coroutine_enter", "qemu_coroutine_yield",
			"qemu_coroutine_terminate", "aio_co_schedule", "aio_co_schedule_bh_cb")
	}
	if t.trace == "locks" {
		events = append(events, "qemu_mutex_lock", "qemu_mutex_locked", "qemu_mutex_unlock")
	}
	args = append(args, "-msg", "timestamp=on", "-D", traceFile())
	for _, e := range events {
		args = append(args, "-trace", "enable="+e)
	}
	return args
}

// testPickQemu: which QEMU this start runs, and the share folder that goes with it.
func testPickQemu(t attempt, label, runDir, qemu, share string) (string, string, bool) {
	exe := qemu
	if t.build != "" {
		dir := filepath.Join(runDir, map[string]string{"kh": "qemu-kh", "khfix": "qemu-kh-fixed"}[t.build])
		exe, share = filepath.Join(dir, "qemu-system-x86_64.exe"), filepath.Join(dir, "share")
		if _, err := os.Stat(exe); err != nil {
			logf("%s: that QEMU build is not on this drive (%v)", label, err)
			return "", "", false
		}
	}
	if t.fixedLen {
		if t.build != "" {
			logf("%s: hdev=fixed is for the downloaded QEMU only", label)
			return "", "", false
		}
		fixed, err := fixedLenQemu(qemu)
		if err != nil {
			logf("%s: no fixed-length copy of QEMU: %v", label, err)
			return "", "", false
		}
		exe = fixed
	}
	return exe, share, true
}

func testTune(t attempt, pid int) {
	if t.power == "full" {
		logf("  Windows told not to treat QEMU as a background program: %s", errStr(noThrottle(pid)))
	}
	if t.prio == "high" {
		logf("  QEMU set to high priority: %s", errStr(highPriority(pid)))
	}
}

func testWhileRunning(t attempt, gone <-chan struct{}) {
	if t.awake {
		go spin(gone)
		logf("  one processor is kept busy for this start")
	}
	if t.trace == "deep" || t.trace == "locks" {
		// These logs grow by megabytes a second. 20 s reaches well into the read-only check
		// (nothing is mounted for writing yet), and that is all the log is for.
		logf("  this start ends by itself after 20 s (the detailed log would fill the disk)")
		go func() {
			select {
			case <-gone:
			case <-time.After(20 * time.Second):
				qmp("quit")
			}
		}()
	}
}

func testCleanup() { os.Remove(traceFile()) }

// ---------- the rig itself ----------

// The build laptop's address is not baked in. This tree is published, and a source tree
// must not carry anyone's home network; a rig that trusts a hardcoded address also trusts
// whatever later answers at it. Set KEEPHAVEN_DEV_HOST to the build laptop's address to
// switch the self-update fetch and the remote-stop route on. Unset, the fetch is skipped
// and only loopback counts as the build laptop.
func devHost() string { return os.Getenv("KEEPHAVEN_DEV_HOST") }

func devUpdateURL() string {
	if h := devHost(); h != "" {
		return "http://" + h + ":8000/Keephaven.exe"
	}
	return ""
}

var remoteStop = make(chan bool, 1)

func traceFile() string { return filepath.Join(baseDir(), "qemu-trace.log") }

func serveStatus() {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		logMu.Lock()
		defer logMu.Unlock()
		fmt.Fprintf(w, "Keephaven helper %s — log\n\n", version)
		for _, l := range logBuf {
			fmt.Fprintln(w, l)
		}
	})
	// TEST BUILDS ONLY: Keephaven's own console output, each line stamped with this PC's clock,
	// for the build laptop (or this PC) to read. It shows where the start-up time goes.
	// TEST BUILDS ONLY: the end of QEMU's request log from a start made with trace=blk.
	mux.HandleFunc("/trace", func(w http.ResponseWriter, r *http.Request) {
		if !fromBuildLaptop(r) {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		f, err := os.Open(traceFile())
		if err != nil {
			fmt.Fprintln(w, "no trace:", err)
			return
		}
		defer f.Close()
		tail := int64(400 << 10)
		if n, err := strconv.Atoi(r.URL.Query().Get("kb")); err == nil && n >= 1 && n <= 16384 {
			tail = int64(n) << 10
		}
		if st, err := f.Stat(); err == nil && st.Size() > tail {
			f.Seek(st.Size()-tail, 0)
		}
		io.Copy(w, f)
	})
	mux.HandleFunc("/serial", func(w http.ResponseWriter, r *http.Request) {
		if !fromBuildLaptop(r) {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		serialMu.Lock()
		defer serialMu.Unlock()
		for _, l := range serialLines {
			fmt.Fprintln(w, l)
		}
	})
	// TEST BUILDS ONLY: the build laptop may ask for Keephaven to be shut down and started again
	// with other settings, each picked from a fixed list, so start-up can be timed without
	// anyone at the PC. Nothing outside these lists reaches QEMU's command line.
	mux.HandleFunc("/again", func(w http.ResponseWriter, r *http.Request) {
		if !fromBuildLaptop(r) {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		q := r.URL.Query()
		t := attempt{accel: "whpx,kernel-irqchip=off", cpu: "Haswell-noTSX", display: "sdl,window-close=off", smp: defaultSmp()}
		bad := ""
		switch q.Get("irq") {
		case "", "off":
		case "on":
			t.accel = "whpx,kernel-irqchip=on"
		default:
			bad = "irq"
		}
		switch q.Get("accel") {
		case "", "whpx":
		case "tcg": // no hypervisor at all: tells QEMU's own handling apart from the Windows Hypervisor Platform's
			t.accel, t.cpu = "tcg,thread=multi", "max"
			if q.Get("irq") != "" {
				bad = "irq with accel=tcg"
			}
		default:
			bad = "accel"
		}
		switch c := q.Get("cpu"); c {
		case "":
		case "Haswell-noTSX", "qemu64", "max":
			t.cpu = c
		default:
			bad = "cpu"
		}
		if v := q.Get("smp"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 4 {
				t.smp = n
			} else {
				bad = "smp"
			}
		}
		if v := q.Get("quiet"); v != "" {
			if n, err := strconv.Atoi(v); err == nil && n >= 30 && n <= 900 {
				t.quiet = n
			} else {
				bad = "quiet"
			}
		}
		switch c := q.Get("cache"); c {
		case "":
		case "none", "directsync", "writethrough", "writeback":
			t.cache = c
		default:
			bad = "cache"
		}
		switch q.Get("power") {
		case "", "default":
		case "full":
			t.power = "full"
		default:
			bad = "power"
		}
		switch q.Get("prio") {
		case "", "normal":
		case "high":
			t.prio = "high"
		default:
			bad = "prio"
		}
		switch tr := q.Get("trace"); tr {
		case "":
		case "blk", "deep", "locks":
			t.trace = tr
		default:
			bad = "trace"
		}
		switch q.Get("display") {
		case "", "sdl":
		case "none":
			t.nodisplay = true
		default:
			bad = "display"
		}
		switch q.Get("merge") {
		case "", "on":
		case "off":
			t.nomerge = true
		default:
			bad = "merge"
		}
		switch bq := q.Get("qemu"); bq {
		case "", "stock":
		case "kh", "khfix":
			t.build = bq
		default:
			bad = "qemu"
		}
		switch q.Get("pull") {
		case "", "0":
		case "1":
			t.pull = true
		default:
			bad = "pull"
		}
		switch q.Get("hdev") {
		case "", "stock":
		case "fixed":
			t.fixedLen = true
		default:
			bad = "hdev"
		}
		switch q.Get("pool") {
		case "":
		case "1", "2", "4", "8", "16":
			t.pool, _ = strconv.Atoi(q.Get("pool"))
		default:
			bad = "pool"
		}
		switch q.Get("awake") {
		case "", "0":
		case "1":
			t.awake = true
		default:
			bad = "awake"
		}
		switch q.Get("io") {
		case "":
		case "thread":
			t.iothread = true
		default:
			bad = "io"
		}
		if bad != "" {
			http.Error(w, "bad value for "+bad, http.StatusBadRequest)
			return
		}
		select {
		case nextRun <- t:
			fmt.Fprintf(w, "queued: accel=%s cpu=%s smp=%d cache=%q iothread=%v power=%q prio=%q trace=%q awake=%v nodisplay=%v nomerge=%v pool=%d fixedlen=%v qemu=%q pull=%v quiet=%d\n",
				t.accel, t.cpu, t.smp, t.cache, t.iothread, t.power, t.prio, t.trace, t.awake, t.nodisplay, t.nomerge, t.pool, t.fixedLen, t.build, t.pull, t.quiet)
		default:
			fmt.Fprintln(w, "busy: one start is already queued")
		}
	})
	// TEST BUILDS ONLY: the build laptop (or this PC) may ask for a clean stop.
	mux.HandleFunc("/stop", func(w http.ResponseWriter, r *http.Request) {
		if !fromBuildLaptop(r) {
			http.Error(w, "no", http.StatusForbidden)
			return
		}
		select {
		case remoteStop <- true:
			fmt.Fprintln(w, "stopping")
		default:
			fmt.Fprintln(w, "already stopping")
		}
	})
	go func() {
		if err := http.ListenAndServe(fmt.Sprintf(":%d", statusPort), mux); err != nil {
			logf("status page not available on port %d: %v", statusPort, err)
		}
	}()
}

func fromBuildLaptop(r *http.Request) bool {
	host, _, _ := net.SplitHostPort(r.RemoteAddr)
	if host == "127.0.0.1" || host == "::1" {
		return true
	}
	h := devHost()
	return h != "" && host == h
}

// ---------- Keephaven's console, stamped ----------

var (
	serialMu    sync.Mutex
	serialLines []string
	serialOff   int64
	serialCarry string
	serialGrew  = time.Now()
	ansiSeq     = regexp.MustCompile(`\x1b\[[0-9;?]*[A-Za-z]`)
)

func serialMark(text string) {
	serialMu.Lock()
	serialLines = append(serialLines, time.Now().Format("15:04:05")+" ---- "+text+" ----")
	serialOff, serialCarry, serialGrew = 0, "", time.Now()
	serialMu.Unlock()
}

func serialQuietFor() time.Duration {
	serialMu.Lock()
	defer serialMu.Unlock()
	return time.Since(serialGrew)
}

// tailSerial follows the file QEMU writes Keephaven's console to.

func tailSerial(path string) {
	for {
		time.Sleep(500 * time.Millisecond)
		f, err := os.Open(path)
		if err != nil {
			continue
		}
		serialMu.Lock()
		if st, err := f.Stat(); err == nil && st.Size() < serialOff {
			serialOff, serialCarry = 0, ""
		}
		f.Seek(serialOff, 0)
		if b, _ := io.ReadAll(f); len(b) > 0 {
			serialOff += int64(len(b))
			serialGrew = time.Now()
			parts := strings.Split(serialCarry+strings.ReplaceAll(string(b), "\r", ""), "\n")
			serialCarry = parts[len(parts)-1]
			stamp := time.Now().Format("15:04:05")
			for _, l := range parts[:len(parts)-1] {
				if l = strings.TrimRight(ansiSeq.ReplaceAllString(l, ""), " "); l != "" {
					serialLines = append(serialLines, stamp+" "+l)
				}
			}
		}
		serialMu.Unlock()
		f.Close()
	}
}

// readSpeed reads from the raw drive for a few seconds, past Windows' cache. A USB 2 port or
// cable gives about 40 MB/s; USB 3 gives several hundred.

func readSpeed(disk uint32) string {
	h, err := syscall.CreateFile(utf16ptr(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk)), genericRead,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING,
		0x20000000|0x08000000, 0) // FILE_FLAG_NO_BUFFERING | FILE_FLAG_SEQUENTIAL_SCAN
	if err != nil {
		return "not measured (" + err.Error() + ")"
	}
	defer syscall.CloseHandle(h)
	const chunk = 1 << 20
	raw := make([]byte, chunk+4096)
	skip := (4096 - int(uintptr(unsafe.Pointer(&raw[0]))%4096)) % 4096
	buf := raw[skip : skip+chunk]
	if _, err := syscall.Seek(h, 3<<30, 0); err != nil { // 3 GiB in: inside the system partition
		return "not measured (" + err.Error() + ")"
	}
	t0 := time.Now()
	total := 0
	for total < 256<<20 && time.Since(t0) < 4*time.Second {
		var n uint32
		if err := syscall.ReadFile(h, buf, &n, nil); err != nil {
			return fmt.Sprintf("not measured (%v after %d MB)", err, total>>20)
		}
		if n == 0 {
			break
		}
		total += int(n)
	}
	secs := time.Since(t0).Seconds()
	return fmt.Sprintf("%.0f MB/s (%d MB in %.1f s)", float64(total)/1e6/secs, total>>20, secs)
}

// scatteredReads reads blocks of one size at scattered places in the system partition and
// returns how long each took. A file system check is tens of thousands of small reads, so
// this is the number that matters for it. With direct set the reads go past Windows' own
// buffering (FILE_FLAG_NO_BUFFERING); without it they are what QEMU's default drive mode does.
// run is how many blocks are read one after another at each place: a check reads short runs
// (an inode table), and Windows' read-ahead, if it applies here, reacts to that pattern.

func scatteredReads(disk uint32, size int, direct bool, seed uint64, run int) string {
	flags := uint32(0)
	if direct {
		flags = 0x20000000
	}
	h, err := syscall.CreateFile(utf16ptr(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk)), genericRead,
		syscall.FILE_SHARE_READ|syscall.FILE_SHARE_WRITE, nil, syscall.OPEN_EXISTING, flags, 0)
	if err != nil {
		return "not measured (" + err.Error() + ")"
	}
	defer syscall.CloseHandle(h)
	raw := make([]byte, size+4096)
	skip := (4096 - int(uintptr(unsafe.Pointer(&raw[0]))%4096)) % 4096
	buf := raw[skip : skip+size]
	const base, span = int64(2) << 30, int64(12) << 30 // 2 GiB to 14 GiB in: all inside the system partition
	x := seed
	t0 := time.Now()
	n := 0
	for n < 1500 && time.Since(t0) < 3*time.Second {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		off := base + int64(x%uint64(span/65536))*65536
		if _, err := syscall.Seek(h, off, 0); err != nil {
			return fmt.Sprintf("not measured (%v)", err)
		}
		for i := 0; i < run; i++ {
			var got uint32
			if err := syscall.ReadFile(h, buf, &got, nil); err != nil {
				return fmt.Sprintf("not measured (%v after %d reads)", err, n)
			}
			n++
		}
	}
	secs := time.Since(t0).Seconds()
	return fmt.Sprintf("%.2f ms each (%d reads in %.1f s)", secs*1000/float64(n), n, secs)
}

type procUse struct {
	cpu                              float64 // seconds of processor time
	reads, readBytes, writes, wBytes uint64
}

// useOf returns what a process has used so far: processor time, and its reads and writes.

func useOf(pid int) (procUse, bool) {
	var u procUse
	h, err := syscall.OpenProcess(0x1000, false, uint32(pid)) // PROCESS_QUERY_LIMITED_INFORMATION
	if err != nil {
		return u, false
	}
	defer syscall.CloseHandle(h)
	var c, e, k, us syscall.Filetime
	if err := syscall.GetProcessTimes(h, &c, &e, &k, &us); err != nil {
		return u, false
	}
	ticks := func(f syscall.Filetime) int64 { return int64(f.HighDateTime)<<32 | int64(f.LowDateTime) } // 100 ns each
	u.cpu = float64(ticks(k)+ticks(us)) / 1e7
	var io [6]uint64 // IO_COUNTERS: read, write, other operations; read, write, other bytes
	if r, _, _ := procGetProcessIoCounters.Call(uintptr(h), uintptr(unsafe.Pointer(&io[0]))); r != 0 {
		u.reads, u.writes, u.readBytes, u.wBytes = io[0], io[1], io[3], io[4]
	}
	return u, true
}

// TEST BUILDS ONLY. QEMU's Windows host-device driver marks every raw drive as one whose size
// may change (block/file-win32.c, hdev_refresh_limits: bs->bl.has_variable_length = true), so
// its block layer asks the drive for its geometry three times for every read: once in
// virtio-blk's range check and once per layer in bdrv_aligned_preadv. On a USB drive each of
// those is a round trip. The proper fix is a QEMU built from patched source. To measure what
// that will give before such a build exists, this makes a copy of the exact QEMU build that is
// on the drive with that one flag written as false: one byte, at a place checked first.
// Nothing made here is for release.

func fixedLenQemu(orig string) (string, error) {
	const at = 0x508a60
	// mov dword [rcx+0x460], 0x200 ; mov byte [rcx+0x4b4], 1 ; xor ecx, ecx ; ret
	want := []byte{0xc7, 0x81, 0x60, 0x04, 0, 0, 0, 0x02, 0, 0, 0xc6, 0x81, 0xb4, 0x04, 0, 0, 0x01, 0x31, 0xc9, 0xc3}
	b, err := os.ReadFile(orig)
	if err != nil {
		return "", err
	}
	if fmt.Sprintf("%x", sha256.Sum256(b)) != "47d57a6072e0bb3bd98f87926eb129eb1736dfe818c67b3b81ef7ce4edd0b3cd" {
		return "", fmt.Errorf("%s is not the QEMU build this was worked out for", orig)
	}
	if len(b) < at+len(want) || !bytes.Equal(b[at:at+len(want)], want) {
		return "", fmt.Errorf("the expected instructions are not at 0x%x", at)
	}
	b[at+16] = 0
	out := filepath.Join(filepath.Dir(orig), "qemu-system-x86_64-fixedlen.exe")
	if err := os.WriteFile(out, b, 0755); err != nil {
		return "", err
	}
	return out, nil
}

// geometryQueries times the question QEMU asks the drive before every read: "what is your
// geometry?" (IOCTL_DISK_GET_DRIVE_GEOMETRY_EX), alone and in QEMU's pattern of three
// questions and then one 4 KB read.

func geometryQueries(disk uint32) string {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead)
	if err != nil {
		return "not measured (" + err.Error() + ")"
	}
	defer syscall.CloseHandle(h)
	out := make([]byte, 256)
	ask := func() error {
		var got uint32
		return syscall.DeviceIoControl(h, 0x000700A0, nil, 0, &out[0], uint32(len(out)), &got, nil)
	}
	t0 := time.Now()
	n := 0
	for n < 1000 && time.Since(t0) < 4*time.Second {
		if err := ask(); err != nil {
			return fmt.Sprintf("not measured (%v after %d)", err, n)
		}
		n++
	}
	alone := time.Since(t0).Seconds() * 1000 / float64(n)
	raw := make([]byte, 8192)
	skip := (4096 - int(uintptr(unsafe.Pointer(&raw[0]))%4096)) % 4096
	buf := raw[skip : skip+4096]
	x := uint64(1442695040888963407)
	t1 := time.Now()
	m := 0
	for m < 500 && time.Since(t1) < 4*time.Second {
		for i := 0; i < 3; i++ {
			if err := ask(); err != nil {
				return fmt.Sprintf("%.2f ms each alone (%d); the mixed run failed: %v", alone, n, err)
			}
		}
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		if _, err := syscall.Seek(h, (int64(2)<<30)+int64(x%uint64((int64(12)<<30)/65536))*65536, 0); err != nil {
			return fmt.Sprintf("%.2f ms each alone (%d); the mixed run failed: %v", alone, n, err)
		}
		var got uint32
		if err := syscall.ReadFile(h, buf, &got, nil); err != nil {
			return fmt.Sprintf("%.2f ms each alone (%d); the mixed run failed: %v", alone, n, err)
		}
		m++
	}
	mixed := time.Since(t1).Seconds() * 1000 / float64(m)
	return fmt.Sprintf("%.2f ms each alone (%d asked) | three questions then one scattered 4 KB read: %.2f ms a round (%d rounds)", alone, n, mixed, m)
}

// noThrottle tells Windows not to treat a process as a background one: no slowed execution and
// no ignoring of its request for a fine timer (Windows 11 does both to windows it can't see).

func noThrottle(pid int) error {
	h, err := syscall.OpenProcess(0x0200, false, uint32(pid)) // PROCESS_SET_INFORMATION
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(h)
	st := struct{ Version, ControlMask, StateMask uint32 }{1, 0x1 | 0x4, 0}                                                // EXECUTION_SPEED | IGNORE_TIMER_RESOLUTION, both off
	if r, _, e := procSetProcessInformation.Call(uintptr(h), 4, uintptr(unsafe.Pointer(&st)), unsafe.Sizeof(st)); r == 0 { // ProcessPowerThrottling
		return e
	}
	return nil
}

func highPriority(pid int) error {
	h, err := syscall.OpenProcess(0x0200, false, uint32(pid))
	if err != nil {
		return err
	}
	defer syscall.CloseHandle(h)
	if r, _, e := procSetPriorityClass.Call(uintptr(h), 0x80); r == 0 { // HIGH_PRIORITY_CLASS
		return e
	}
	return nil
}

// inFront says whether the window the user is working in belongs to this process.

func inFront(pid int) bool {
	hwnd, _, _ := procGetForegroundWindow.Call()
	if hwnd == 0 {
		return false
	}
	var owner uint32
	procGetWindowThreadProcId.Call(hwnd, uintptr(unsafe.Pointer(&owner)))
	return int(owner) == pid
}

// timerMs is the timer step Windows is running at right now (15.6 ms when nothing asks for finer).

func timerMs() float64 {
	var coarsest, finest, cur uint32
	procNtQueryTimerResolution.Call(uintptr(unsafe.Pointer(&coarsest)), uintptr(unsafe.Pointer(&finest)), uintptr(unsafe.Pointer(&cur)))
	return float64(cur) / 10000
}

func powerSource() string {
	var st struct {
		ACLine, BatteryFlag, BatteryPercent, SystemStatusFlag byte
		BatteryLifeTime, BatteryFullLifeTime                  uint32
	}
	if r, _, _ := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&st))); r == 0 {
		return "unknown"
	}
	src := map[byte]string{0: "on battery", 1: "plugged in"}[st.ACLine]
	if src == "" {
		src = "unknown source"
	}
	return fmt.Sprintf("%s, battery %d %%, battery saver %v", src, st.BatteryPercent, st.SystemStatusFlag == 1)
}

// spin keeps one processor busy until gone is closed. TEST BUILDS ONLY: with something always
// running, the chip cannot drop into its deepest sleep between two drive requests.

func spin(gone <-chan struct{}) {
	runtime.LockOSThread()
	x := uint64(1)
	for {
		select {
		case <-gone:
			return
		default:
		}
		for i := 0; i < 200000; i++ {
			x = x*6364136223846793005 + 1442695040888963407
		}
	}
}

// watchCPU logs, while Keephaven starts, how busy QEMU is and how much it reads from the drive:
// a busy processor means the PC is the limit, an idle one means it is waiting for the drive.
// TEST BUILDS ONLY.

func watchCPU(pid int, stop <-chan struct{}) {
	last, ok := useOf(pid)
	if !ok {
		return
	}
	for {
		select {
		case <-stop:
			return
		case <-time.After(15 * time.Second):
		}
		now, ok := useOf(pid)
		if !ok {
			return
		}
		r, rb := now.reads-last.reads, now.readBytes-last.readBytes
		each := 0.0
		if r > 0 {
			each = float64(rb) / float64(r) / 1024
		}
		logf("  load, last 15 s: processor %.1f s (one busy core = 15.0) | %d reads, %.0f MB, %.0f KB each | %d writes, %.1f MB | QEMU window in front: %v | timer %.1f ms",
			now.cpu-last.cpu, r, float64(rb)/1e6, each, now.writes-last.writes, float64(now.wBytes-last.wBytes)/1e6, inFront(pid), timerMs())
		last = now
	}
}

// waitForKeephaven polls the dashboard for up to 15 minutes. With quietLimit set it also gives
// up when Keephaven's console has printed nothing for that long: a frozen guest prints nothing.

var nextRun = make(chan attempt, 1)
