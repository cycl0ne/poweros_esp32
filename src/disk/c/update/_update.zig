// SPDX-License-Identifier: MIT
//! What Update's pieces share: the run, the source it reads a package
//! from, and the few helpers each of its files wants.

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const http = sdk.http;
const install = sdk.install;
const prefs = sdk.prefs;
const posfs = dos.posfs;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const HttpBase = sdk.interface.http.HttpBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const Printf = dos.stdio.Printf;

pub const COMMAND_NAME = "Update";

/// Where a package is read from: a path on a volume, or an address.
pub const Kind = enum { path, address };

/// How much is read and written at a time.
pub const buffer_bytes: usize = 64 * 1024;

/// The longest name this builds: a path in a manifest under a volume's
/// name, or under an address.
pub const max_path = install.manifest.max_path + 256;

/// Where a file is written while it is fetched, on the volume it belongs
/// to so that the last step is a rename and not a copy.
pub const part_file = "SYS:System/update.part";

/// The snapshot the system volume is given before the first file is
/// written, where it is a volume that keeps them: what a system that
/// comes up and is wrong is put back to. There is one of it, since a
/// volume is only ever put back to its newest snapshot, and it is made
/// again each time.
pub const snapshot_name = "before-update";

/// One run of the command.
pub const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    /// LIBS:http.library and its socket base, opened only for an
    /// address.
    hb: ?*HttpBase = null,
    sb: ?*SocketBase = null,
    client: ?*http.Client = null,
    /// What FROM said, or what the machine was installed from.
    from: [*:0]const u8 = "",
    kind: Kind = .path,
    check: bool = false,
    force: bool = false,
    quiet: bool = false,
    /// The piece files are read and written in.
    buffer: []u8 = &.{},
    /// What the package holds, from its list's first line.
    files: u32 = 0,
    bytes: u64 = 0,
    /// What the install left: where this system came from, which board
    /// it was built for, and which partition its firmware reads.
    installed: ?*const prefs.install.Settings = null,
    /// Whether the files the firmware reads are to be written too.
    want_boot: bool = false,
    /// Whether the machine is started again at the end.
    restart: bool = false,
    /// Whether this is the run the machine makes by itself.
    auto: bool = false,
    /// What this run came to.
    written: u32 = 0,
    written_bytes: u64 = 0,
    deleted: u32 = 0,
    kept: u32 = 0,
    made: u32 = 0,
    /// What the firmware reads: how many the package holds, and how many
    /// were written into its partition.
    boot: u32 = 0,
    boot_written: u32 = 0,
    /// The partition the firmware was told to try at the next start, 0
    /// where none was.
    tried: u32 = 0,
    /// Whether the system volume has been given its snapshot.
    snapshotted: bool = false,

    /// What a run came to, cleared: AUTO looks first and writes after,
    /// and the second walk counts for itself.
    pub fn again(run: *Run) void {
        run.written = 0;
        run.written_bytes = 0;
        run.deleted = 0;
        run.kept = 0;
        run.made = 0;
        run.boot = 0;
        run.boot_written = 0;
        run.tried = 0;
        run.snapshotted = false;
    }
};

/// The system volume given its snapshot, once in a run and before the
/// first file is written. A volume that keeps no snapshots - the flash
/// file system, FAT - says so and nothing is lost by it: there was
/// nothing to put back to.
pub fn snapshot(run: *Run) void {
    if (run.snapshotted or run.check) return;
    run.snapshotted = true;
    const dl = run.dl;
    const dp = dl.GetDeviceProc("SYS:", null) orelse return;
    defer dl.FreeDeviceProc(dp);
    const port = dp.port orelse return;
    var info: dos.InfoData = .{};
    const disk_info = @intFromEnum(dos.ActionCode.disk_info);
    if (dl.DoPkt(port, disk_info, @bitCast(@intFromPtr(&info)), 0, 0, 0, 0) == dos.DOSFALSE) return;
    if (info.disk_type != posfs.ID_POSFS_DISK) return;
    // The one from the update before this is what it replaces.
    var args: posfs.packets.SnapshotArgs = .{ .name = snapshot_name };
    _ = dl.DoPkt(port, posfs.packets.ACTION_POSFS_DELETE_SNAPSHOT, @bitCast(@intFromPtr(&args)), 0, 0, 0, 0);
    if (dl.DoPkt(port, posfs.packets.ACTION_POSFS_MAKE_SNAPSHOT, @bitCast(@intFromPtr(&args)), 0, 0, 0, 0) == dos.DOSFALSE) {
        _ = Printf(dl, "%s: %s has no snapshot %s to go back to\n", .{ COMMAND_NAME, "SYS:", snapshot_name });
        return;
    }
    say(run, "  %-7s %s\n", .{ "back to", "SYS: before this, as the snapshot " ++ snapshot_name });
}

