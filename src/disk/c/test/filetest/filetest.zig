// SPDX-License-Identifier: MIT
//! FileTest: how fast a file system writes and reads through dos - one
//! large file, and many small ones - and whether what was written reads
//! back. Built against the SDK only.
//!
//!   FileTest DRAWER/A,SIZE/K/N,BUFFER/K/N,FILES/K/N,FILESIZE/K/N,KEEP/S
//!
//!   FileTest HD0:                      a file of 256 MiB written in
//!                                      pieces of 1 MiB, read back,
//!                                      compared, deleted
//!   FileTest HD0: SIZE 4096 BUFFER 65536
//!                                      ... of 4 GiB in pieces of 64 KiB
//!   FileTest HD0:Work FILES 1000       1000 files of 4 KiB made in a
//!                                      drawer of their own, read back,
//!                                      deleted
//!   FileTest HD0: FILES 200 FILESIZE 65536 KEEP
//!                                      ... of 64 KiB each, and left
//!
//! Everything goes in DRAWER, which must be there: the large file as
//! `FileTest.dat`, the small ones in a new drawer `FileTest.d`. Nothing
//! else is written. A speed counts the time in dos's calls only - Open,
//! Write or Read, Close, DeleteFile - not filling the buffer or checking
//! it; a write's ends with its Close. SIZE without FILES, or FILES
//! without SIZE, runs only that test; neither runs the large file's.
//! Ctrl-C stops it, and what it made is deleted all the same unless KEEP.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const timer = sdk.devices.timer;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "FileTest";
const VERSION_STRING = "\x00$VER: FileTest 1.0 (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DRAWER/A,SIZE/K/N,BUFFER/K/N,FILES/K/N,FILESIZE/K/N,KEEP/S";
const arg_drawer = 0;
const arg_size = 1;
const arg_buffer = 2;
const arg_files = 3;
const arg_file_size = 4;
const arg_keep = 5;

const default_size_mib: u32 = 256;
const default_buffer: u32 = 1024 * 1024;
const most_buffer: u32 = 64 * 1024 * 1024;
const default_file_size: u32 = 4096;

const big_name = "FileTest.dat";
const small_drawer = "FileTest.d";

const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    timer_base: *TimerBase,
    buffer: []u8,
    keep: bool,
    /// The microseconds spent in dos's calls.
    spent: u64 = 0,

    /// `call` timed into `spent`.
    fn timed(run: *Run, comptime call: anytype, args: anytype) @typeInfo(@TypeOf(call)).@"fn".return_type.? {
        const started = eclock(run.timer_base);
        const result = @call(.auto, call, args);
        run.spent += eclock(run.timer_base) - started;
        return result;
    }

    fn stopped(run: *Run) bool {
        if (run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
        _ = run.dl.PutStr("***Break\n");
        return true;
    }
};

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);

    var argv: [6]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const drawer = std.mem.span(@as([*:0]const u8, @ptrFromInt(argv[arg_drawer])));
    const files = number(argv[arg_files], 0);
    const size_mib = number(argv[arg_size], if (files == 0) default_size_mib else 0);
    const buffer_bytes = std.mem.alignForward(u32, std.math.clamp(number(argv[arg_buffer], default_buffer), 512, most_buffer), 8);
    const file_size = std.mem.alignForward(u32, std.math.clamp(number(argv[arg_file_size], default_file_size), 8, most_buffer), 8);

    const lock = dl.Lock(drawer.ptr, dos.SHARED_LOCK) orelse {
        _ = dl.PrintFault(dl.IoErr(), drawer.ptr);
        return dos.RETURN_ERROR;
    };
    dl.UnLock(lock);

    var clock: timer.TimeRequest = .{};
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &clock.node, 0) != 0) return dos.RETURN_FAIL;
    defer sys.CloseDevice(&clock.node);
    const bytes = @max(buffer_bytes, if (files != 0) file_size else 0);
    const memory = sys.AllocVec(bytes, exec.MEMF_ANY) orelse {
        _ = Printf(dl, "%s: no memory for a buffer of %u bytes\n", .{ COMMAND_NAME, bytes });
        return dos.RETURN_FAIL;
    };
    defer sys.FreeVec(memory);
    var run = Run{
        .sys = sys,
        .dl = dl,
        .timer_base = @ptrCast(@alignCast(clock.node.device.?)),
        .buffer = @as([*]u8, @ptrCast(memory))[0..bytes],
        .keep = argv[arg_keep] != 0,
    };

    if (size_mib != 0) {
        const result = bigFile(&run, drawer, @as(u64, size_mib) << 20, buffer_bytes);
        if (result != dos.RETURN_OK) return result;
    }
    if (files != 0) return smallFiles(&run, drawer, files, file_size);
    return dos.RETURN_OK;
}

