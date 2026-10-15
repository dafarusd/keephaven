// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only

// Package code stamps the buyer's update code into the field the image already carries on its
// Windows-visible partition, and reads it back to prove it landed.
//
// Why in place rather than writing a file: the field is created at image build time with a fixed
// length and the code is written over it byte for byte, same length, same clusters. So nothing
// here has to understand FAT, and a tool that erases disks carries no filesystem writer. The
// padding is '.' because a code may contain '-' but never a '.', so the padding can be stripped
// without ambiguity at the other end.
//
// What the code is NOT: it is not a password and it does not unlock anything on the drive. It is
// one path segment appended to the update host that is baked into the image, so a wrong code can
// only ever earn a refusal from Keephaven's own server - it can never point the drive somewhere
// else. See section 4a of the ssd publish gate.
package code

import (
	"bytes"
	"fmt"
	"io"
	"regexp"
)

// Marker is what the image writes and what this searches for. Changing it breaks every drive
// already in the field, because the guest looks for the same string.
const Marker = "KEEPHAVEN-UPDATE-CODE:"

// Field is the length of the padded value that follows the marker.
const Field = 64

// Valid is the same shape the drive's own service enforces. Deliberately no '.', no '/', no ':'
// and nothing that could read as a URL or a path.
var Valid = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{7,63}$`)

// Reserved is the one shape that is never minted: KH- followed by four zeros. Tests, examples,
// documentation and posts use codes from this range so that no code-shaped string anywhere in
// this tree can be one the update server would answer. It exists because the opposite happened:
// on 2026-10-15 the live code from a test drive was found sitting in this package's own test,
// in a tree about to be published, and a working update code in public source is exactly what
// the gate is for. feed-gate/mint-code.sh refuses to mint one - a random 64-bit mint lands in
// this range 1 time in 65536, so it draws again rather than hoping.
//
// Reserved codes are otherwise ordinary: Check accepts them and Stamp writes them, because a
// test has to be able to stamp a drive. The server is what never issues one.
var Reserved = regexp.MustCompile(`^KH-0000`)

// IsReserved reports whether c is in the never-minted range.
func IsReserved(c string) bool { return Reserved.MatchString(c) }

// Device is the part of a disk this package touches.
type Device interface {
	io.ReaderAt
	io.WriterAt
}

// Check says whether a string is usable as a code, with a reason a buyer can act on.
func Check(c string) error {
	switch {
	case c == "":
		return fmt.Errorf("the code is empty")
	case len(c) > Field:
		return fmt.Errorf("the code is %d characters; the longest a drive can carry is %d", len(c), Field)
	case !Valid.MatchString(c):
		return fmt.Errorf("%q is not a code: letters, digits and dashes only, at least 8 of them, starting with a letter or digit", c)
	}
	return nil
}

// find locates the marker inside the partition and returns the absolute offset of the field that
// follows it. It reads in overlapping windows so a marker spanning a window boundary is still
// found, and refuses if the field would run past the end of the partition.
func find(d Device, start, size int64) (int64, error) {
	const window = 1 << 20
	// The overlap between windows is rounded up to a sector so every read sits on a sector
	// boundary. A raw drive handle refuses anything else outright, and a 1 MiB window advancing
	// by 1 MiB minus 86 bytes is how this failed on real hardware the first time.
	const align = 4096
	need := int64(len(Marker) + Field)
	overlap := (need + align - 1) / align * align
	if size < need {
		return 0, fmt.Errorf("the partition is too small to hold the code field")
	}
	buf := make([]byte, window)
	for off := int64(0); off < size; off += window - overlap {
		n := int64(window)
		if off+n > size {
			n = size - off
		}
		if n < need {
			break
		}
		if _, err := d.ReadAt(buf[:n], start+off); err != nil && err != io.EOF {
			return 0, err
		}
		i := bytes.Index(buf[:n], []byte(Marker))
		if i < 0 {
			continue
		}
		at := off + int64(i) + int64(len(Marker))
		if at+Field > size {
			return 0, fmt.Errorf("the code field runs past the end of the partition")
		}
		return start + at, nil
	}
	return 0, fmt.Errorf("this image carries no update code field")
}

// Stamp writes the code over the field and reads it back to prove it. Returns the offset it used.
//
// The Device MUST tolerate reads and writes at any offset and of any length. A raw Windows drive
// handle does NOT: it takes only whole sectors at sector offsets, and the 64-byte field sits
// wherever the file sits inside the filesystem, so it can never be aligned by itself. On Windows
// the handle is wrapped in sectorDevice (winextra.go) for exactly this reason; handing this a bare
// drive handle fails with "The parameter is incorrect", which is how it failed on the HP on
// 2026-10-14. TestABareRawDeviceIsRefusedBecauseTheFieldIsNeverAligned holds that line.
func Stamp(d Device, start, size int64, c string) (int64, error) {
	if err := Check(c); err != nil {
		return 0, err
	}
	at, err := find(d, start, size)
	if err != nil {
		return 0, err
	}
	val := make([]byte, Field)
	for i := range val {
		val[i] = '.'
	}
	copy(val, c)
	if _, err := d.WriteAt(val, at); err != nil {
		return 0, err
	}
	back := make([]byte, Field)
	if _, err := d.ReadAt(back, at); err != nil {
		return 0, err
	}
	if !bytes.Equal(back, val) {
		return 0, fmt.Errorf("the code did not stay written")
	}
	return at, nil
}

// Read returns the code currently in the field, or "" if the field is still all padding.
func Read(d Device, start, size int64) (string, error) {
	at, err := find(d, start, size)
	if err != nil {
		return "", err
	}
	buf := make([]byte, Field)
	if _, err := d.ReadAt(buf, at); err != nil {
		return "", err
	}
	if i := bytes.IndexByte(buf, '.'); i >= 0 {
		buf = buf[:i]
	}
	return string(buf), nil
}