/// A line said unless QUIET.
pub fn say(run: *Run, comptime format: [:0]const u8, args: anytype) void {
    if (run.quiet) return;
    _ = Printf(run.dl, format, args);
}

/// A line always said, and the output flushed.
pub fn tell(run: *Run, comptime format: [:0]const u8, args: anytype) void {
    _ = Printf(run.dl, format, args);
    _ = run.dl.Flush(run.dl.Output());
}

/// What went wrong, with the command's name in front of it, and the code
/// a failed update answers.
pub fn fail(run: *Run, comptime format: [:0]const u8, args: anytype) i32 {
    _ = run.dl.PutStr(COMMAND_NAME ++ ": ");
    _ = Printf(run.dl, format, args);
    return dos.RETURN_FAIL;
}

/// What dos said went wrong, and the same code.
pub fn failed(run: *Run, what: [*:0]const u8, code: i32) i32 {
    _ = run.dl.PrintFault(code, what);
    return dos.RETURN_FAIL;
}

/// Whether Ctrl-C was typed; it is said once where it was.
pub fn stopped(run: *Run) bool {
    if (run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
    _ = run.dl.PrintFault(dos.ERROR_BREAK, null);
    return true;
}

/// `from` into `into`: how many bytes.
pub fn copy(into: []u8, from: []const u8) usize {
    const room = @min(into.len, from.len);
    @memcpy(into[0..room], from[0..room]);
    return room;
}

/// How long a NUL-terminated string is.
pub fn length(text: [*:0]const u8) usize {
    var at: usize = 0;
    while (text[at] != 0) at += 1;
    return at;
}

/// `value` as digits into `into`: how many bytes.
pub fn decimal(into: []u8, value: u64) usize {
    if (value == 0) {
        if (into.len != 0) into[0] = '0';
        return 1;
    }
    var digits: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (left != 0) : (left /= 10) {
        digits[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
    }
    var at: usize = 0;
    while (at < count and at < into.len) : (at += 1) into[at] = digits[count - 1 - at];
    return count;
}

/// `bytes` as a short, round number of them, NUL-terminated in `into`
/// (16 bytes are enough): 1K, 18.8M, 2G.
pub fn bytesAsText(into: *[16:0]u8, bytes: u64) void {
    const names = [_][]const u8{ "", "K", "M", "G", "T" };
    var size = bytes;
    var tenths: u64 = 0;
    var which: usize = 0;
    while (size >= 1024 and which + 1 < names.len) : (which += 1) {
        tenths = (size % 1024) * 10 / 1024;
        size /= 1024;
    }
    var at = decimal(into, size);
    if (which != 0 and size < 100 and tenths != 0) {
        into[at] = '.';
        at += 1;
        at += decimal(into[at..], tenths);
    }
    at += copy(into[at..], names[which]);
    into[at] = 0;
}

/// A path under a volume or an address, NUL-terminated: `root`, a
/// separator where one is wanted, and `rest`.
pub const Name = struct {
    text: [max_path:0]u8 = @splat(0),

    pub fn of(root: []const u8, rest: []const u8) Name {
        var name: Name = .{};
        var at = copy(&name.text, root);
        if (at != 0 and rest.len != 0) {
            const last = name.text[at - 1];
            if (last != '/' and last != ':') {
                name.text[at] = '/';
                at += 1;
            }
        }
        at += copy(name.text[at..], rest);
        name.text[at] = 0;
        return name;
    }

    pub fn cstr(name: *const Name) [*:0]const u8 {
        return @ptrCast(&name.text);
    }
};

/// Memory that grows, for a list of paths this keeps to the end.
pub const Buffer = struct {
    sys: *ExecBase,
    bytes: []u8 = &.{},
    at: usize = 0,

    pub fn room(buffer: *Buffer, more: usize) bool {
        if (buffer.at + more <= buffer.bytes.len) return true;
        var want = if (buffer.bytes.len == 0) 4096 else buffer.bytes.len;
        while (want < buffer.at + more) want *= 2;
        const got = buffer.sys.AllocVec(@intCast(want), exec.MEMF_ANY) orelse return false;
        const fresh: [*]u8 = @ptrCast(got);
        @memcpy(fresh[0..buffer.at], buffer.bytes[0..buffer.at]);
        if (buffer.bytes.len != 0) buffer.sys.FreeVec(@ptrCast(buffer.bytes.ptr));
        buffer.bytes = fresh[0..want];
        return true;
    }

    pub fn add(buffer: *Buffer, from: []const u8) bool {
        if (!buffer.room(from.len)) return false;
        @memcpy(buffer.bytes[buffer.at..][0..from.len], from);
        buffer.at += from.len;
        return true;
    }

    pub fn free(buffer: *Buffer) void {
        if (buffer.bytes.len != 0) buffer.sys.FreeVec(@ptrCast(buffer.bytes.ptr));
        buffer.bytes = &.{};
        buffer.at = 0;
    }
};