// --- one large file -----------------------------------------------------------------------

fn bigFile(run: *Run, drawer: []const u8, total: u64, buffer_bytes: u32) i32 {
    const dl = run.dl;
    var path: [dos.path_max + 1:0]u8 = @splat(0);
    if (!join(&path, drawer, big_name)) return tooLong(run);

    run.spent = 0;
    const out = run.timed(DosBase.Open, .{ dl, &path, dos.MODE_NEWFILE }) orelse return failed(run, "cannot make", &path);
    var done: u64 = 0;
    var whole = true;
    while (done < total) {
        if (run.stopped()) {
            whole = false;
            break;
        }
        const piece: u32 = @intCast(@min(total - done, buffer_bytes));
        fill(run.buffer[0..piece], done);
        if (run.timed(DosBase.Write, .{ dl, out, run.buffer.ptr, @as(isize, @intCast(piece)) }) != piece) {
            _ = run.timed(DosBase.Close, .{ dl, out });
            return failedAt(run, "write", &path, done);
        }
        done += piece;
    }
    if (!run.timed(DosBase.Close, .{ dl, out })) return failed(run, "cannot close", &path);
    if (!whole) return cleanBig(run, &path, dos.RETURN_WARN);
    report(run, "written", total, buffer_bytes);

    run.spent = 0;
    const in = run.timed(DosBase.Open, .{ dl, &path, dos.MODE_OLDFILE }) orelse return failed(run, "cannot open", &path);
    done = 0;
    var mismatch: ?u64 = null;
    while (done < total) {
        if (run.stopped()) {
            _ = run.timed(DosBase.Close, .{ dl, in });
            return cleanBig(run, &path, dos.RETURN_WARN);
        }
        const piece: u32 = @intCast(@min(total - done, buffer_bytes));
        if (run.timed(DosBase.Read, .{ dl, in, run.buffer.ptr, @as(isize, @intCast(piece)) }) != piece) {
            _ = run.timed(DosBase.Close, .{ dl, in });
            return failedAt(run, "read", &path, done);
        }
        if (mismatch == null) mismatch = differs(run.buffer[0..piece], done);
        done += piece;
    }
    _ = run.timed(DosBase.Close, .{ dl, in });
    report(run, "read", total, buffer_bytes);
    if (mismatch) |byte| {
        _ = Printf(dl, "%s: %s differs from what was written from byte %lu on\n", .{ COMMAND_NAME, @as([*:0]const u8, &path), byte });
        return cleanBig(run, &path, dos.RETURN_ERROR);
    }
    _ = dl.PutStr("what was written read back as it was\n");
    return cleanBig(run, &path, dos.RETURN_OK);
}

/// The large file deleted, timed, unless KEEP; `result` passed on.
fn cleanBig(run: *Run, path: [*:0]const u8, result: i32) i32 {
    if (run.keep) return result;
    run.spent = 0;
    if (!run.timed(DosBase.DeleteFile, .{ run.dl, path })) return failed(run, "cannot delete", path);
    _ = Printf(run.dl, "deleted in %lu.%03lu ms\n", .{ run.spent / 1000, run.spent % 1000 });
    return result;
}

