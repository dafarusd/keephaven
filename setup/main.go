// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only

//go:build windows

// Keephaven-Setup.exe - the one thing a buyer downloads.
//
// It fetches the Keephaven image and the writer, checks both against their published
// checksums, and starts the writer. Nobody should have to collect seven files out of a web
// page and keep them in the right folder: that is what this exists to stop.
//
// IT NEVER TOUCHES A DISK. That is the whole reason it is a separate program from
// Keephaven-Writer.exe, which never touches the network. A tool that erases disks should have
// nothing in it that a proxy, a certificate store or an antivirus can turn into a second
// failure mode - and the converse holds too, so the thing with the network code cannot open a
// drive even if it is wrong.
//
// The buyer's update code is stamped into this binary at download time, into the fixed field
// below. The same trick, and the same reasoning, as the code field on the drive itself: a
// fixed-length placeholder written over byte for byte, so the file's length never changes.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// version is set at build time.
var version = "unset-build"

// base is where this asks for everything. Baked in, never read from a file or an argument:
// a setup program that can be pointed somewhere else is a setup program that can be used to
// deliver somebody else's image.
const base = "https://updates.keephaven.co/get/ssd"

// codeField is overwritten at download time. The marker is searched for in the binary and the
// 64 bytes after it are the code, padded with dots - a code may contain '-' and never a '.',
// so the padding strips without guessing. Kept as a var and read through a function so the
// compiler cannot fold it away.
var codeField = "KEEPHAVEN-SETUP-CODE:................................................................"

// Sliced out of the field rather than written again as its own constant. Two literals meant
// the linker stored the marker twice and the build check found the wrong one - and a stamper
// would have overwritten the wrong 64 bytes just as easily (2026-10-15).
const markerLen = 21

func codeMarkerStr() string { return codeField[:markerLen] }

