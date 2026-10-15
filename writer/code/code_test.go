// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only

// Built the way the image builds it: sgdisk lays the four partitions, mkfs.vfat makes the
// KEEPHAVEN filesystem, mcopy puts the code file in it. The judge for "did the in-place write
// corrupt the filesystem" is mtype - a real FAT reader, not this package reading its own bytes
// back. That is the whole risk of overwriting a file's contents under a filesystem's nose.
package code

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"keephaven.co/writer/gpt"
)

const (
	espType      = "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
	linuxType    = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
	recoveryType = "0FC63DAF-8483-4772-8E79-3D69D8477DE4"
	dataType     = "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
)

// the field exactly as modules/disk-layout.nix writes it
var placeholder = Marker + strings.Repeat(".", Field)

func need(t *testing.T, tools ...string) map[string]string {
	t.Helper()
	got := map[string]string{}
	for _, n := range tools {
		p, err := exec.LookPath(n)
		if err != nil {
			t.Skipf("no %s on PATH; this test needs it to build and to judge a real FAT partition", n)
		}
		got[n] = p
	}
	return got
}

func run(t *testing.T, name string, args ...string) string {
	t.Helper()
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("%s %s: %v\n%s", filepath.Base(name), strings.Join(args, " "), err, out)
	}
	return string(out)
}

// drive returns a sparse image with the real four partitions and a real FAT32 KEEPHAVEN holding
// the code file, plus that partition's byte range read out of the GPT.
func drive(t *testing.T, body string) (string, int64, int64) {
	t.Helper()
	tools := need(t, "sgdisk", "mkfs.vfat", "mcopy")
	dir := t.TempDir()
	path := filepath.Join(dir, "drive.img")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(100 << 20); err != nil {
		t.Fatal(err)
	}
	f.Close()
	run(t, tools["sgdisk"],
		"-n", "1:2048:+8M", "-t", "1:"+espType, "-c", "1:FIRMWARE",
		"-n", "2:0:+20M", "-t", "2:"+linuxType, "-c", "2:NIXOS_SD",
		"-n", "3:0:+20M", "-t", "3:"+recoveryType, "-c", "3:cloudunit-recovery",
		"-n", "4:0:+40M", "-t", "4:"+dataType, "-c", "4:KEEPHAVEN",
		path)

	img, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer img.Close()
	start, size, err := gpt.FindPartition(img, 512, "KEEPHAVEN")
	if err != nil {
		t.Fatalf("could not find KEEPHAVEN in the table: %v", err)
	}

	// build the filesystem separately and dd it in, exactly as disk-layout.nix does
	fat := filepath.Join(dir, "launcher.fat")
	if err := os.Truncate(fat, 0); err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	ff, err := os.Create(fat)
	if err != nil {
		t.Fatal(err)
	}
	if err := ff.Truncate(size); err != nil {
		t.Fatal(err)
	}
	ff.Close()
	run(t, tools["mkfs.vfat"], "-F", "32", "-n", "KEEPHAVEN", fat)
	src := filepath.Join(dir, "Keephaven-code.txt")
	if err := os.WriteFile(src, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	run(t, tools["mcopy"], "-i", fat, src, "::")
	blob, err := os.ReadFile(fat)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := img.WriteAt(blob, start); err != nil {
		t.Fatal(err)
	}
	return path, start, size
}

// mtype reads the file back through a real FAT implementation.
func mtype(t *testing.T, path string, start int64) string {
	t.Helper()
	tools := need(t, "mtype")
	cmd := exec.Command(tools["mtype"], "-i", path+"@@"+itoa(start), "::Keephaven-code.txt")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("mtype could not read the file back - the in-place write broke the filesystem: %v\n%s", err, out)
	}
	return string(out)
}

func itoa(n int64) string {
	return strings.TrimSpace(strings.Join(strings.Fields(strings.Replace(fmtInt(n), "\n", "", -1)), ""))
}

func fmtInt(n int64) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}