fn report(run: *Run, what: [*:0]const u8, bytes: u64, buffer_bytes: u32) void {
    const took = @max(run.spent, 1);
    const kib_s = bytes * 1_000_000 / took / 1024;
    _ = Printf(run.dl, "%lu MiB %s in %lu ms, %lu.%02lu MiB/s, in pieces of %u bytes\n", .{ bytes >> 20, what, took / 1000, kib_s / 1024, kib_s % 1024 * 100 / 1024, buffer_bytes });
}

// --- many small files ---------------------------------------------------------------------

fn smallFiles(run: *Run, drawer: []const u8, files: u32, file_size: u32) i32 {
    const dl = run.dl;
    var base: [dos.path_max + 1:0]u8 = @splat(0);
    if (!join(&base, drawer, small_drawer)) return tooLong(run);
    const made = dl.CreateDir(&base) orelse return failed(run, "cannot make", &base);
    dl.UnLock(made);
    const data = run.buffer[0..file_size];

    // Made.
    run.spent = 0;
    var count: u32 = 0;
    var result: i32 = dos.RETURN_OK;
    while (count < files) : (count += 1) {
        if (run.stopped()) {
            result = dos.RETURN_WARN;
            break;
        }
        var path: [dos.path_max + 1:0]u8 = undefined;
        nameOf(&path, &base, count);
        fill(data, @as(u64, count) << 32);
        const out = run.timed(DosBase.Open, .{ dl, &path, dos.MODE_NEWFILE }) orelse {
            result = failed(run, "cannot make", &path);
            break;
        };
        const wrote = run.timed(DosBase.Write, .{ dl, out, data.ptr, @as(isize, @intCast(file_size)) });
        const closed = run.timed(DosBase.Close, .{ dl, out });
        if (wrote != file_size or !closed) {
            count += 1;
            result = failed(run, "cannot write", &path);
            break;
        }
    }
    const made_count = count;
    if (result == dos.RETURN_OK) perFile(run, "made", files, file_size);

    // Read back.
    if (result == dos.RETURN_OK) {
        run.spent = 0;
        var wrong: u32 = 0;
        count = 0;
        while (count < files) : (count += 1) {
            if (run.stopped()) {
                result = dos.RETURN_WARN;
                break;
            }
            var path: [dos.path_max + 1:0]u8 = undefined;
            nameOf(&path, &base, count);
            const in = run.timed(DosBase.Open, .{ dl, &path, dos.MODE_OLDFILE }) orelse {
                result = failed(run, "cannot open", &path);
                break;
            };
            const got = run.timed(DosBase.Read, .{ dl, in, data.ptr, @as(isize, @intCast(file_size)) });
            _ = run.timed(DosBase.Close, .{ dl, in });
            if (got != file_size or differs(data, @as(u64, count) << 32) != null) wrong += 1;
        }
        if (result == dos.RETURN_OK) {
            perFile(run, "read", files, file_size);
            if (wrong != 0) {
                _ = Printf(dl, "%s: %u of the files differ from what was written\n", .{ COMMAND_NAME, wrong });
                result = dos.RETURN_ERROR;
            } else {
                _ = dl.PutStr("every file read back as it was written\n");
            }
        }
    }
    if (run.keep) return result;

    // Deleted, the drawer last.
    run.spent = 0;
    count = 0;
    var left: u32 = 0;
    while (count < made_count) : (count += 1) {
        var path: [dos.path_max + 1:0]u8 = undefined;
        nameOf(&path, &base, count);
        if (!run.timed(DosBase.DeleteFile, .{ dl, &path })) left += 1;
    }
    if (!run.timed(DosBase.DeleteFile, .{ dl, &base })) left += 1;
    if (left != 0) {
        _ = Printf(dl, "%s: %u of what was made could not be deleted\n", .{ COMMAND_NAME, left });
        return dos.RETURN_ERROR;
    }
    if (made_count == files) perFile(run, "deleted", files, 0);
    return result;
}

