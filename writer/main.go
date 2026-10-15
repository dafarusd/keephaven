// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only

//go:build windows

// Keephaven-Writer.exe - writes a Keephaven Photos SSD image to a drive on Windows.
//
// Why this exists rather than "download Rufus": on 2026-10-14 Rufus 4.15 on the HP rewrote the
// drive's partition table and then errored, leaving a drive whose first 64 MiB did not match
// the image at all - and it never checked, so nothing said so. Before that it would not even
// list the drive until a hidden setting was ticked, because the enclosure reports as a fixed
// disk. The same write done directly took 70 seconds at 497 MB/s and read back byte-identical.
// So the tool was the problem, and this is the tool.
//
// What it does, in order, and it will not skip any of it:
//
//	finds exactly one USB disk that is not Windows' own and not the one this is running from,
//	  of the right size, writable, and reporting the 512-byte sectors the image is built for;
//	shows what is on it and makes you type its make and size before anything is touched;
//	checks the download against its own checksum, still before any disk is opened;
//	locks and dismounts every volume on it, or refuses - at byte zero, never at 33 GB;
//	writes the image, hashing the compressed and the decompressed bytes on the way through;
//	reads every byte back through an unbuffered handle and compares against the shipped sha256;
//	gives the drive identifiers of its own, so two Keephavens on one PC do not collide;
//	takes the boot partition's drive letter away and gives KEEPHAVEN one, then says what to
//	  double-click.
//
// It has no network code, no arguments and runs no other program. A tool that erases disks
// should have nothing in it that a proxy, a certificate store or an antivirus can turn into a
// second failure mode.
package main

import (
	"bufio"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"keephaven.co/writer/code"
	"keephaven.co/writer/gpt"
)

// set at build time by writer/package.nix
var version = "unset-build"

const (
	// A drive sold as 64 GB holds 64,000,000,000 bytes, which is 59.6 GiB: a 64 << 30 floor
	// would have refused every drive the instructions tell a buyer to buy. The image is
	// 36.5 GB and the photo partition grows into the rest, so this is the real floor.
	minDiskBytes = 56000000000
	chunk        = 4 << 20
)

func say(f string, a ...any) { fmt.Printf(f+"\n", a...) }

// touched goes true the moment the drive is opened for writing. Until then "nothing was
// written" is a promise this program can keep; after it, saying so would be a lie told at the
// exact moment the owner is deciding whether to trust the drive.
var touched bool

func stop(f string, a ...any) {
	fmt.Printf("\n"+f+"\n", a...)
	if touched {
		fmt.Println("\nThe drive is unfinished and will not start a Keephaven as it is.")
		fmt.Println("Press Enter to close.")
	} else {
		fmt.Println("\nNothing was written. Press Enter to close.")
	}
	bufio.NewReader(os.Stdin).ReadString('\n')
	os.Exit(1)
}

// Decimal, not binary, everywhere a customer reads a number: the drive's box, the shop listing
// and this program's own minimum all speak decimal, so a drive sold as 64 GB has to print as
// about 64 GB and not as 59.6. The owner types this number back, so it has to be the one on the
// label in front of them.
func gb(n int64) string { return fmt.Sprintf("%.1f GB", float64(n)/1e9) }

func mbs(n int64, d time.Duration) float64 {
	if d <= 0 {
		return 0
	}
	return float64(n) / 1e6 / d.Seconds()
}

// candidate is a disk this is allowed to consider.
type candidate struct {
	disk   uint32
	model  string
	size   int64
	sector int64
}

