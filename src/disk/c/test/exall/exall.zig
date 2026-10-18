// SPDX-License-Identifier: MIT
//! ExAll: lists a directory with ExAll and with ExNext and checks that
//! the two agree, each step printed with PASS or FAIL. Built against the
//! SDK only.
//!
//!   ExAll DIR/A,PATTERN/K
//!
//! DIR is listed with ExNext first, then with ExAll in a small buffer, so
//! that it takes several calls: the same entries must come, with the same
//! names, types and sizes, in the same order, and the listing must end
//! with ERROR_NO_MORE_ENTRIES. Then a buffer too small for one record
//! (ERROR_BUFFER_OVERFLOW), a listing through PATTERN (`#?.info` without
//! one) against what MatchPatternNoCase says of ExNext's names, one
//! stopped by ExAllEnd and done again whole, and one whose MatchFunc
//! takes nothing. It works the same whether the handler lists the
//! directory itself or leaves it to dos. RETURN_OK when every step
//! passed, RETURN_ERROR when one failed.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const Hook = sdk.utility.Hook;
const ExAllControl = dos.ExAllControl;
const ExAllData = dos.ExAllData;
const FileInfoBlock = dos.FileInfoBlock;
const FileLock = dos.FileLock;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "ExAll";
const VERSION_STRING = "\x00$VER: ExAll 1.0 (18.10.2026)\r\n";
export const version_tag: [VERSION_STRING.len:0]u8 linksection(".version") = VERSION_STRING.*;

const template = "DIR/A,PATTERN/K";
const arg_dir = 0;
const arg_pattern = 1;

const MSG_PASS = "PASS  %s\n";
const MSG_FAIL = "FAIL  %s (error %ld)\n";
const MSG_LISTED = "      %lu entries, %lu calls\n";
const MSG_RESULT = "%u of %u steps passed\n";

/// Small enough that a directory of a few entries takes several calls.
const small_buffer = 256;
const pattern_max = 256;