func TestStampLandsAndTheFilesystemStillReads(t *testing.T) {
	const want = "KH-7F3A91CC20B4"
	path, start, size := drive(t, "Keephaven - update code\n\n"+placeholder+"\n\nkeep this file.\n")
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	if got, err := Read(f, start, size); err != nil || got != "" {
		t.Fatalf("a fresh image should carry no code, got %q err %v", got, err)
	}
	at, err := Stamp(f, start, size, want)
	if err != nil {
		t.Fatalf("Stamp: %v", err)
	}
	if at < start || at >= start+size {
		t.Errorf("Stamp wrote at %d, outside KEEPHAVEN (%d..%d)", at, start, start+size)
	}
	got, err := Read(f, start, size)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("Read after Stamp = %q, want %q", got, want)
	}
	f.Sync()

	// the real test: a FAT reader must still see a well-formed file carrying the code
	out := mtype(t, path, start)
	if !strings.Contains(out, Marker+want) {
		t.Errorf("mtype does not see the stamped code; it read:\n%s", out)
	}
	if !strings.Contains(out, "keep this file.") {
		t.Errorf("the rest of the file did not survive the stamp; mtype read:\n%s", out)
	}
	if strings.Count(out, Marker) != 1 {
		t.Errorf("expected exactly one marker in the file, mtype read:\n%s", out)
	}
}

func TestStampKeepsTheFieldLength(t *testing.T) {
	path, start, size := drive(t, "x\n"+placeholder+"\nytail\n")
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	before := make([]byte, size)
	if _, err := f.ReadAt(before, start); err != nil {
		t.Fatal(err)
	}
	if _, err := Stamp(f, start, size, "KH-SHORT1"); err != nil {
		t.Fatal(err)
	}
	after := make([]byte, size)
	if _, err := f.ReadAt(after, start); err != nil {
		t.Fatal(err)
	}
	// Exactly Field bytes may differ, and they must all be inside the field.
	diff := 0
	first, last := -1, -1
	for i := range before {
		if before[i] != after[i] {
			diff++
			if first < 0 {
				first = i
			}
			last = i
		}
	}
	if diff == 0 {
		t.Fatal("nothing changed")
	}
	if last-first+1 > Field {
		t.Errorf("the stamp touched bytes %d..%d, a span of %d, wider than the %d-byte field",
			first, last, last-first+1, Field)
	}
	if !bytes.Contains(after, []byte("ytail")) {
		t.Error("the text after the field was overwritten")
	}
}

func TestRefusesAnythingThatIsNotACode(t *testing.T) {
	path, start, size := drive(t, placeholder+"\n")
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	for _, bad := range []string{
		"", "short", "KH-1/../photos", "https://evil.example/x", "KH-1.evil.com",
		"KH with spaces", "-leadingdash", strings.Repeat("A", Field+1), "KH\nNEWLINE1",
	} {
		if _, err := Stamp(f, start, size, bad); err == nil {
			t.Errorf("Stamp accepted %q", bad)
		}
	}
	// and nothing was written
	if got, _ := Read(f, start, size); got != "" {
		t.Errorf("a refused stamp still changed the field to %q", got)
	}
}

func TestRefusesAnImageWithNoField(t *testing.T) {
	path, start, size := drive(t, "Keephaven\nno field here at all\n")
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if _, err := Stamp(f, start, size, "KH-7F3A91CC20B4"); err == nil {
		t.Error("Stamp invented a field that the image does not carry")
	}
	_ = path
}

// strictDevice refuses any read or write that Windows would refuse on a raw physical drive:
// offset and length must both be multiples of the sector size. It exists because the first
// version of this package passed every test on Linux against a plain file and then failed on the
// HP with "The parameter is incorrect" - a plain *os.File accepts anything, so the tests could
// not see the constraint the real target imposes. Running the same stamp through this is what
// makes that bug impossible to ship twice.
type strictDevice struct {
	f      *os.File
	sector int64
	reads  int
	writes int
}

func (d *strictDevice) check(what string, p []byte, off int64) error {
	if off%d.sector != 0 {
		return fmt.Errorf("%s at offset %d is %d bytes off a %d-byte sector boundary: the parameter is incorrect",
			what, off, off%d.sector, d.sector)
	}
	if int64(len(p))%d.sector != 0 {
		return fmt.Errorf("%s of %d bytes is not a multiple of the %d-byte sector: the parameter is incorrect",
			what, len(p), d.sector)
	}
	return nil
}

