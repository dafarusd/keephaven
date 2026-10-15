// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// Give a freshly written drive identifiers of its own.
//
// Every Keephaven image is built with one disk GUID and four partition GUIDs, fixed at build
// time so a rebuild is byte-identical and a published hash means something. That makes every
// drive written from one image a twin of every other: two of them on one PC collide on
// /dev/disk/by-partuuid on Linux, Windows may take the second offline, and Windows remembers
// drive letters against those ids, so one owner's drive inherits the letters of the last one.
// The Linux flash scripts have always run `sgdisk -G` for exactly this. There is no sgdisk on
// Windows, so this does the same work: new disk GUID in both headers, a new unique GUID for
// every used entry in both arrays, and the two CRCs recomputed.
//
// Safe to do, confirmed from the image's own source rather than assumed: the recovery path
// parses the table for the TYPE GUID at entry offset 0 and the NAME at offset 56 and never
// reads the unique GUID at offset 16, and every mount in the system is by filesystem label or
// partlabel. Nothing in the image reads a unique id.
//
// It runs AFTER the image has been written and verified, so the shipped sha256 is checked
// against the bytes on the disk with no exclusions, and a re-id that fails leaves a verified
// bootable drive that merely shares its ids rather than an unverified one.
//
// This package is platform-neutral on purpose: it is exercised by go test against a sparse file
// carrying the real image's table, which is the only place the CRC arithmetic gets tested
// without a 1 TB drive in the room.
package gpt

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io"
)

// Device is the drive, or a file standing in for one.
type Device interface {
	io.ReaderAt
	io.WriterAt
}

const (
	sigOffset        = 0x00
	revisionOffset   = 0x08
	headerSizeOffset = 0x0C
	headerCRCOffset  = 0x10
	myLBAOffset      = 0x18
	altLBAOffset     = 0x20
	diskGUIDOffset   = 0x38
	entryLBAOffset   = 0x48
	numEntriesOffset = 0x50
	entrySizeOffset  = 0x54
	entriesCRCOffset = 0x58

	entryTypeOffset     = 0x00 // read by the image's recovery parse
	entryUniqueOffset   = 0x10 // what this package replaces; nothing reads it
	entryFirstLBAOffset = 0x20 // where FindPartition reads a partition's extent
	entryLastLBAOffset  = 0x28 // inclusive, per the spec
	entryNameOffset     = 0x38 // read by the image's recovery parse

	signature = "EFI PART"
)

// Change is one partition's before and after, for the log the owner sees.
type Change struct {
	Entry  int
	Name   string
	Before string
	After  string
}

// Report is what happened, so the caller can print it and a test can assert on it.
type Report struct {
	DiskBefore string
	DiskAfter  string
	Partitions []Change
}

type header struct {
	raw        []byte
	lba        int64
	headerSize uint32
	entryLBA   uint64
	numEntries uint32
	entrySize  uint32
}

func readHeader(d Device, sectorSize, lba int64) (*header, error) {
	raw := make([]byte, sectorSize)
	if _, err := d.ReadAt(raw, lba*sectorSize); err != nil {
		return nil, fmt.Errorf("reading the GPT header at LBA %d: %w", lba, err)
	}
	if string(raw[sigOffset:sigOffset+8]) != signature {
		return nil, fmt.Errorf("no GPT signature at LBA %d (found %q)", lba, raw[sigOffset:sigOffset+8])
	}
	h := &header{
		raw:        raw,
		lba:        lba,
		headerSize: binary.LittleEndian.Uint32(raw[headerSizeOffset:]),
		entryLBA:   binary.LittleEndian.Uint64(raw[entryLBAOffset:]),
		numEntries: binary.LittleEndian.Uint32(raw[numEntriesOffset:]),
		entrySize:  binary.LittleEndian.Uint32(raw[entrySizeOffset:]),
	}
	if h.headerSize < 92 || int64(h.headerSize) > sectorSize {
		return nil, fmt.Errorf("GPT header at LBA %d claims an impossible size of %d bytes", lba, h.headerSize)
	}
	if h.numEntries == 0 || h.entrySize < 128 || h.numEntries > 1024 {
		return nil, fmt.Errorf("GPT header at LBA %d claims %d entries of %d bytes", lba, h.numEntries, h.entrySize)
	}
	// MyLBA has to be where the header actually is. A header written to the wrong place, or one
	// copy of a pair that was moved without being rewritten, passes every other check here: its
	// CRC is intact because the bytes are intact, and only this field disagrees.
	if my := int64(binary.LittleEndian.Uint64(raw[myLBAOffset:])); my != lba {
		return nil, fmt.Errorf("the GPT header at LBA %d says it lives at LBA %d", lba, my)
	}
	if err := h.checkCRC(); err != nil {
		return nil, err
	}
	return h, nil
}

