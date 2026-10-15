// SPDX-FileCopyrightText: 2026 Keephaven LLC
// SPDX-License-Identifier: AGPL-3.0-only
//
// The release build. This file takes the place of testbed.go when the helper is built with
// `-tags release`, and it is what makes the difference checkable: every seam below does
// nothing, so a released helper opens no port, fetches nothing, starts only the QEMU that
// came with the drive, and takes no instruction from the network.

//go:build windows && release

package main

import "time"

const releaseBuild = true

// What the log calls this build. A release says only the date: a log a stranger sends us
// has to be readable as a release at a glance, and "test-" in it would be a lie.
// Set at build time by launcher.nix: -X main.version=<keephaven.imageVersion>. It was a const
// reading "2026.10.12a", so the fresh 2026.10.16 drive's helper.log said 2026.10.12a and support
// would have read the wrong version off a customer's machine. A var, because -X cannot write a
// const. The fallback value is deliberately not a version: an unset build should look wrong.
var version = "unset-build"

// Nil channels. A receive on one blocks for ever and len() is 0, so the run loop simply
// never hears from anybody.
var (
	nextRun    chan attempt
	remoteStop chan bool
)

func testServe()                                       {}
func testFirewallPorts() []string                      { return nil }
func testNewerHelper(cur []byte) []byte                { return cur }
func testExtraQemuDirs() []string                      { return nil }
func testSettings(t attempt) string                    { return "" }
func testHostChecks(disk uint32)                       {}
func testTail(serial string)                           {}
func testMark(text string)                             {}
func testQuietFor() time.Duration                      { return 0 }
func testWatch(pid int, stop <-chan struct{})          {}
func testFirstAttempts() []attempt                     { return nil }
func testTraceArgs(t attempt, args []string) []string  { return args }
func testTune(t attempt, pid int)                      {}
func testWhileRunning(t attempt, gone <-chan struct{}) {}
func testCleanup()                                     {}

// testPickQemu: the release build runs the QEMU that came with the drive, and nothing else.
func testPickQemu(t attempt, label, runDir, qemu, share string) (string, string, bool) {
	return qemu, share, true
}