func (d *strictDevice) ReadAt(p []byte, off int64) (int, error) {
	if err := d.check("a read", p, off); err != nil {
		return 0, err
	}
	d.reads++
	return d.f.ReadAt(p, off)
}

func (d *strictDevice) WriteAt(p []byte, off int64) (int, error) {
	if err := d.check("a write", p, off); err != nil {
		return 0, err
	}
	d.writes++
	return d.f.WriteAt(p, off)
}

// sectorWrapper is the same aligned read-modify-write the writer uses on Windows
// (winextra.go, sectorDevice). Kept here so the behaviour can be tested on Linux.
type sectorWrapper struct {
	d      Device
	sector int64
}

func (w sectorWrapper) span(off int64, n int) (int64, int64) {
	s := w.sector
	start := off - off%s
	end := off + int64(n)
	if r := end % s; r != 0 {
		end += s - r
	}
	return start, end
}

func (w sectorWrapper) ReadAt(p []byte, off int64) (int, error) {
	start, end := w.span(off, len(p))
	buf := make([]byte, end-start)
	if _, err := w.d.ReadAt(buf, start); err != nil {
		return 0, err
	}
	return copy(p, buf[off-start:]), nil
}

func (w sectorWrapper) WriteAt(p []byte, off int64) (int, error) {
	start, end := w.span(off, len(p))
	buf := make([]byte, end-start)
	if _, err := w.d.ReadAt(buf, start); err != nil {
		return 0, err
	}
	copy(buf[off-start:], p)
	if _, err := w.d.WriteAt(buf, start); err != nil {
		return 0, err
	}
	return len(p), nil
}

func TestStampWorksThroughAWindowsStyleRawDevice(t *testing.T) {
	const want = "KH-0000000000000001"
	// A 40 MiB partition so the marker is well past the first scan window on some layouts.
	path, start, size := drive(t, "Keephaven - update code\n\n"+placeholder+"\n\ntail marker here.\n")
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	strict := &strictDevice{f: f, sector: 512}
	dev := sectorWrapper{d: strict, sector: 512}

	if _, err := Stamp(dev, start, size, want); err != nil {
		t.Fatalf("Stamp through a sector-strict device: %v", err)
	}
	if strict.reads == 0 || strict.writes == 0 {
		t.Fatalf("the strict device saw %d reads and %d writes; it was not actually used", strict.reads, strict.writes)
	}
	got, err := Read(dev, start, size)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Errorf("Read = %q, want %q", got, want)
	}
	f.Sync()
	out := mtype(t, path, start)
	if !strings.Contains(out, Marker+want) {
		t.Errorf("mtype does not see the code after an aligned stamp; it read:\n%s", out)
	}
	if !strings.Contains(out, "tail marker here.") {
		t.Errorf("the aligned write clobbered the bytes after the field; mtype read:\n%s", out)
	}
}

// The aligning wrapper is NOT optional, and this is the test that says so. The 64-byte field sits
// wherever the file sits inside the filesystem, so the write to it can never be sector-aligned by
// itself - no amount of fixing the scan stride changes that. A caller handing Stamp a bare raw
// drive handle must fail, loudly, rather than appear to work: that is the bug the HP found on
// 2026-10-14 ("read drive: The parameter is incorrect"), and the writer's one call site wraps the
// handle in sectorDevice because of it.
func TestABareRawDeviceIsRefusedBecauseTheFieldIsNeverAligned(t *testing.T) {
	path, start, size := drive(t, strings.Repeat("x", 600000)+"\n"+placeholder+"\n")
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	strict := &strictDevice{f: f, sector: 512}
	_, err = Stamp(strict, start, size, "KH-0000000000000001")
	if err == nil {
		t.Fatal("Stamp claimed to work on a device that refuses unaligned access; on Windows that " +
			"is the error the HP returned and the code would silently not be on the drive")
	}
	if !strings.Contains(err.Error(), "parameter is incorrect") {
		t.Errorf("failed for the wrong reason: %v", err)
	}
	// and the scan itself must be aligned - the failure has to come from the FIELD, not the search
	if strict.reads == 0 {
		t.Error("the scan did not manage a single aligned read, so the stride is still wrong")
	}
}