var validCode = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{7,63}$`)

func buyerCode() string {
	if len(codeField) < markerLen || codeMarkerStr() == "" {
		return ""
	}
	c := strings.TrimRight(codeField[markerLen:], ".")
	if !validCode.MatchString(c) {
		return ""
	}
	return c
}

type indexFile struct {
	Name  string `json:"name"`
	Bytes int64  `json:"bytes"`
}

type index struct {
	Version string      `json:"version"`
	Files   []indexFile `json:"files"`
}

func say(f string, a ...any) { fmt.Printf(f+"\n", a...) }

func stop(f string, a ...any) {
	say("")
	say(f, a...)
	say("")
	say("Nothing was written to any drive. Press Enter to close.")
	fmt.Scanln()
	os.Exit(1)
}

func gb(n int64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/float64(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.0f MB", float64(n)/float64(1<<20))
	default:
		return fmt.Sprintf("%d bytes", n)
	}
}

func main() {
	say("Keephaven Photos SSD - setup %s", version)
	say("")

	code := buyerCode()
	if code == "" {
		stop("This copy of the setup program has no update code in it.\n" +
			"Download it again from keephaven.co/ssd - each download carries its own.")
	}

	exe, err := os.Executable()
	if err != nil {
		stop("could not work out where this program is: %v", err)
	}
	// Everything lands in a folder beside this program, named so it is obvious what it is and
	// obvious that it can be deleted afterwards.
	dir := filepath.Join(filepath.Dir(exe), "Keephaven")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		stop("could not make a folder to download into:\n  %v", err)
	}
	say("Downloading into:  %s", dir)
	say("")

	client := &http.Client{Timeout: 0}

	idx, err := fetchIndex(client, code)
	if err != nil {
		stop("Could not ask Keephaven what the current version is.\n  %v\n\n"+
			"Check this PC is online and try again. If it keeps failing, write to support@keephaven.co.", err)
	}
	say("Current version:   %s", idx.Version)
	var total int64
	for _, f := range idx.Files {
		if f.Name != "index.json" {
			total += f.Bytes
		}
	}
	say("To download:       %s", gb(total))
	say("")

	// Smallest first, so every checksum file is already here when the thing it describes
	// arrives. The server lists them in a sensible reading order, which is NOT the order to
	// fetch them in: the image came down before its own checksum and the check was silently
	// skipped (caught on the HP, 2026-10-15).
	want := make([]indexFile, 0, len(idx.Files))
	for _, f := range idx.Files {
		if f.Name != "index.json" {
			want = append(want, f)
		}
	}
	sort.SliceStable(want, func(i, j int) bool { return want[i].Bytes < want[j].Bytes })

	for _, f := range want {
		if err := fetchFile(client, code, f, dir); err != nil {
			stop("Downloading %s stopped:\n  %v\n\n"+
				"Run this again - it carries on from where it got to.", f.Name, err)
		}
	}

	// The code file the writer reads, written here rather than downloaded: it is the one thing
	// that is ours to produce and the server never stores anyone's.
	codePath := filepath.Join(dir, "Keephaven-code.txt")
	if err := os.WriteFile(codePath, []byte(codeFileBody(code)), 0o644); err != nil {
		stop("could not write %s: %v", codePath, err)
	}

	say("")
	say("Everything is here and every file matched its published checksum.")
	say("")

	writer := filepath.Join(dir, "Keephaven-Writer.exe")
	if _, err := os.Stat(writer); err != nil {
		stop("The writer did not arrive. Run this again.")
	}
	say("Starting the writer. It will ask Windows for permission, then show you")
	say("the one drive it is about to erase.")
	say("")
	time.Sleep(2 * time.Second)

	cmd := exec.Command(writer)
	cmd.Dir = dir
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		say("")
		say("The writer closed: %v", err)
		say("You can run it yourself from %s", writer)
		say("")
		say("Press Enter to close.")
		fmt.Scanln()
	}
}

func fetchIndex(c *http.Client, code string) (*index, error) {
	resp, err := c.Get(base + "/" + code + "/index.json")
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode == 403 {
		return nil, fmt.Errorf("Keephaven did not accept this download's code")
	}
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("the server answered %d", resp.StatusCode)
	}
	var idx index
	if err := json.NewDecoder(resp.Body).Decode(&idx); err != nil {
		return nil, err
	}
	if len(idx.Files) == 0 {
		return nil, fmt.Errorf("the server listed no files")
	}
	return &idx, nil
}

// fetchFile downloads one file, resuming if part of it is already here, and refuses to leave a
// file in place that is not the size the server said it would be.
func fetchFile(c *http.Client, code string, f indexFile, dir string) error {
	dest := filepath.Join(dir, f.Name)
	var have int64
	if st, err := os.Stat(dest); err == nil {
		have = st.Size()
		if have == f.Bytes {
			say("%-46s already here", f.Name)
			return nil
		}
		if have > f.Bytes {
			if err := os.Remove(dest); err != nil {
				return err
			}
			have = 0
		}
	}

	req, err := http.NewRequest("GET", base+"/"+code+"/"+urlEscape(f.Name), nil)
	if err != nil {
		return err
	}
	if have > 0 {
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-", have))
	}
	resp, err := c.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 && resp.StatusCode != 206 {
		return fmt.Errorf("the server answered %d", resp.StatusCode)
	}
	if have > 0 && resp.StatusCode == 200 {
		// It ignored the resume and is sending the whole thing, so start the file again rather
		// than append to what is already there.
		have = 0
	}

	flags := os.O_CREATE | os.O_WRONLY
	if have > 0 {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}
	out, err := os.OpenFile(dest, flags, 0o644)
	if err != nil {
		return err
	}
	done := have
	start := time.Now()
	last := start
	buf := make([]byte, 1<<20)
	for {
		n, rerr := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := out.Write(buf[:n]); werr != nil {
				out.Close()
				return werr
			}
			done += int64(n)
			if time.Since(last) > 900*time.Millisecond {
				last = time.Now()
				pct := float64(done) / float64(f.Bytes) * 100
				rate := float64(done-have) / time.Since(start).Seconds()
				fmt.Printf("\r%-46s %5.1f%%  %s/s      ", f.Name, pct, gb(int64(rate)))
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			out.Close()
			return rerr
		}
	}
	if err := out.Close(); err != nil {
		return err
	}
	if st, err := os.Stat(dest); err != nil || st.Size() != f.Bytes {
		return fmt.Errorf("it arrived as %d bytes, not %d", st.Size(), f.Bytes)
	}
	fmt.Printf("\r%-46s %s", f.Name, gb(f.Bytes))

	// Checksums, where the server published one. The writer checks the image again itself
	// before it opens a disk; this is so a bad download is caught here rather than there.
	if strings.HasSuffix(f.Name, ".sha256") || strings.HasSuffix(f.Name, ".txt") {
		fmt.Printf("\n")
		return nil
	}
	sum, ok := checksumFor(f.Name, dir)
	if !ok {
		// Not a warning. A file this cannot check is a file it has no business handing to
		// something that erases a disk.
		os.Remove(dest)
		return fmt.Errorf("there is no published checksum for %s, so it cannot be checked", f.Name)
	}
	{
		got, err := hashFile(dest)
		if err != nil {
			return err
		}
		if got != sum {
			os.Remove(dest)
			return fmt.Errorf("the file that arrived is not the one that was published\n  arrived: %s\n  should be: %s", got, sum)
		}
		fmt.Printf("  checked")
	}
	fmt.Printf("\n")
	return nil
}

// checksumFor looks for <name>.sha256 beside the file. The checksum files are small and come
// down first, so by the time a big file lands its checksum is already here.
func checksumFor(name, dir string) (string, bool) {
	b, err := os.ReadFile(filepath.Join(dir, name+".sha256"))
	if err != nil {
		return "", false
	}
	fields := strings.Fields(string(b))
	if len(fields) == 0 || len(fields[0]) != 64 {
		return "", false
	}
	return strings.ToLower(fields[0]), true
}

func hashFile(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func urlEscape(s string) string { return strings.ReplaceAll(s, " ", "%20") }

// codeFileBody is the same text mint-code.sh and the Worker write, so all three cannot drift.
func codeFileBody(code string) string {
	return code + "\r\n\r\n" +
		"# This is your Keephaven update code. Keep this file next to the image and the\r\n" +
		"# writer when you write your drive - Keephaven puts it on the drive for you.\r\n" +
		"#\r\n" +
		"# It is not a password. It does not unlock anything on the drive. It tells the\r\n" +
		"# Keephaven update server which drive is asking, so it can send you new\r\n" +
		"# versions. You can write your drive as many times as you like with it.\r\n"
}