// checkCRC verifies the header's own CRC32, which is computed over HeaderSize bytes with the
// CRC field itself zeroed.
func (h *header) checkCRC() error {
	want := binary.LittleEndian.Uint32(h.raw[headerCRCOffset:])
	if got := h.computeCRC(); got != want {
		return fmt.Errorf("GPT header at LBA %d has CRC %08x, its own field says %08x", h.lba, got, want)
	}
	return nil
}

func (h *header) computeCRC() uint32 {
	tmp := make([]byte, h.headerSize)
	copy(tmp, h.raw[:h.headerSize])
	binary.LittleEndian.PutUint32(tmp[headerCRCOffset:], 0)
	return crc32.ChecksumIEEE(tmp)
}

func (h *header) setCRC() {
	binary.LittleEndian.PutUint32(h.raw[headerCRCOffset:], 0)
	binary.LittleEndian.PutUint32(h.raw[headerCRCOffset:], h.computeCRC())
}

func (h *header) entriesBytes() int64 { return int64(h.numEntries) * int64(h.entrySize) }

// newGUID returns 16 bytes in GPT's mixed-endian layout that print as a version 4 GUID, which
// is what sgdisk produces and what `sgdisk -v` expects to see.
func newGUID(rnd io.Reader) ([]byte, error) {
	b := make([]byte, 16)
	if _, err := io.ReadFull(rnd, b); err != nil {
		return nil, fmt.Errorf("no random bytes for a new GUID: %w", err)
	}
	// The version nibble lives in the high nibble of the third little-endian field, which is
	// byte 7 on disk; the variant bits live in the top two bits of byte 8.
	b[7] = (b[7] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	return b, nil
}

func guidString(b []byte) string {
	return fmt.Sprintf("%08X-%04X-%04X-%02X%02X-%012X",
		binary.LittleEndian.Uint32(b[0:4]),
		binary.LittleEndian.Uint16(b[4:6]),
		binary.LittleEndian.Uint16(b[6:8]),
		b[8], b[9], b[10:16])
}

func entryName(e []byte) string {
	u := make([]uint16, 0, 36)
	for i := entryNameOffset; i+1 < len(e) && i < entryNameOffset+72; i += 2 {
		c := binary.LittleEndian.Uint16(e[i:])
		if c == 0 {
			break
		}
		u = append(u, c)
	}
	out := make([]rune, 0, len(u))
	for _, c := range u {
		out = append(out, rune(c))
	}
	return string(out)
}

func used(e []byte) bool {
	return !bytes.Equal(e[entryTypeOffset:entryTypeOffset+16], make([]byte, 16))
}

// Reidentify gives the disk and every used partition a fresh GUID, in both the primary and the
// backup tables, and recomputes both CRCs in each. It writes the backup copies first, so a
// failure part way through leaves the primary table - the one the firmware reads - intact.
func Reidentify(d Device, sectorSize int64, rnd io.Reader) (*Report, error) {
	if sectorSize < 512 || sectorSize%512 != 0 {
		return nil, fmt.Errorf("a sector size of %d is not something this understands", sectorSize)
	}
	if rnd == nil {
		rnd = rand.Reader
	}

	primary, err := readHeader(d, sectorSize, 1)
	if err != nil {
		return nil, err
	}
	altLBA := int64(binary.LittleEndian.Uint64(primary.raw[altLBAOffset:]))
	backup, err := readHeader(d, sectorSize, altLBA)
	if err != nil {
		return nil, fmt.Errorf("the backup table is unreadable, so this will not touch either: %w", err)
	}
	if backup.numEntries != primary.numEntries || backup.entrySize != primary.entrySize {
		return nil, fmt.Errorf("the two tables disagree: primary %dx%d, backup %dx%d",
			primary.numEntries, primary.entrySize, backup.numEntries, backup.entrySize)
	}

	// The backup array is wherever the BACKUP header says it is, which is not a fixed distance
	// from the end of the disk.
	pEntries := make([]byte, primary.entriesBytes())
	if _, err := d.ReadAt(pEntries, int64(primary.entryLBA)*sectorSize); err != nil {
		return nil, fmt.Errorf("reading the primary entries: %w", err)
	}
	bEntries := make([]byte, backup.entriesBytes())
	if _, err := d.ReadAt(bEntries, int64(backup.entryLBA)*sectorSize); err != nil {
		return nil, fmt.Errorf("reading the backup entries: %w", err)
	}
	if want := binary.LittleEndian.Uint32(primary.raw[entriesCRCOffset:]); crc32.ChecksumIEEE(pEntries) != want {
		return nil, fmt.Errorf("the primary entries do not match their CRC; not touching this table")
	}
	if want := binary.LittleEndian.Uint32(backup.raw[entriesCRCOffset:]); crc32.ChecksumIEEE(bEntries) != want {
		return nil, fmt.Errorf("the backup entries do not match their CRC; not touching this table")
	}

	rep := &Report{DiskBefore: guidString(primary.raw[diskGUIDOffset : diskGUIDOffset+16])}

	diskGUID, err := newGUID(rnd)
	if err != nil {
		return nil, err
	}
	rep.DiskAfter = guidString(diskGUID)
	copy(primary.raw[diskGUIDOffset:], diskGUID)
	copy(backup.raw[diskGUIDOffset:], diskGUID)

	es := int(primary.entrySize)
	for i := 0; i < int(primary.numEntries); i++ {
		off := i * es
		e := pEntries[off : off+es]
		if !used(e) {
			continue
		}
		g, err := newGUID(rnd)
		if err != nil {
			return nil, err
		}
		rep.Partitions = append(rep.Partitions, Change{
			Entry:  i + 1,
			Name:   entryName(e),
			Before: guidString(e[entryUniqueOffset : entryUniqueOffset+16]),
			After:  guidString(g),
		})
		copy(pEntries[off+entryUniqueOffset:], g)
		// The same id in the backup array: the two must describe the same disk.
		if off+es <= len(bEntries) {
			copy(bEntries[off+entryUniqueOffset:], g)
		}
	}
	if len(rep.Partitions) == 0 {
		return nil, fmt.Errorf("the table has no used entries, which is not a Keephaven drive")
	}

	// Entries CRC first - it lives in the header - then the header's own.
	binary.LittleEndian.PutUint32(primary.raw[entriesCRCOffset:], crc32.ChecksumIEEE(pEntries))
	binary.LittleEndian.PutUint32(backup.raw[entriesCRCOffset:], crc32.ChecksumIEEE(bEntries))
	primary.setCRC()
	backup.setCRC()

	// Backup first: if the power goes between these writes, the table the firmware reads is
	// still the old, consistent one.
	if _, err := d.WriteAt(bEntries, int64(backup.entryLBA)*sectorSize); err != nil {
		return nil, fmt.Errorf("writing the backup entries: %w", err)
	}
	if _, err := d.WriteAt(backup.raw, backup.lba*sectorSize); err != nil {
		return nil, fmt.Errorf("writing the backup header: %w", err)
	}
	if _, err := d.WriteAt(pEntries, int64(primary.entryLBA)*sectorSize); err != nil {
		return nil, fmt.Errorf("writing the primary entries: %w", err)
	}
	if _, err := d.WriteAt(primary.raw, primary.lba*sectorSize); err != nil {
		return nil, fmt.Errorf("writing the primary header: %w", err)
	}
	return rep, nil
}

// Check re-reads both tables and insists they are valid and agree. A parse that passes on the
// primary alone is not a pass: the Rufus failure of 2026-10-14 left a table Windows could read
// and an image that was never written.
func Check(d Device, sectorSize int64) (*Report, error) {
	primary, err := readHeader(d, sectorSize, 1)
	if err != nil {
		return nil, err
	}
	altLBA := int64(binary.LittleEndian.Uint64(primary.raw[altLBAOffset:]))
	backup, err := readHeader(d, sectorSize, altLBA)
	if err != nil {
		return nil, err
	}
	pg := primary.raw[diskGUIDOffset : diskGUIDOffset+16]
	bg := backup.raw[diskGUIDOffset : diskGUIDOffset+16]
	if !bytes.Equal(pg, bg) {
		return nil, fmt.Errorf("the two tables name different disks: %s and %s", guidString(pg), guidString(bg))
	}
	pEntries := make([]byte, primary.entriesBytes())
	if _, err := d.ReadAt(pEntries, int64(primary.entryLBA)*sectorSize); err != nil {
		return nil, err
	}
	if want := binary.LittleEndian.Uint32(primary.raw[entriesCRCOffset:]); crc32.ChecksumIEEE(pEntries) != want {
		return nil, fmt.Errorf("the primary entries do not match their CRC")
	}
	bEntries := make([]byte, backup.entriesBytes())
	if _, err := d.ReadAt(bEntries, int64(backup.entryLBA)*sectorSize); err != nil {
		return nil, err
	}
	if want := binary.LittleEndian.Uint32(backup.raw[entriesCRCOffset:]); crc32.ChecksumIEEE(bEntries) != want {
		return nil, fmt.Errorf("the backup entries do not match their CRC")
	}
	// Both arrays valid is not the same as both arrays agreeing. Two CRCs can each be correct
	// over different content, which is exactly what half a rewrite looks like - and what the
	// test for this package needed to catch sgdisk quietly repairing one side from the other.
	if !bytes.Equal(pEntries, bEntries) {
		return nil, fmt.Errorf("the primary and backup partition entries are both valid and not the same")
	}
	rep := &Report{DiskBefore: guidString(pg), DiskAfter: guidString(pg)}
	es := int(primary.entrySize)
	for i := 0; i < int(primary.numEntries); i++ {
		e := pEntries[i*es : i*es+es]
		if !used(e) {
			continue
		}
		rep.Partitions = append(rep.Partitions, Change{
			Entry:  i + 1,
			Name:   entryName(e),
			Before: guidString(e[entryUniqueOffset : entryUniqueOffset+16]),
			After:  guidString(e[entryUniqueOffset : entryUniqueOffset+16]),
		})
	}
	return rep, nil
}

// FindPartition returns the byte range of the partition with this name, from the primary table
// after Check has agreed the two tables match. The range is what a caller may read and write
// WITHIN that partition and nothing outside it: the whole point of going through the table
// rather than a constant is that a partition's offset moves whenever the layout does.
func FindPartition(d Device, sectorSize int64, name string) (start, size int64, err error) {
	primary, err := readHeader(d, sectorSize, 1)
	if err != nil {
		return 0, 0, err
	}
	entries := make([]byte, primary.entriesBytes())
	if _, err := d.ReadAt(entries, int64(primary.entryLBA)*sectorSize); err != nil {
		return 0, 0, err
	}
	if want := binary.LittleEndian.Uint32(primary.raw[entriesCRCOffset:]); crc32.ChecksumIEEE(entries) != want {
		return 0, 0, fmt.Errorf("the primary entries do not match their CRC")
	}
	es := int(primary.entrySize)
	for i := 0; i < int(primary.numEntries); i++ {
		e := entries[i*es : i*es+es]
		if !used(e) || entryName(e) != name {
			continue
		}
		first := int64(binary.LittleEndian.Uint64(e[entryFirstLBAOffset:]))
		last := int64(binary.LittleEndian.Uint64(e[entryLastLBAOffset:]))
		if first <= 0 || last < first {
			return 0, 0, fmt.Errorf("partition %d (%s) says it runs from LBA %d to %d", i+1, name, first, last)
		}
		return first * sectorSize, (last - first + 1) * sectorSize, nil
	}
	return 0, 0, fmt.Errorf("no partition on this disk is named %s", name)
}
