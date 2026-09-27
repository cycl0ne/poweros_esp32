// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Thomas Dye
//! BsdSockTest's results: a line per category on the screen, the whole
//! run in TAP version 12 in the log file.
//!
//! Every test ends in exactly one `ok` or `skip`, so a test's number is
//! the same from run to run. On the screen a category is its name, dots,
//! and how many passed; a test that failed is listed under it by number
//! and description, with the notable results (a rate, a round trip) the
//! category noted. With VERBOSE each test gets its own line as well.
//!
//! The log holds `ok N - text`, `not ok N - text`, `ok N - # SKIP why`,
//! and `# ...` for the details the tests note; the plan line `1..N` comes
//! last. It is flushed after each category, so a run that stops half way
//! still leaves what went before.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileHandle = sdk.dos.FileHandle;
const Printf = dos.stdio.Printf;
const FPrintf = dos.stdio.FPrintf;

/// The width a category's name is padded to with dots.
const category_width = 23;
/// The failed tests listed under a category; the log has the rest.
const failures_most = 16;
/// The notable results kept for a category, and how long each may be.
const notes_most = 8;
const note_bytes = 128;

const Failure = struct { number: u32, description: [*:0]const u8 };

pub const Tap = struct {
    sys: *ExecBase,
    dl: *DosBase,
    /// The log file, or null for none.
    log: ?*FileHandle,
    verbose: bool,

    /// Tests so far, over every category: the last one's number.
    number: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,
    skipped: u32 = 0,
    bailed: bool = false,

    /// The category running, or null between categories.
    category: ?[*:0]const u8 = null,
    category_passed: u32 = 0,
    category_failed: u32 = 0,
    category_skipped: u32 = 0,
    failures: [failures_most]Failure = undefined,
    failure_count: u32 = 0,
    notes: [notes_most][note_bytes]u8 = undefined,
    note_count: u32 = 0,
    note_used: usize = 0,

    /// The header, on the screen and in the log.
    pub fn start(tap: *Tap, version: [*:0]const u8, log_name: ?[*:0]const u8) void {
        tap.logLine("TAP version 12", .{});
        tap.logLine("# bsdsocktest %s", .{VERSION});
        tap.logLine("# bsdsocket.library: %s", .{version});
        _ = Printf(tap.dl, "BsdSockTest %s - %s\n", .{ VERSION, version });
        if (log_name) |name| {
            if (tap.log != null) _ = Printf(tap.dl, "Log: %s\n", .{name});
        }
        _ = Printf(tap.dl, "\n", .{});
    }

    /// A test's result.
    pub fn ok(tap: *Tap, passed: bool, description: [*:0]const u8) void {
        tap.number += 1;
        if (passed) {
            tap.logLine("ok %u - %s", .{ tap.number, description });
            tap.passed += 1;
            tap.category_passed += 1;
        } else {
            tap.logLine("not ok %u - %s", .{ tap.number, description });
            tap.failed += 1;
            tap.category_failed += 1;
            if (tap.category != null and tap.failure_count < failures_most) {
                tap.failures[tap.failure_count] = .{ .number = tap.number, .description = description };
                tap.failure_count += 1;
            }
        }
        if (tap.verbose) _ = Printf(tap.dl, "  %3u %s - %s\n", .{ tap.number, @as([*:0]const u8, if (passed) "ok   " else "FAIL "), description });
    }

    /// A test that could not run here, and why; it counts as passed.
    pub fn skip(tap: *Tap, reason: [*:0]const u8) void {
        tap.number += 1;
        tap.passed += 1;
        tap.skipped += 1;
        tap.category_passed += 1;
        tap.category_skipped += 1;
        tap.logLine("ok %u - # SKIP %s", .{ tap.number, reason });
        if (tap.verbose) _ = Printf(tap.dl, "  %3u skip  - %s\n", .{ tap.number, reason });
    }

    /// A detail, in the log only.
    pub fn diag(tap: *Tap, comptime format: [:0]const u8, args: anytype) void {
        tap.logLine("# " ++ format, args);
    }

    /// A notable result: in the log, and on the screen under the
    /// category's line.
    pub fn note(tap: *Tap, comptime format: [:0]const u8, args: anytype) void {
        tap.logLine("# " ++ format, args);
        if (tap.category == null or tap.note_count == notes_most) return;
        comptime exec.checkFormat(format, @TypeOf(args));
        const stream = exec.fmtStream(args);
        tap.note_used = 0;
        _ = tap.sys.RawDoFmt(format, &stream, &putNote, tap);
        tap.notes[tap.note_count][note_bytes - 1] = 0;
        tap.note_count += 1;
    }

    fn putNote(character: u8, data: ?*anyopaque) callconv(.c) void {
        const tap: *Tap = @ptrCast(@alignCast(data.?));
        if (tap.note_used < note_bytes - 1) {
            tap.notes[tap.note_count][tap.note_used] = character;
            tap.note_used += 1;
        }
    }

    /// The start of a category: its name and dots on the screen while it
    /// runs, which `end` finishes.
    pub fn begin(tap: *Tap, name: [*:0]const u8, description: [*:0]const u8) void {
        tap.category = name;
        tap.category_passed = 0;
        tap.category_failed = 0;
        tap.category_skipped = 0;
        tap.failure_count = 0;
        tap.note_count = 0;
        tap.logLine("# --- %s ---", .{name});
        tap.logLine("# %s", .{description});
        if (!tap.verbose) {
            tap.dots(name);
            _ = tap.dl.Flush(tap.dl.Output());
        }
    }

    /// The category's line: how many of its tests passed, which failed,
    /// and what it noted.
    pub fn end(tap: *Tap) void {
        const name = tap.category orelse return;
        if (!tap.verbose) _ = Printf(tap.dl, "\r", .{});
        tap.dots(name);
        const ran = tap.category_passed + tap.category_failed;
        _ = Printf(tap.dl, " %u/%u %s", .{ tap.category_passed, ran, @as([*:0]const u8, if (tap.category_failed > 0) "FAILED" else "passed") });
        tap.counts(tap.category_failed, tap.category_skipped);
        _ = Printf(tap.dl, "\n", .{});
        for (tap.failures[0..tap.failure_count]) |failure| {
            _ = Printf(tap.dl, "  FAIL #%u: %s\n", .{ failure.number, failure.description });
        }
        if (tap.category_failed > tap.failure_count) {
            _ = Printf(tap.dl, "  ... and %u more (see log)\n", .{tap.category_failed - tap.failure_count});
        }
        for (tap.notes[0..tap.note_count]) |*text| {
            _ = Printf(tap.dl, "  %s\n", .{@as([*:0]const u8, @ptrCast(text))});
        }
        tap.category = null;
        if (tap.log) |file| _ = tap.dl.Flush(file);
    }

    /// The run given up, and why.
    pub fn bail(tap: *Tap, reason: [*:0]const u8) void {
        tap.bailed = true;
        _ = Printf(tap.dl, "\nBail out! %s\n", .{reason});
        tap.logLine("Bail out! %s", .{reason});
    }

    /// The summary and the plan line; the return code: RETURN_FAIL when
    /// the run was given up, RETURN_WARN when a test failed, else
    /// RETURN_OK.
    pub fn finish(tap: *Tap) i32 {
        const ran = tap.passed + tap.failed;
        _ = Printf(tap.dl, "\nResults: %u/%u %s", .{ tap.passed, ran, @as([*:0]const u8, if (tap.failed > 0) "FAILED" else "passed") });
        tap.counts(tap.failed, tap.skipped);
        _ = Printf(tap.dl, "\n", .{});
        tap.logLine("1..%u", .{tap.number});
        tap.logLine("# Results: %u passed, %u failed, %u skipped (%u total)", .{ tap.passed, tap.failed, tap.skipped, tap.number });
        if (tap.bailed) return dos.RETURN_FAIL;
        if (tap.failed > 0) return dos.RETURN_WARN;
        return dos.RETURN_OK;
    }

    fn dots(tap: *Tap, name: [*:0]const u8) void {
        var length: u32 = 0;
        while (name[length] != 0) length += 1;
        const count = if (length + 3 > category_width) 3 else category_width - length;
        _ = Printf(tap.dl, "%s", .{name});
        var written: u32 = 0;
        while (written < count) : (written += 1) _ = Printf(tap.dl, ".", .{});
    }

    /// " (2 failed, 3 skipped)", or nothing when both are 0.
    fn counts(tap: *Tap, failed: u32, skipped: u32) void {
        if (failed == 0 and skipped == 0) return;
        if (failed > 0 and skipped > 0) {
            _ = Printf(tap.dl, " (%u failed, %u skipped)", .{ failed, skipped });
        } else if (failed > 0) {
            _ = Printf(tap.dl, " (%u failed)", .{failed});
        } else {
            _ = Printf(tap.dl, " (%u skipped)", .{skipped});
        }
    }

    fn logLine(tap: *Tap, comptime format: [:0]const u8, args: anytype) void {
        const file = tap.log orelse return;
        _ = FPrintf(tap.dl, file, format ++ "\n", args);
    }
};

/// The suite's version, as the log's header gives it.
pub const VERSION = "1.0";