func main() {
	say("Keephaven Photos SSD writer %s", version)
	say("")

	if !isAdmin() {
		say("Windows needs to allow this to write to a drive. Say yes to the prompt.")
		if err := relaunchAsAdmin(""); err != nil {
			stop("Windows would not allow it: %v", err)
		}
		return
	}

	exe, err := os.Executable()
	if err != nil {
		stop("could not work out where this program is: %v", err)
	}
	dir := filepath.Dir(exe)

	img, rawShaPath, gzShaPath, err := findFiles(dir)
	if err != nil {
		stop("%v\n\nKeep the downloaded files together in one folder: the .img.gz, the .img.sha256 and this program.", err)
	}
	want, err := readSha(rawShaPath)
	if err != nil {
		stop("%v", err)
	}
	// Required, not optional: this is the checksum of the DOWNLOAD, and it is what tells a
	// damaged download apart from a damaged drive. If it is missing or unreadable the download
	// is incomplete, and an incomplete download is not something to start erasing a disk over.
	wantGz, err := readSha(gzShaPath)
	if err != nil {
		stop("%v", err)
	}
	// Read before the drive is touched: a code file that is present and wrong is a refusal,
	// not something to discover after 36 GB has been written.
	buyerCode, err := findCode(dir)
	if err != nil {
		stop("%v", err)
	}

	st, err := os.Stat(img)
	if err != nil {
		stop("could not read %s: %v", filepath.Base(img), err)
	}
	say("image:    %s  (%s)", filepath.Base(img), gb(st.Size()))
	say("expected: %s", want)
	if buyerCode != "" {
		say("code:     %s  (from %s)", buyerCode, codeFileName)
	} else {
		say("code:     none in this folder - this drive will not be able to fetch updates")
	}
	say("")

	c := pickDisk(exe, img, rawShaPath, gzShaPath)
	say("")
	confirm(c)

	// After the owner has answered and before the drive is opened. The commonest failure by far
	// is a download that did not finish, and a damaged download must never reach a disk - but
	// making somebody watch a 5 GB checksum before the drive has even been named is how a tool
	// gets closed halfway through. They read, they type once, and then it works.
	say("checking the download before anything is written...")
	gzHave, err := hashFile(img)
	if err != nil {
		stop("could not read %s right through: %v", filepath.Base(img), err)
	}
	if gzHave != wantGz {
		stop("The file you downloaded is damaged.\n"+
			"  the file here is: %s\n  it should be:     %s\n\n"+
			"Download it again. Nothing has been written.", gzHave, wantGz)
	}
	say("the download is the one that was published (%s)", shortSha(gzHave))
	say("")

	held, err := takeDrive(c.disk)
	// Through a closure: `defer release(held)` would have taken the slice as it was here, and
	// the explicit release further down would then be a second CloseHandle on each handle.
	defer func() { release(held) }()
	if err != nil {
		// Before a single byte: Windows refuses raw writes inside a mounted volume's extent,
		// so carrying on would die tens of gigabytes in with "Access is denied".
		stop("Windows is still using this drive: %v\n\n"+
			"Close every window showing it, stop anything reading from it, and run this again.", err)
	}

	wrote, written, sentHash, gzHash, err := writeImage(img, c.disk)
	if err != nil {
		stop("the write stopped: %v\n\nRun this again when you have dealt with that.", err)
	}
	say("")
	say("wrote %s in %s", gb(wrote), written)

	// The same file, hashed again on its way through. It agreed before the drive was opened,
	// so a disagreement now means the file changed under us while it was being read.
	if gzHash != wantGz {
		stop("FAIL: the download changed while it was being read.\n"+
			"  on the way through: %s\n  it should be:       %s\n\n"+
			"Nothing else was using it, was it? Download it again and run this again.", gzHash, wantGz)
	}
	if sentHash != want {
		stop("FAIL: the image inside the download is not the one that was shipped.\n"+
			"  the file decompressed to: %s\n  the download should be:   %s\n\n"+
			"That is a bad download, not a bad drive. Download it again.", sentHash, want)
	}
	say("the image matched the shipped sha256 as it was written")

	say("reading every byte back off the drive to be sure...")
	got, err := readBackHash(c.disk, wrote)
	if err != nil {
		stop("could not read the drive back: %v", err)
	}
	if got != want {
		stop("FAIL: the drive does not hold what was written.\n"+
			"  read back from the drive: %s\n  the download should be:   %s\n\n"+
			"The image was fine, so this is the drive or the cable. Try another port, then another drive.", got, want)
	}
	say("PASS: the drive holds the image, byte for byte (%s)", got)

	say("")
	say("giving this drive identifiers of its own...")
	if err := reidentify(c.disk, c.sector); err != nil {
		say("  note: %v", err)
		say("  the drive is written and verified; it just shares its ids with other Keephavens.")
	}

	if buyerCode != "" {
		say("")
		say("writing this drive's update code...")
		if err := stampCode(c.disk, c.sector, buyerCode); err != nil {
			say("  note: %v", err)
			say("  the drive is written and verified; it just cannot fetch updates yet.")
		} else {
			say("  done - Keephaven-code.txt on the drive carries %s", buyerCode)
		}
	}

	release(held)
	held = nil
	if err := rereadPartitions(c.disk); err != nil {
		say("note: Windows did not re-read the table (%v); unplug and replug the drive.", err)
	}
	time.Sleep(3 * time.Second)

	if gone := hideFirmware(c.disk); len(gone) > 0 {
		say("took the boot partition's letter back off this PC: %s", strings.Join(gone, " "))
	}
	letter, err := giveKeephavenALetter(c.disk)
	if err != nil {
		say("")
		say("The drive is ready, but Windows has not given it a letter: %v", err)
		say("Unplug it and plug it in again, then look for a drive named KEEPHAVEN.")
	} else {
		say("")
		say("Your Keephaven is on %s", letter)
		say("Open %s and double-click Keephaven.exe to start it.", letter)
	}
	say("")
	say("Done. Press Enter to close.")
	bufio.NewReader(os.Stdin).ReadString('\n')
}

