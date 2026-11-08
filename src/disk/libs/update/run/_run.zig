// SPDX-License-Identifier: MIT
//! A run of the update - what CreateUpdate makes and the other calls are
//! handed - and what every part of a run shares: where what it says goes,
//! the snapshot the system volume is given, and the names it builds.
//!
//! **What a run says** goes to the caller's output - a line of prose, or
//! a line for each path saying first what happens to it (`row`) - unless
//! the run was given a hook (`UPD_Hook`): then each line is formatted and
//! handed to it as an `UpdateMessage`, each path with what happens to it
//! and the bytes written for it, and each file once it is in place
//! (`wrote`). `UPD_Quiet` quiets only the output, never a failure.
//!
//! **A run belongs to the task that made it.** It reads and writes on
//! that task's process - dos's packets, the output, the network libraries
//! it opened there - and checks it for Ctrl-C between files (`stopped`).

const sdk = @import("sdk");
const dos = sdk.dos;
const exec = sdk.exec;
const http = sdk.http;
const install = sdk.install;
const prefs = sdk.prefs;
const update = sdk.update;
const utility = sdk.utility;
const posfs = dos.posfs;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const HttpBase = sdk.interface.http.HttpBase;
const SocketBase = sdk.interface.bsdsocket.SocketBase;
const UpdateBase = @import("../update_base.zig").UpdateBase;
const Printf = dos.stdio.Printf;

/// What a failure said on the output starts with.
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

/// One run of the update.
pub const Run = struct {
    sys: *ExecBase,
    dl: *DosBase,
    ub: *UtilityBase,
    /// Where what the run says goes instead of the output, and the object
    /// it is handed with each message: the run for CreateUpdate's, null
    /// for ConfirmUpdate's.
    hook: ?*utility.Hook = null,
    object: ?*anyopaque = null,
    /// LIBS:http.library and its socket base, opened only for an
    /// address.
    hb: ?*HttpBase = null,
    sb: ?*SocketBase = null,
    client: ?*http.Client = null,
    /// The package: a path or an address, kept in `from_text`.
    from: [*:0]const u8 = "",
    from_text: [max_path + 1:0]u8 = @splat(0),
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
    settings: prefs.install.Settings = .{},
    /// Whether the files the firmware reads are to be written too.
    want_boot: bool = false,
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

    /// What a run came to, cleared: each DoUpdate counts for itself.
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

/// A run made for `base`'s caller: the hook and the quiet `tags` give,
/// and what the install left in `ENVARC:Sys/install.prefs` read into it.
/// Null where there is no memory for it (`IoErr` ERROR_NO_FREE_STORE,
/// nothing said), or where that file is not a line of settings (said);
/// freed with `free`.
pub fn make(base: *UpdateBase, tags: ?[*]const utility.TagItem) ?*Run {
    const sys = base.sys_base;
    const dl = base.dos_base;
    const ub = base.utility_base;
    const memory = sys.AllocVec(@sizeOf(Run), exec.MEMF_ANY) orelse {
        _ = dl.SetIoErr(dos.ERROR_NO_FREE_STORE);
        return null;
    };
    const run: *Run = @ptrCast(@alignCast(memory));
    run.* = .{
        .sys = sys,
        .dl = dl,
        .ub = ub,
        .hook = @ptrFromInt(ub.GetTagData(update.UPD_Hook, 0, tags)),
        .quiet = ub.GetTagData(update.UPD_Quiet, 0, tags) != 0,
    };
    const text = prefs.loadWhole(sys, dl, prefs.install.ENVARC_FILE) orelse return run;
    defer sys.FreeVec(@ptrCast(text.ptr));
    const line = prefs.firstLine(text) orelse return run;
    if (prefs.install.parse(ub, line, &run.settings)) |wrong| {
        _ = fail(run, "%s: %s\n", .{ prefs.install.ENVARC_FILE, wrong });
        free(run);
        return null;
    }
    return run;
}

/// A run `make` made let go, with what it opened to read a package.
pub fn free(run: *Run) void {
    const sys = run.sys;
    if (run.hb) |hb| {
        hb.DeleteClient(run.client);
        sys.CloseLibrary(@ptrCast(@alignCast(hb)));
    }
    if (run.sb) |sb| sys.CloseLibrary(@ptrCast(@alignCast(sb)));
    if (run.buffer.len != 0) sys.FreeVec(@ptrCast(run.buffer.ptr));
    sys.FreeVec(run);
}

/// The run behind a handle the caller holds.
pub fn runOf(handle: *update.Update) *Run {
    return @ptrCast(@alignCast(handle));
}

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
        if (run.hook) |hook| {
            relay(run, hook, "%s has no snapshot %s to go back to\n", .{ "SYS:", snapshot_name }, false);
        } else _ = Printf(dl, "%s: %s has no snapshot %s to go back to\n", .{ COMMAND_NAME, "SYS:", snapshot_name });
        return;
    }
    row(run, "back to", "SYS: before this, as the snapshot " ++ snapshot_name, 0);
}