/// How the steps went.
const Tally = struct {
    dl: *DosBase,
    steps: u32 = 0,
    passed: u32 = 0,

    /// A step whose outcome is `ok`, with `code` the error to say if not.
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

/// What a listing gave: how many entries, in how many calls, and a sum
/// over their names, types and sizes that depends on their order.
const Listing = struct {
    entries: u32 = 0,
    calls: u32 = 0,
    sum: u32 = 0x811C_9DC5,
    /// IoErr when the listing ended.
    code: i32 = 0,

    fn add(listing: *Listing, name: [*:0]const u8, entry_type: i32, size: u64) void {
        var index: usize = 0;
        while (name[index] != 0) : (index += 1) listing.mix(name[index]);
        listing.mix(@truncate(@as(u32, @bitCast(entry_type))));
        listing.mix(@truncate(size));
        listing.mix(@truncate(size >> 32));
        listing.entries += 1;
    }

    fn mix(listing: *Listing, byte: u8) void {
        listing.sum = (listing.sum ^ byte) *% 0x0100_0193;
    }
};

/// The directory through ExNext; with a pattern, only the names it
/// matches.
fn byExNext(dl: *DosBase, ub: *UtilityBase, lock: *FileLock, fib: *FileInfoBlock, pattern: ?[*:0]const u8) Listing {
    var listing: Listing = .{};
    if (!dl.Examine(lock, fib)) {
        listing.code = dl.IoErr();
        return listing;
    }
    while (dl.ExNext(lock, fib)) {
        const name: [*:0]const u8 = @ptrCast(&fib.file_name);
        if (pattern) |parsed| {
            if (!ub.MatchPatternNoCase(parsed, name)) continue;
        }
        listing.add(name, fib.dir_entry_type, fib.size);
    }
    listing.code = dl.IoErr();
    return listing;
}

/// The directory through ExAll in `buffer`, every record of each call
/// summed. Stops after `stop_after` calls when that is not 0, without
/// ending the listing.
fn byExAll(dl: *DosBase, lock: *FileLock, buffer: []u8, control: *ExAllControl, stop_after: u32) Listing {
    var listing: Listing = .{};
    while (true) {
        const more = dl.ExAll(lock, buffer.ptr, @intCast(buffer.len), dos.ED_SIZE, control);
        listing.calls += 1;
        var rec: ?*ExAllData = if (control.entries != 0) @ptrCast(@alignCast(buffer.ptr)) else null;
        while (rec) |it| : (rec = it.next) listing.add(it.name.?, it.type, it.size);
        if (!more) {
            listing.code = dl.IoErr();
            return listing;
        }
        if (stop_after != 0 and listing.calls == stop_after) return listing;
    }
}

/// A MatchFunc that takes no entry.
fn takeNothing(_: *Hook, _: ?*anyopaque, _: ?*anyopaque) callconv(.c) usize {
    return 0;
}

export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    const dos_lib = sys.OpenLibrary(dos.DOSNAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(dos_lib);
    const dl: *DosBase = @ptrCast(dos_lib);
    const utility_lib = sys.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return dos.RETURN_FAIL;
    defer sys.CloseLibrary(utility_lib);
    const ub: *UtilityBase = @ptrCast(utility_lib);

    var argv: [2]usize = @splat(0);
    const rda = dl.ReadArgs(template, &argv, null) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.FreeArgs(rda);
    const dir: [*:0]const u8 = @ptrFromInt(argv[arg_dir]);
    const pattern: [*:0]const u8 = if (argv[arg_pattern] != 0) @ptrFromInt(argv[arg_pattern]) else "#?.info";

    const lock = dl.Lock(dir, dos.SHARED_LOCK) orelse {
        _ = dl.PrintFault(dl.IoErr(), COMMAND_NAME);
        return dos.RETURN_FAIL;
    };
    defer dl.UnLock(lock);
    const fib: *FileInfoBlock = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_FIB, null) orelse return dos.RETURN_FAIL));
    defer dl.FreeDosObject(dos.DOS_FIB, fib);
    const control: *ExAllControl = @ptrCast(@alignCast(dl.AllocDosObject(dos.DOS_EXALLCONTROL, null) orelse return dos.RETURN_FAIL));
    defer dl.FreeDosObject(dos.DOS_EXALLCONTROL, control);
    const memory = sys.AllocVec(small_buffer + pattern_max, exec.MEMF_ANY) orelse return dos.RETURN_FAIL;
    defer sys.FreeVec(memory);
    const bytes: [*]u8 = @ptrCast(memory);
    const buffer = bytes[0..small_buffer];
    const parsed: [*]u8 = bytes + small_buffer;
    var tally: Tally = .{ .dl = dl };

    // The whole directory, both ways.
    const listed = byExNext(dl, ub, lock, fib, null);
    tally.say("ExNext lists the directory", listed.code == dos.ERROR_NO_MORE_ENTRIES, listed.code);
    const all = byExAll(dl, lock, buffer, control, 0);
    _ = Printf(dl, MSG_LISTED, .{ @as(u64, all.entries), @as(u64, all.calls) });
    tally.say("ExAll ends with ERROR_NO_MORE_ENTRIES", all.code == dos.ERROR_NO_MORE_ENTRIES, all.code);
    tally.say("as many entries as ExNext", all.entries == listed.entries, 0);
    tally.say("the same names, types and sizes, in the same order", all.sum == listed.sum, 0);

    // A buffer the fields alone fill.
    const overflow = dl.ExAll(lock, buffer.ptr, @sizeOf(usize) * 2, dos.ED_NAME, control);
    const overflow_code = dl.IoErr();
    tally.say("a buffer too small: ERROR_BUFFER_OVERFLOW", !overflow and (listed.entries == 0 or overflow_code == dos.ERROR_BUFFER_OVERFLOW), overflow_code);

    // Through a pattern.
    if (ub.ParsePatternNoCase(pattern, parsed, pattern_max) < 0) {
        tally.say("the pattern parses", false, dos.ERROR_BAD_TEMPLATE);
    } else {
        const matched = byExNext(dl, ub, lock, fib, @ptrCast(parsed));
        control.match_string = @ptrCast(parsed);
        const through = byExAll(dl, lock, buffer, control, 0);
        control.match_string = null;
        tally.say("the pattern: the names MatchPatternNoCase takes", through.entries == matched.entries and through.sum == matched.sum, through.code);
    }

    // Stopped after one call, then again from the start.
    const stopped = byExAll(dl, lock, buffer, control, 1);
    if (stopped.code == 0) dl.ExAllEnd(lock, buffer.ptr, @intCast(buffer.len), dos.ED_SIZE, control);
    tally.say("ExAllEnd starts the next listing afresh", control.last_key == 0, 0);
    const again = byExAll(dl, lock, buffer, control, 0);
    tally.say("and that one is whole", again.entries == listed.entries and again.sum == listed.sum, again.code);

    // A hook that takes nothing.
    var nothing: Hook = .{ .entry = &takeNothing };
    control.match_func = &nothing;
    const none = byExAll(dl, lock, buffer, control, 0);
    control.match_func = null;
    tally.say("a MatchFunc that takes nothing: no entry, and the end", none.entries == 0 and none.code == dos.ERROR_NO_MORE_ENTRIES, none.code);

    _ = Printf(dl, MSG_RESULT, .{ tally.passed, tally.steps });
    return if (tally.passed == tally.steps) dos.RETURN_OK else dos.RETURN_ERROR;
}
