// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// The CRC arithmetic in gpt.go is the part that cannot be checked by reading it, and the only
// honest way to exercise it without a 1 TB drive is against a real table. These tests lay the
// image's own four partitions on a 100 MiB sparse file with sgdisk, re-identify it, and then
// hand the result back to sgdisk to say whether it is valid - so the check is made by the tool
// the Linux flash scripts have always used, not by this package agreeing with itself.
package gpt

import (
	"bytes"
	"encoding/binary"
	"hash/crc32"
	"math/rand"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// the image's own type GUIDs and labels (modules/disk-layout.nix)
const (
	espType      = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
	linuxType    = "0fc63daf-8483-4772-8e79-3d69d8477de4"
	recoveryType = "15d78efc-03a8-4ec9-a5ac-784f8283ebc4"
	dataType     = "ebd0a0a2-b9e5-4433-87c0-68b6b72699c7"
)

func sgdisk(t *testing.T) string {
	t.Helper()
	p, err := exec.LookPath("sgdisk")
	if err != nil {
		t.Skip("no sgdisk on PATH; this test needs it to make and to judge the table")
	}
	return p
}

// keephavenTable builds a sparse file with the same four partitions, types and labels the real
// image carries, which is what the writer will meet on a customer's drive.
func keephavenTable(t *testing.T) string {
	t.Helper()
	sg := sgdisk(t)
	path := filepath.Join(t.TempDir(), "drive.img")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(100 << 20); err != nil {
		t.Fatal(err)
	}
	f.Close()
	args := []string{
		"-n", "1:2048:+8M", "-t", "1:" + espType, "-c", "1:FIRMWARE",
		"-n", "2:0:+20M", "-t", "2:" + linuxType, "-c", "2:NIXOS_SD",
		"-n", "3:0:+20M", "-t", "3:" + recoveryType, "-c", "3:cloudunit-recovery",
		"-n", "4:0:+8M", "-t", "4:" + dataType, "-c", "4:KEEPHAVEN",
		path,
	}
	if out, err := exec.Command(sg, args...).CombinedOutput(); err != nil {
		t.Fatalf("sgdisk could not lay the table: %v\n%s", err, out)
	}
	return path
}

func open(t *testing.T, path string) *os.File {
	t.Helper()
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

func TestReidentifyChangesEveryGUIDAndStaysValid(t *testing.T) {
	path := keephavenTable(t)
	sg := sgdisk(t)

	before, err := Check(open(t, path), 512)
	if err != nil {
		t.Fatalf("the table sgdisk just made does not pass Check: %v", err)
	}
	if len(before.Partitions) != 4 {
		t.Fatalf("expected the image's four partitions, found %d", len(before.Partitions))
	}

	rep, err := Reidentify(open(t, path), 512, rand.New(rand.NewSource(1)))
	if err != nil {
		t.Fatalf("Reidentify: %v", err)
	}
	if rep.DiskBefore == rep.DiskAfter {
		t.Error("the disk GUID did not change")
	}
	if len(rep.Partitions) != 4 {
		t.Fatalf("re-identified %d partitions, expected 4", len(rep.Partitions))
	}
	seen := map[string]bool{rep.DiskAfter: true}
	for _, c := range rep.Partitions {
		if c.Before == c.After {
			t.Errorf("entry %d (%s) kept its GUID %s", c.Entry, c.Name, c.Before)
		}
		if seen[c.After] {
			t.Errorf("entry %d (%s) was given a GUID that is already in use: %s", c.Entry, c.Name, c.After)
		}
		seen[c.After] = true
	}

	// the names must survive: everything in the image mounts by label or partlabel
	want := []string{"FIRMWARE", "NIXOS_SD", "cloudunit-recovery", "KEEPHAVEN"}
	for i, c := range rep.Partitions {
		if c.Name != want[i] {
			t.Errorf("entry %d is named %q, expected %q", c.Entry, c.Name, want[i])
		}
	}

	// and the judge is sgdisk, not us
	out, err := exec.Command(sg, "-v", path).CombinedOutput()
	if err != nil {
		t.Fatalf("sgdisk -v failed: %v\n%s", err, out)
	}
	if !strings.Contains(string(out), "No problems found") {
		t.Errorf("sgdisk -v is not happy with the result:\n%s", out)
	}

	// Check must agree, and both tables must name the same disk
	after, err := Check(open(t, path), 512)
	if err != nil {
		t.Fatalf("Check after Reidentify: %v", err)
	}
	if after.DiskBefore != rep.DiskAfter {
		t.Errorf("the disk GUID on disk is %s, Reidentify said %s", after.DiskBefore, rep.DiskAfter)
	}
}

func TestBothTablesGetTheSameIDs(t *testing.T) {
	// Compare the two arrays directly rather than asking sgdisk, because sgdisk silently
	// recovers a wiped primary header from the backup and still prints "No problems found" -
	// which made the first version of this test pass on its own confusion.
	path := keephavenTable(t)
	if _, err := Reidentify(open(t, path), 512, rand.New(rand.NewSource(2))); err != nil {
		t.Fatal(err)
	}
	f := open(t, path)
	primary, err := readHeader(f, 512, 1)
	if err != nil {
		t.Fatalf("primary header after Reidentify: %v", err)
	}
	altLBA := int64(binary.LittleEndian.Uint64(primary.raw[altLBAOffset:]))
	backup, err := readHeader(f, 512, altLBA)
	if err != nil {
		t.Fatalf("backup header after Reidentify: %v", err)
	}
	if !bytes.Equal(primary.raw[diskGUIDOffset:diskGUIDOffset+16], backup.raw[diskGUIDOffset:diskGUIDOffset+16]) {
		t.Errorf("the two headers name different disks: %s and %s",
			guidString(primary.raw[diskGUIDOffset:diskGUIDOffset+16]),
			guidString(backup.raw[diskGUIDOffset:diskGUIDOffset+16]))
	}
	// the backup array is where the BACKUP header says, not at a fixed distance from the end
	if backup.entryLBA == primary.entryLBA {
		t.Errorf("both headers point at the same entry array at LBA %d", backup.entryLBA)
	}
	pe := make([]byte, primary.entriesBytes())
	if _, err := f.ReadAt(pe, int64(primary.entryLBA)*512); err != nil {
		t.Fatal(err)
	}
	be := make([]byte, backup.entriesBytes())
	if _, err := f.ReadAt(be, int64(backup.entryLBA)*512); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(pe, be) {
		es := int(primary.entrySize)
		for i := 0; i < int(primary.numEntries); i++ {
			a, b := pe[i*es:i*es+es], be[i*es:i*es+es]
			if !bytes.Equal(a, b) {
				t.Errorf("entry %d differs between the tables: %s vs %s", i+1,
					guidString(a[entryUniqueOffset:entryUniqueOffset+16]),
					guidString(b[entryUniqueOffset:entryUniqueOffset+16]))
			}
		}
	}
	// and the backup alone must still describe a Keephaven: rebuild from it and look
	zero := make([]byte, 512)
	if _, err := f.WriteAt(zero, 512); err != nil {
		t.Fatal(err)
	}
	f.Close()
	sg := sgdisk(t)
	if out, err := exec.Command(sg, "-e", path).CombinedOutput(); err != nil {
		t.Fatalf("sgdisk could not rebuild the primary from the backup: %v\n%s", err, out)
	}
	rep, err := Check(open(t, path), 512)
	if err != nil {
		t.Fatalf("after rebuilding from the backup, Check: %v", err)
	}
	if len(rep.Partitions) != 4 || rep.Partitions[3].Name != "KEEPHAVEN" {
		t.Errorf("the backup table did not describe the same drive: %+v", rep.Partitions)
	}
}

func TestRefusesATableItShouldNotTouch(t *testing.T) {
	// no GPT at all
	path := filepath.Join(t.TempDir(), "empty.img")
	if err := os.WriteFile(path, make([]byte, 2<<20), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Reidentify(open(t, path), 512, nil); err == nil {
		t.Error("re-identified a file with no GPT")
	}

	// a good table with a corrupt entries CRC must be refused, not written to
	path2 := keephavenTable(t)
	f := open(t, path2)
	var b [1]byte
	if _, err := f.ReadAt(b[:], 2*512+1); err != nil {
		t.Fatal(err)
	}
	b[0] ^= 0xFF
	if _, err := f.WriteAt(b[:], 2*512+1); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if _, err := Reidentify(open(t, path2), 512, nil); err == nil {
		t.Error("re-identified a table whose entries do not match their CRC")
	}
}

// resign makes a tampered header self-consistent again: zero the CRC field, compute the CRC over
// HeaderSize bytes, store it. Without this the tests below would be caught by the CRC check and
// would prove nothing about the check they are actually aiming at.
func resign(raw []byte) {
	size := binary.LittleEndian.Uint32(raw[headerSizeOffset:])
	binary.LittleEndian.PutUint32(raw[headerCRCOffset:], 0)
	binary.LittleEndian.PutUint32(raw[headerCRCOffset:], crc32.ChecksumIEEE(raw[:size]))
}

// A header that was copied somewhere else rather than written there keeps a perfectly valid CRC
// - the bytes are intact, only MyLBA disagrees with where the bytes are. Nothing else in this
// package would notice.
func TestRefusesAHeaderThatIsNotWhereItSaysItIs(t *testing.T) {
	path := keephavenTable(t)
	f := open(t, path)
	raw := make([]byte, 512)
	if _, err := f.ReadAt(raw, 512); err != nil {
		t.Fatal(err)
	}
	binary.LittleEndian.PutUint64(raw[myLBAOffset:], 9999)
	resign(raw)
	if _, err := f.WriteAt(raw, 512); err != nil {
		t.Fatal(err)
	}
	f.Close()

	_, err := Check(open(t, path), 512)
	if err == nil {
		t.Fatal("accepted a header that says it lives at LBA 9999")
	}
	if !strings.Contains(err.Error(), "says it lives at LBA 9999") {
		t.Errorf("refused for the wrong reason: %v", err)
	}
	if _, err := Reidentify(open(t, path), 512, nil); err == nil {
		t.Error("re-identified a table whose primary header is in the wrong place")
	}
}

// Two entry arrays can each match their own CRC and still describe different drives, which is
// what half a rewrite leaves behind. Check has to compare the bytes, not just the checksums.
func TestRefusesTwoValidTablesThatDisagree(t *testing.T) {
	path := keephavenTable(t)
	f := open(t, path)

	// the backup header, wherever the primary says it is
	pri := make([]byte, 512)
	if _, err := f.ReadAt(pri, 512); err != nil {
		t.Fatal(err)
	}
	altLBA := int64(binary.LittleEndian.Uint64(pri[altLBAOffset:]))
	bak := make([]byte, 512)
	if _, err := f.ReadAt(bak, altLBA*512); err != nil {
		t.Fatal(err)
	}
	entryLBA := int64(binary.LittleEndian.Uint64(bak[entryLBAOffset:]))
	n := int64(binary.LittleEndian.Uint32(bak[numEntriesOffset:]))
	es := int64(binary.LittleEndian.Uint32(bak[entrySizeOffset:]))

	// change one byte of the BACKUP copy and make that copy valid on its own terms
	ent := make([]byte, n*es)
	if _, err := f.ReadAt(ent, entryLBA*512); err != nil {
		t.Fatal(err)
	}
	ent[entryUniqueOffset] ^= 0xFF
	if _, err := f.WriteAt(ent, entryLBA*512); err != nil {
		t.Fatal(err)
	}
	binary.LittleEndian.PutUint32(bak[entriesCRCOffset:], crc32.ChecksumIEEE(ent))
	resign(bak)
	if _, err := f.WriteAt(bak, altLBA*512); err != nil {
		t.Fatal(err)
	}
	f.Close()

	_, err := Check(open(t, path), 512)
	if err == nil {
		t.Fatal("accepted two valid tables that describe different drives")
	}
	if !strings.Contains(err.Error(), "not the same") {
		t.Errorf("refused for the wrong reason: %v", err)
	}
}

func TestGUIDLooksLikeVersion4(t *testing.T) {
	g, err := newGUID(rand.New(rand.NewSource(3)))
	if err != nil {
		t.Fatal(err)
	}
	if g[7]&0xF0 != 0x40 {
		t.Errorf("version nibble is %x, expected 4", g[7]>>4)
	}
	if g[8]&0xC0 != 0x80 {
		t.Errorf("variant bits are %02x, expected the top two to be 10", g[8])
	}
	s := guidString(g)
	if len(s) != 36 || strings.Count(s, "-") != 4 {
		t.Errorf("%q does not look like a GUID", s)
	}
	if bytes.Equal(g, make([]byte, 16)) {
		t.Error("the GUID is all zeros")
	}
}