// findFiles insists on exactly one image beside this program and on BOTH of its checksums: one
// for the download, one for the image inside it. A download missing either file is an
// incomplete download, and this refuses rather than quietly checking less.
func findFiles(dir string) (img, rawSha, gzSha string, err error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return "", "", "", fmt.Errorf("could not look in %s: %v", dir, err)
	}
	var imgs []string
	for _, e := range ents {
		if !e.IsDir() && strings.HasSuffix(strings.ToLower(e.Name()), ".img.gz") {
			imgs = append(imgs, filepath.Join(dir, e.Name()))
		}
	}
	switch len(imgs) {
	case 0:
		return "", "", "", fmt.Errorf("there is no Keephaven image (a file ending .img.gz) in %s", dir)
	case 1:
	default:
		return "", "", "", fmt.Errorf("there are %d .img.gz files in %s and this will not guess between them", len(imgs), dir)
	}
	img = imgs[0]
	rawSha = strings.TrimSuffix(img, ".gz") + ".sha256" // ...img.gz -> ...img.sha256
	if _, err := os.Stat(rawSha); err != nil {
		return "", "", "", fmt.Errorf("%s is here but %s is not, so there would be nothing to judge the drive against",
			filepath.Base(img), filepath.Base(rawSha))
	}
	gzSha = img + ".sha256" // ...img.gz -> ...img.gz.sha256
	if _, err := os.Stat(gzSha); err != nil {
		return "", "", "", fmt.Errorf("%s is here but %s is not, so there would be no way to tell a damaged download from a damaged drive",
			filepath.Base(img), filepath.Base(gzSha))
	}
	return img, rawSha, gzSha, nil
}

// codeFileName is what the buyer's download calls the file holding their update code.
const codeFileName = "Keephaven-code.txt"

// findCode reads the buyer's update code from the download folder. Absent is fine and says so
// later; present but not a code is a refusal, because a drive that silently cannot fetch updates
// is the thing the whole arrangement exists to avoid.
func findCode(dir string) (string, error) {
	b, err := os.ReadFile(filepath.Join(dir, codeFileName))
	if err != nil {
		if os.IsNotExist(err) {
			return "", nil
		}
		return "", fmt.Errorf("could not read %s: %v", codeFileName, err)
	}
	// Take the first non-empty line that is not a comment, so the file can carry a word of
	// explanation for whoever opens it.
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if err := code.Check(line); err != nil {
			return "", fmt.Errorf("%s does not hold a usable code: %v", codeFileName, err)
		}
		return line, nil
	}
	return "", fmt.Errorf("%s is empty", codeFileName)
}