/// A line said unless QUIET.
pub fn say(run: *Run, comptime format: [:0]const u8, args: anytype) void {
    if (run.hook) |hook| return relay(run, hook, format, args, false);
    if (run.quiet) return;
    _ = Printf(run.dl, format, args);
}

/// What happens to the path `where`, said as a line with `what` first
/// unless QUIET; `bytes` is what is written for it, for a hook.
pub fn row(run: *Run, what: [*:0]const u8, where: [*:0]const u8, bytes: u64) void {
    if (run.hook) |hook| {
        var message: update.UpdateMessage = .{ .kind = update.UPDM_PATH, .text = where, .what = what, .bytes = bytes };
        _ = run.ub.CallHookPkt(hook, run.object, &message);
        return;
    }
    if (run.quiet) return;
    _ = Printf(run.dl, "  %-7s %s\n", .{ what, where });
}

/// The file `where`, `bytes` long, written whole and put in place: told
/// to a hook.
pub fn wrote(run: *Run, where: [*:0]const u8, bytes: u64) void {
    const hook = run.hook orelse return;
    var message: update.UpdateMessage = .{ .kind = update.UPDM_WROTE, .text = where, .bytes = bytes };
    _ = run.ub.CallHookPkt(hook, run.object, &message);
}

/// What went wrong, with "Update: " in front of it on the output, and the
/// code a failed run answers.
pub fn fail(run: *Run, comptime format: [:0]const u8, args: anytype) i32 {
    if (run.hook) |hook| {
        relay(run, hook, format, args, true);
        return dos.RETURN_FAIL;
    }
    _ = run.dl.PutStr(COMMAND_NAME ++ ": ");
    _ = Printf(run.dl, format, args);
    return dos.RETURN_FAIL;
}

/// What dos said went wrong, and the same code.
pub fn failed(run: *Run, what: [*:0]const u8, code: i32) i32 {
    fault(run, code, what, true);
    return dos.RETURN_FAIL;
}

/// What dos says `code` is, with `what` in front of it; `failure` when the
/// run ends with it.
pub fn fault(run: *Run, code: i32, what: ?[*:0]const u8, failure: bool) void {
    const hook = run.hook orelse {
        _ = run.dl.PrintFault(code, what);
        return;
    };
    var text: [line_room]u8 = undefined;
    const used = run.dl.Fault(code, what, &text, line_room);
    const end: usize = @intCast(@max(0, @min(used, line_room - 1)));
    text[end] = 0;
    var message: update.UpdateMessage = .{ .failed = @intFromBool(failure), .text = @ptrCast(&text) };
    _ = run.ub.CallHookPkt(hook, run.object, &message);
}

/// Whether Ctrl-C was sent to the run's task; it is said once where it
/// was.
pub fn stopped(run: *Run) bool {
    if (run.dl.CheckSignal(exec.SIGBREAKF_CTRL_C) == 0) return false;
    fault(run, dos.ERROR_BREAK, null, false);
    return true;
}

/// The most a line handed to a hook holds, its NUL included; a longer
/// one is cut.
const line_room = 1024;

/// A line formatted for a hook.
const Line = struct {
    text: [line_room]u8 = undefined,
    used: usize = 0,

    fn put(c: u8, data: ?*anyopaque) callconv(.c) void {
        const line: *Line = @ptrCast(@alignCast(data.?));
        if (c == 0 or line.used >= line_room - 1) return;
        line.text[line.used] = c;
        line.used += 1;
    }
};

/// `format` with `args` formatted as Printf would, its newlines at the
/// end left off, and handed to `hook` as a line.
fn relay(run: *Run, hook: *utility.Hook, comptime format: [:0]const u8, args: anytype, failure: bool) void {
    comptime exec.checkFormat(format, @TypeOf(args));
    const stream = exec.fmtStream(args);
    var line: Line = .{};
    _ = run.sys.RawDoFmt(format, &stream, &Line.put, &line);
    while (line.used > 0 and line.text[line.used - 1] == '\n') line.used -= 1;
    line.text[line.used] = 0;
    var message: update.UpdateMessage = .{ .failed = @intFromBool(failure), .text = @ptrCast(&line.text) };
    _ = run.ub.CallHookPkt(hook, run.object, &message);
}

/// `from` into `into`: how many bytes.
pub fn copy(into: []u8, from: []const u8) usize {
    const room = @min(into.len, from.len);
    @memcpy(into[0..room], from[0..room]);
    return room;
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
