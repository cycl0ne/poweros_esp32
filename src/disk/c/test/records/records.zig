// SPDX-License-Identifier: MIT
//! Records: record locks (LockRecord, LockRecords, UnLockRecord,
//! UnLockRecords) tried on a file, each step printed with PASS or FAIL.
//! Built against the SDK only.
//!
//!   Records FILE/A
//!
//! FILE is made and opened through two handles, and ranges of it are
//! locked through both: exclusive and shared, a handle's own range again,
//! a lock that does not wait, one whose time runs out, one that waits
//! for a helper process to free the bytes and one that waits for it to
//! close its handle, an array locked whole or not at all, ranges past
//! 4 GiB, and a handle's locks given back when it is closed. FILE is
//! deleted at the end. RETURN_OK when every step passed, RETURN_ERROR
//! when one failed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const record = dos.record;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const FileHandle = dos.FileHandle;
const TagItem = sdk.utility.TagItem;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Records";
const VERSION_STRING = "\x00$VER: Records 1.0 (17.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "FILE/A";
const arg_file = 0;

const MSG_PASS = "PASS  %s\n";
const MSG_FAIL = "FAIL  %s (error %ld)\n";
const MSG_WAITED = "      waited %lu ticks\n";
const MSG_RESULT = "%u of %u steps passed\n";

/// 4 GiB: where a 32-bit offset would wrap.
const far: u64 = 0x1_0000_0000;

/// A DateStamp's minute in ticks of 1/50 s.
const ticks_per_minute = 60 * 50;

/// How the steps went.
const Tally = struct {
    dl: *DosBase,
    steps: u32 = 0,
    passed: u32 = 0,

    /// A step that should succeed.
    fn expect(tally: *Tally, name: [*:0]const u8, ok: bool) void {
        tally.say(name, ok, if (ok) 0 else tally.dl.IoErr());
    }

    /// A step that should fail with `code`.
    fn refused(tally: *Tally, name: [*:0]const u8, ok: bool, code: i32) void {
        const got: i32 = if (ok) 0 else tally.dl.IoErr();
        tally.say(name, got == code, got);
    }

    fn say(tally: *Tally, name: [*:0]const u8, ok: bool, code: i32) void {
        tally.steps += 1;
        if (ok) {
            tally.passed += 1;
            _ = Printf(tally.dl, MSG_PASS, .{name});
        } else {
            _ = Printf(tally.dl, MSG_FAIL, .{ name, @as(i64, code) });
        }
        _ = tally.dl.Flush(tally.dl.Output());
    }
};

/// What the helper process does after its delay: give back a range of
/// the handle's, or close the handle.
const Job = struct {
    fh: *FileHandle,
    delay: u32,
    close: bool = false,
    offset: u64 = 0,
    length: u64 = 0,
};

/// The helper process: its job, a while after it starts.
fn helperEntry(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const job: *Job = @ptrCast(@alignCast(me.user_data.?));
    const lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return;
    defer sys.CloseLibrary(lib);
    const dl: *DosBase = @ptrCast(lib);
    dl.Delay(job.delay);
    if (job.close) {
        _ = dl.Close(job.fh);
    } else {
        _ = dl.UnLockRecord(job.fh, job.offset, job.length);
    }
}

/// The helper started on `job`; `ended` comes back to `port` once it has
/// gone.
fn startHelper(dl: *DosBase, job: *Job, ended: *exec.Message, port: *exec.MsgPort) bool {
    ended.* = .{ .reply_port = port };
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&helperEntry) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("Records helper") },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(job) },
        .{ .tag = dos.NP_StackSize, .data = 8192 },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(ended) },
        .{},
    };
    return dl.CreateNewProc(&tags) != null;
}