// stampCode writes the code into the field the image already carries on KEEPHAVEN. It goes
// through the partition table rather than a fixed offset, so a layout change cannot make it
// write into the wrong partition.
func stampCode(disk uint32, sector int64, c string) error {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead|genericWrite)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(h), "drive")
	defer f.Close()
	// sectorDevice, not deviceFile: the stamp reads and writes part-sector lengths at offsets
	// that are wherever the file happens to sit, and a raw drive handle refuses both.
	dev := sectorDevice{f: f, sector: sector}
	start, size, err := gpt.FindPartition(dev, sector, "KEEPHAVEN")
	if err != nil {
		return err
	}
	if _, err := code.Stamp(dev, start, size, c); err != nil {
		return err
	}
	return f.Sync()
}

// hashFile reads a file right through and returns its sha256, saying how fast it is going so a
// 5 GB read does not look like a hang.
func hashFile(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	sum := sha256.New()
	buf := make([]byte, chunk)
	t0 := time.Now()
	last := t0
	var read int64
	for {
		n, err := f.Read(buf)
		if n > 0 {
			sum.Write(buf[:n])
			read += int64(n)
			if time.Since(last) > 3*time.Second {
				last = time.Now()
				say("  %s read, %.0f MB/s", gb(read), mbs(read, time.Since(t0)))
			}
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// shortSha is for a line that is reassurance rather than evidence. A failure always prints both
// checksums in full.
func shortSha(h string) string {
	if len(h) < 12 {
		return h
	}
	return h[:12] + "..."
}

func readSha(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("could not read %s: %v", filepath.Base(path), err)
	}
	f := strings.Fields(string(b))
	if len(f) == 0 || len(f[0]) != 64 {
		return "", fmt.Errorf("%s does not contain a sha256", filepath.Base(path))
	}
	return strings.ToLower(f[0]), nil
}

// pickDisk finds the one disk this may write to, or explains why it will not write to any.
func pickDisk(exe string, files ...string) candidate {
	forbidden := map[uint32]string{}
	note := func(path, why string) {
		if d, ok := diskOfPath(path); ok {
			if _, seen := forbidden[d]; !seen {
				forbidden[d] = why
			}
		}
	}
	sys := os.Getenv("SystemDrive")
	if sys == "" {
		sys = "C:"
	}
	note(sys+`\`, "Windows runs from it")
	if r := os.Getenv("SystemRoot"); r != "" {
		note(r, "Windows is installed on it")
	}
	for d := range pagefileDisks() {
		if _, seen := forbidden[d]; !seen {
			forbidden[d] = "Windows keeps its pagefile on it"
		}
	}
	note(exe, "this program is running from it")
	for _, f := range files {
		if f != "" {
			note(f, "the download is being read from it")
		}
	}

	var found []candidate
	var skipped []string
	for d := uint32(0); d < 32; d++ {
		bus, model, err := diskBusAndModel(d)
		if err != nil {
			// Almost always "there is no such disk", which is not worth a line. Anything else
			// is a disk that exists and would not answer, and the owner has to see it: a disk
			// Windows has taken offline would otherwise vanish out of this list without a word.
			if !noSuchDisk(err) {
				skipped = append(skipped, fmt.Sprintf("  drive %d  could not be examined: %v", d, err))
			}
			continue
		}
		size, err := diskSize(d)
		if err != nil {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  could not say how big it is: %v", d, model, err))
			continue
		}
		if why, bad := forbidden[d]; bad {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  %s  - skipped, %s", d, model, gb(size), why))
			continue
		}
		if bus != busTypeUsb {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  %s  - skipped, not a USB drive", d, model, gb(size)))
			continue
		}
		if size < minDiskBytes {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  %s  - skipped, too small for a Keephaven", d, model, gb(size)))
			continue
		}
		if !diskWritable(d) {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  %s  - skipped, it is write-protected", d, model, gb(size)))
			continue
		}
		// The image is a 512-byte-sector image: its partition table puts the GPT header at
		// byte 512 and every partition boundary is a 512-byte LBA. Written byte for byte to a
		// drive that presents 4096-byte sectors it would verify perfectly and never boot,
		// because the firmware would look for the table at byte 4096 and find nothing. Some
		// USB enclosures do present 4Kn to get past 2 TB, so this is asked of every candidate
		// and a drive that answers anything else is refused by name.
		sec, err := diskSectorSize(d)
		if err != nil {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  %s  - skipped, it would not say how big a sector is: %v", d, model, gb(size), err))
			continue
		}
		if sec != 512 {
			skipped = append(skipped, fmt.Sprintf("  drive %d  %s  %s  - skipped, it reports %d-byte sectors and Keephaven needs 512", d, model, gb(size), sec))
			continue
		}
		found = append(found, candidate{disk: d, model: model, size: size, sector: sec})
	}

	for _, s := range skipped {
		say("%s", s)
	}
	switch len(found) {
	case 1:
		return found[0]
	case 0:
		stop("No drive to write to.\n\nKeephaven writes to a USB drive of 64 GB or more. Plug the drive in, " +
			"wait a few seconds, and start this again. If it is already plugged in, unplug it and plug it back in.")
	default:
		say("")
		for _, f := range found {
			say("  drive %d  %s  %s", f.disk, f.model, gb(f.size))
		}
		stop("There is more than one USB drive plugged in, and this will not guess which one you mean.\n\n" +
			"Unplug every USB drive except the one you want to write, then start this again.")
	}
	return candidate{}
}

// confirm shows what is on the drive and takes a typed answer. It erases a whole disk; a
// keypress is not enough, and the model alone is not enough either because model strings repeat.
func confirm(c candidate) {
	say("This will ERASE this drive and everything on it:")
	say("")
	say("    %s   %s   (Windows drive %d)", c.model, gb(c.size), c.disk)
	say("")
	vols := whatIsOnDisk(c.disk)
	if len(vols) == 0 {
		say("    Windows cannot read anything on it. That is what a new drive looks like,")
		say("    and also what a drive from another computer can look like.")
	} else {
		say("    On it now:")
		for _, v := range vols {
			if v.Note != "" {
				say("      %s  %s", v.Letter, v.Note)
				continue
			}
			say("      %s  %s  %s  %.1f GB used of %.1f GB", v.Letter, v.Label, v.FS, v.UsedGB, v.SizeGB)
		}
	}
	say("")
	want := fmt.Sprintf("%s %s", c.model, gb(c.size))
	say("If that is the right drive, type this line exactly and press Enter:")
	say("")
	say("    %s", want)
	say("")
	fmt.Print("> ")
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	// Case and runs of spaces are forgiven; the make and the size are not. The point is that
	// the owner has to read both off this screen, not that they type like a machine.
	flat := func(s string) string { return strings.ToLower(strings.Join(strings.Fields(s), " ")) }
	if flat(line) != flat(want) {
		stop("That is not what was asked for, so nothing has been touched.")
	}
	say("")
}

// writeImage decompresses the image straight onto the drive, hashing the decompressed bytes as
// they go - which costs nothing and catches a bad download before a single byte is trusted.
func writeImage(img string, disk uint32) (int64, string, string, string, error) {
	f, err := os.Open(img)
	if err != nil {
		return 0, "", "", "", err
	}
	defer f.Close()
	// Hash the compressed bytes on their way through. It costs one pass that is happening
	// anyway and it is what tells a buyer "your download is damaged" instead of "it failed".
	gzSum := sha256.New()
	zr, err := gzip.NewReader(bufio.NewReaderSize(io.TeeReader(f, gzSum), chunk))
	if err != nil {
		return 0, "", "", "", fmt.Errorf("%s is not a gzip file, or it is damaged: %v", filepath.Base(img), err)
	}
	defer zr.Close()

	h, err := openRaw(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead|genericWrite, fileFlagWriteThrough)
	if err != nil {
		return 0, "", "", "", fmt.Errorf("could not open the drive for writing: %v", err)
	}
	dev := os.NewFile(uintptr(h), "drive")
	defer dev.Close()
	touched = true

	sum := sha256.New()
	buf := aligned(chunk)
	var total int64
	t0 := time.Now()
	last := t0
	for {
		n, rerr := io.ReadFull(zr, buf)
		if n > 0 {
			sum.Write(buf[:n])
			if _, werr := dev.Write(buf[:n]); werr != nil {
				return total, "", "", "", fmt.Errorf("at %s: %v", gb(total), werr)
			}
			total += int64(n)
			if time.Since(last) > 3*time.Second {
				last = time.Now()
				say("  %s written, %.0f MB/s", gb(total), mbs(total, time.Since(t0)))
			}
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			break
		}
		if rerr != nil {
			return total, "", "", "", fmt.Errorf("reading the image at %s: %v", gb(total), rerr)
		}
	}
	// Drain whatever is left of the file so the compressed hash covers all of it: gzip stops
	// reading at the end of the stream, and a sha over part of a file proves nothing.
	if _, err := io.Copy(io.Discard, f); err != nil {
		return total, "", "", "", fmt.Errorf("reading the end of %s: %v", filepath.Base(img), err)
	}
	if err := dev.Sync(); err != nil {
		return total, "", "", "", fmt.Errorf("flushing the drive: %v", err)
	}
	return total, time.Since(t0).Round(time.Second).String(),
		hex.EncodeToString(sum.Sum(nil)), hex.EncodeToString(gzSum.Sum(nil)), nil
}

// readBackHash reads the drive through an UNBUFFERED handle, so what comes back is the disk and
// not Windows' cache of what was just written. Without this the check proves nothing on a
// machine with enough memory to hold the image.
func readBackHash(disk uint32, n int64) (string, error) {
	h, err := openRaw(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead, fileFlagNoBuffering)
	if err != nil {
		return "", err
	}
	dev := os.NewFile(uintptr(h), "drive")
	defer dev.Close()
	sum := sha256.New()
	buf := aligned(chunk) // length AND address must suit the sector size on an unbuffered handle
	var read int64
	t0 := time.Now()
	last := t0
	for read < n {
		want := int64(len(buf))
		if rem := n - read; rem < want {
			// The tail. An unbuffered read must stay sector-aligned, so read a whole chunk off
			// the disk - there is always more disk, since the minimum size is larger than the
			// image - and hash only the bytes that belong to the image. If the image happens to
			// be an exact multiple of the chunk this branch never runs, which is correct and not
			// something to "fix".
			got, err := io.ReadFull(dev, buf)
			if int64(got) < rem {
				return "", fmt.Errorf("the drive gave up %s short of the end: %v", gb(rem-int64(got)), err)
			}
			sum.Write(buf[:rem])
			read += rem
			break
		}
		got, err := io.ReadFull(dev, buf[:want])
		if got > 0 {
			sum.Write(buf[:got])
			read += int64(got)
			if time.Since(last) > 3*time.Second {
				last = time.Now()
				say("  %s read, %.0f MB/s", gb(read), mbs(read, time.Since(t0)))
			}
		}
		if err != nil {
			return "", fmt.Errorf("at %s: %v", gb(read), err)
		}
	}
	return hex.EncodeToString(sum.Sum(nil)), nil
}

// reidentify gives the disk and its partitions fresh ids, then insists the result parses from
// both copies of the table. It runs after the verify on purpose: the shipped sha is checked
// against the bytes on the disk with nothing excluded, and if this step fails the owner still
// has a verified, bootable drive that merely shares its ids.
func reidentify(disk uint32, sector int64) error {
	h, err := openDevice(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead|genericWrite)
	if err != nil {
		return err
	}
	dev := os.NewFile(uintptr(h), "drive")
	rep, err := gpt.Reidentify(deviceFile{dev}, sector, nil)
	if err != nil {
		dev.Close()
		return err
	}
	err = dev.Sync()
	dev.Close()
	if err != nil {
		return err
	}

	// Read the table straight back off the DISK, through an unbuffered handle: a buffered read
	// here could be answered out of Windows' cache of what was just written, which would prove
	// nothing - the same trap the image read-back avoids.
	// Deliberately NOT through IOCTL_DISK_UPDATE_PROPERTIES either: the volumes are still
	// locked at this point, so that call can fail for reasons that have nothing to do with the
	// table, and this function would then report ids unchanged when they had been written.
	// Windows is told to re-read later, once the locks are gone.
	h2, err := openRaw(fmt.Sprintf(`\\.\PhysicalDrive%d`, disk), genericRead, fileFlagNoBuffering)
	if err != nil {
		return err
	}
	dev2 := os.NewFile(uintptr(h2), "drive")
	defer dev2.Close()
	check, err := gpt.Check(unbufferedDevice{f: dev2, sector: sector}, sector)
	if err != nil {
		return fmt.Errorf("the new table does not read back cleanly: %v", err)
	}
	if len(check.Partitions) != len(rep.Partitions) {
		return fmt.Errorf("the table now has %d partitions, it had %d", len(check.Partitions), len(rep.Partitions))
	}
	say("  this drive: %s", rep.DiskAfter)
	for _, p := range rep.Partitions {
		say("    %-20s %s", p.Name, p.After)
	}
	return nil
}

// aligned returns a buffer of n bytes whose start address is a multiple of 4096. Go's allocator
// happens to hand out large blocks page-aligned, but FILE_FLAG_NO_BUFFERING fails the read with
// ERROR_INVALID_PARAMETER if it ever does not, and that would read as a drive fault to the owner.
func aligned(n int) []byte {
	const a = 4096
	b := make([]byte, n+a)
	off := int(uintptr(unsafe.Pointer(&b[0])) % a)
	if off != 0 {
		off = a - off
	}
	return b[off : off+n]
}

func release(held []lockedVolume) {
	for _, v := range held {
		syscall.CloseHandle(v.h)
	}
}

type lockedVolume struct {
	name string
	h    syscall.Handle
}

// takeDrive locks and dismounts every volume on the target so Windows stops writing to it while
// we do. The sequence is the helper's, at launcher/windows/main.go: lock, forced dismount, lock
// again - a first lock fails for something as ordinary as an Explorer window on the drive, and
// the forced dismount invalidates those handles so the second one succeeds. The helper can then
// ask the person at the keyboard to close the window; this cannot, because it may be driven over
// a pipe, so if the second lock still fails it gives up and says which drive to close.
//
// Giving up here means giving up BEFORE the drive is opened for writing. Carrying on with a
// volume Windows still owns is how a write dies thirty gigabytes in with "Access is denied".
func takeDrive(disk uint32) ([]lockedVolume, error) {
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
			release(held)
			return nil, fmt.Errorf("partition %d (%s) would not open: %v", part, v, err)
		}
		var n uint32
		if first := lockVolume(h, 3); first != nil {
			syscall.DeviceIoControl(h, fsctlDismountVolume, nil, 0, nil, 0, &n, nil)
			if final := lockVolume(h, 5); final != nil {
				syscall.CloseHandle(h)
				release(held)
				return nil, fmt.Errorf("partition %d (%s) stayed open after a forced dismount (%v)", part, v, final)
			}
		}
		syscall.DeviceIoControl(h, fsctlDismountVolume, nil, 0, nil, 0, &n, nil)
		held = append(held, lockedVolume{name: v, h: h})
	}
	return held, nil
}

// noSuchDisk is the one error from an open of \\.\PhysicalDriveN that means nothing at all.
func noSuchDisk(err error) bool {
	if e, ok := err.(syscall.Errno); ok {
		// ERROR_FILE_NOT_FOUND, ERROR_PATH_NOT_FOUND
		return e == 2 || e == 3
	}
	return false
}