fn perFile(run: *Run, what: [*:0]const u8, files: u32, file_size: u32) void {
    const took = @max(run.spent, 1);
    const per_second = @as(u64, files) * 1_000_000 / took;
    _ = Printf(run.dl, "%u files %s in %lu ms, %lu a second", .{ files, what, took / 1000, per_second });
    if (file_size != 0) {
        const kib_s = @as(u64, files) * file_size * 1_000_000 / took / 1024;
        _ = Printf(run.dl, ", %lu KiB/s", .{kib_s});
    }
    _ = run.dl.PutStr("\n");
}

/// `base/f00042`.
fn nameOf(into: *[dos.path_max + 1:0]u8, base: [*:0]const u8, index: u32) void {
    const head = std.mem.span(base);
    @memcpy(into[0..head.len], head);
    into[head.len] = '/';
    into[head.len + 1] = 'f';
    var digits: [5]u8 = undefined;
    var value = index;
    for (0..digits.len) |at| {
        digits[digits.len - 1 - at] = '0' + @as(u8, @intCast(value % 10));
        value /= 10;
    }
    @memcpy(into[head.len + 2 ..][0..digits.len], &digits);
    into[head.len + 2 + digits.len] = 0;
}

// --- the rest -----------------------------------------------------------------------------

/// `drawer` and `name` as one path: a slash between them unless the
/// drawer ends in a colon or one. False when it does not fit.
fn join(into: *[dos.path_max + 1:0]u8, drawer: []const u8, name: []const u8) bool {
    const slash = drawer.len != 0 and drawer[drawer.len - 1] != ':' and drawer[drawer.len - 1] != '/';
    const length = drawer.len + @intFromBool(slash) + name.len;
    // Room for nameOf's "/f00000" too.
    if (length + 7 > dos.path_max) return false;
    @memcpy(into[0..drawer.len], drawer);
    if (slash) into[drawer.len] = '/';
    @memcpy(into[drawer.len + @intFromBool(slash) ..][0..name.len], name);
    into[length] = 0;
    return true;
}

fn number(arg: usize, default: u32) u32 {
    if (arg == 0) return default;
    return @bitCast(@as(*const i32, @ptrFromInt(arg)).*);
}

fn failed(run: *Run, what: [*:0]const u8, path: [*:0]const u8) i32 {
    const code = run.dl.IoErr();
    _ = Printf(run.dl, "%s: %s %s: ", .{ COMMAND_NAME, what, path });
    _ = run.dl.PrintFault(code, null);
    return dos.RETURN_ERROR;
}

fn failedAt(run: *Run, what: [*:0]const u8, path: [*:0]const u8, offset: u64) i32 {
    const code = run.dl.IoErr();
    _ = Printf(run.dl, "%s: %s of %s at byte %lu failed: ", .{ COMMAND_NAME, what, path, offset });
    _ = run.dl.PrintFault(code, null);
    if (!run.keep) _ = run.dl.DeleteFile(path);
    return dos.RETURN_ERROR;
}

fn tooLong(run: *Run) i32 {
    _ = Printf(run.dl, "%s: the drawer's name is too long\n", .{COMMAND_NAME});
    return dos.RETURN_ERROR;
}

/// The pattern written: each word its own offset in the file, mixed.
fn fill(bytes: []u8, offset: u64) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 8) std.mem.writeInt(u64, bytes[i..][0..8], pattern(offset + i), .little);
}

fn differs(bytes: []const u8, offset: u64) ?u64 {
    var i: usize = 0;
    while (i < bytes.len) : (i += 8) {
        if (std.mem.readInt(u64, bytes[i..][0..8], .little) != pattern(offset + i)) return offset + i;
    }
    return null;
}

fn pattern(offset: u64) u64 {
    return offset *% 0x9E37_79B9_7F4A_7C15 ^ 0x5A5A_5A5A_5A5A_5A5A;
}

/// The E-clock in microseconds.
fn eclock(timer_base: *TimerBase) u64 {
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = value.toTicks();
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}