/// The time now, in ticks.
fn now(dl: *DosBase) u64 {
    var stamp: dos.DateStamp = .{};
    _ = dl.DateStamp(&stamp);
    const minutes: u64 = @as(u64, @intCast(stamp.days)) * 1440 + @as(u64, @intCast(stamp.minute));
    return minutes * ticks_per_minute + @as(u64, @intCast(stamp.tick));
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);

    var argv: [1]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const name: [*:0]const u8 = @ptrFromInt(argv[arg_file]);

    const made = dl.Open(name, dos.MODE_NEWFILE) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    _ = dl.Write(made, "records", 7);
    _ = dl.Close(made);
    defer _ = dl.DeleteFile(name);
    var one = dl.Open(name, dos.MODE_READWRITE) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    var two = dl.Open(name, dos.MODE_READWRITE) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        _ = dl.Close(one);
        return dos.RETURN_FAIL;
    };
    const port = sys.CreateMsgPort() orelse {
        _ = dl.Close(one);
        _ = dl.Close(two);
        return dos.RETURN_FAIL;
    };
    defer sys.DeleteMsgPort(port);
    var tally: Tally = .{ .dl = dl };

    // Exclusive and shared; a handle never stands in its own way.
    tally.expect("exclusive [0, 100)", dl.LockRecord(one, 0, 100, record.REC_EXCLUSIVE, 0));
    tally.expect("shared [10, 20) through the same handle", dl.LockRecord(one, 10, 10, record.REC_SHARED, 0));
    tally.refused("shared, not waiting, through the other", dl.LockRecord(two, 50, 10, record.REC_SHARED_IMMED, 0), dos.ERROR_LOCK_COLLISION);
    tally.refused("exclusive, no time to wait", dl.LockRecord(two, 50, 10, record.REC_EXCLUSIVE, 0), dos.ERROR_LOCK_TIMEOUT);
    tally.expect("exclusive [100, 110), next to it", dl.LockRecord(two, 100, 10, record.REC_EXCLUSIVE_IMMED, 0));

    // A wait whose time runs out.
    var start = now(dl);
    tally.refused("exclusive, 10 ticks to wait", dl.LockRecord(two, 50, 10, record.REC_EXCLUSIVE, 10), dos.ERROR_LOCK_TIMEOUT);
    var waited = now(dl) - start;
    _ = Printf(dl, MSG_WAITED, .{waited});
    tally.expect("waited its time", waited >= 9);

    // Given back by the same offset and length only.
    tally.refused("unlock [0, 99)", dl.UnLockRecord(one, 0, 99), dos.ERROR_RECORD_NOT_LOCKED);
    tally.refused("unlock through the other handle", dl.UnLockRecord(two, 0, 100), dos.ERROR_RECORD_NOT_LOCKED);
    tally.expect("unlock [10, 20)", dl.UnLockRecord(one, 10, 10));

    // A wait the helper ends by freeing the bytes.
    var ended: exec.Message = .{};
    var free_job: Job = .{ .fh = one, .delay = 25, .offset = 0, .length = 100 };
    if (startHelper(dl, &free_job, &ended, port)) {
        start = now(dl);
        tally.expect("exclusive, waiting for the bytes", dl.LockRecord(two, 50, 10, record.REC_EXCLUSIVE, 500));
        waited = now(dl) - start;
        _ = Printf(dl, MSG_WAITED, .{waited});
        tally.expect("had them when they were freed", waited >= 20 and waited < 500);
        _ = sys.WaitPort(port);
        _ = sys.GetMsg(port);
    } else tally.expect("helper process", false);

    // A wait the helper ends by closing its handle.
    var close_job: Job = .{ .fh = two, .delay = 25, .close = true };
    if (startHelper(dl, &close_job, &ended, port)) {
        start = now(dl);
        tally.expect("shared, waiting for a handle to close", dl.LockRecord(one, 55, 1, record.REC_SHARED, 500));
        waited = now(dl) - start;
        _ = Printf(dl, MSG_WAITED, .{waited});
        tally.expect("had them when it closed", waited >= 20 and waited < 500);
        _ = sys.WaitPort(port);
        _ = sys.GetMsg(port);
    } else tally.expect("helper process", false);
    two = dl.Open(name, dos.MODE_READWRITE) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        _ = dl.Close(one);
        return dos.RETURN_FAIL;
    };
    tally.expect("unlock [55, 56)", dl.UnLockRecord(one, 55, 1));

    // An array: whole, or none of it.
    const first = [_]record.RecordLock{
        .{ .fh = one, .offset = 200, .length = 10 },
        .{ .fh = one, .offset = 300, .length = 10 },
        .{},
    };
    const second = [_]record.RecordLock{
        .{ .fh = two, .offset = 400, .length = 10 },
        .{ .fh = two, .offset = 300, .length = 10 },
        .{},
    };
    tally.expect("an array of two", dl.LockRecords(&first, 0));
    tally.refused("an array whose second is held", dl.LockRecords(&second, 0), dos.ERROR_LOCK_TIMEOUT);
    tally.expect("its first given back", dl.LockRecord(one, 400, 1, record.REC_EXCLUSIVE_IMMED, 0));
    tally.expect("unlock the array", dl.UnLockRecords(&first));
    tally.expect("unlock [400, 401)", dl.UnLockRecord(one, 400, 1));

    // Past 4 GiB: offsets kept whole.
    tally.expect("exclusive at 4 GiB", dl.LockRecord(one, far, 10, record.REC_EXCLUSIVE, 0));
    tally.refused("shared inside it", dl.LockRecord(two, far + 9, 1, record.REC_SHARED_IMMED, 0), dos.ERROR_LOCK_COLLISION);
    tally.expect("exclusive at 0, not at 4 GiB", dl.LockRecord(two, 0, 10, record.REC_EXCLUSIVE_IMMED, 0));
    tally.expect("exclusive just below 4 GiB", dl.LockRecord(two, far - 1, 1, record.REC_EXCLUSIVE_IMMED, 0));

    // Closing a handle gives back what it holds.
    _ = dl.Close(one);
    one = undefined;
    tally.expect("its range, once the handle closed", dl.LockRecord(two, far, 10, record.REC_EXCLUSIVE_IMMED, 0));
    _ = dl.Close(two);

    _ = Printf(dl, MSG_RESULT, .{ tally.passed, tally.steps });
    return if (tally.passed == tally.steps) dos.RETURN_OK else dos.RETURN_ERROR;
}
