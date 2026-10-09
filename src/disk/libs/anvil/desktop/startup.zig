// SPDX-License-Identifier: MIT
//! The drawer of programs started with the desktop: `SYS:WBStartup`.
//!
//! **Which, in what order**: every icon in it that is a program or a
//! document, started as a double click on it starts it - a document by
//! its default tool - in the order of its `STARTPRI` tool type, highest
//! first (-128 to 127, 0 for none), and among equals as the drawer lists
//! them.
//!
//! **Waiting**: each is waited for to end before the next starts - up to
//! its `WAIT` tool type's seconds (5 for none), and not at all with
//! `DONOTWAIT`. One that has not ended by then is asked about: wait some
//! more, or go on without it. The desktop answers meanwhile: the wait is
//! counted in its clock's ticks, and the next program is started from its
//! loop when the one before has ended or been given up on.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const icon = sdk.icon;
const intuition = sdk.intuition;
const _desktop = @import("_desktop.zig");
const Desktop = _desktop.Desktop;
const run = @import("run.zig");
const drawer_path = @import("../drawer/path.zig");

/// The drawer.
pub const drawer_name = "SYS:WBStartup";
/// The most icons in it that are started.
const entries_max = 32;
/// How long one is waited for without a `WAIT`, in seconds.
const default_wait = 5;

/// An icon to start: its name in the drawer, and what its tool types say.
pub const Entry = struct {
    name: [dos.name_max + 1]u8 = @splat(0),
    priority: i32 = 0,
    wait: u32 = default_wait,
    no_wait: bool = false,
};

/// The drawer as read, and how far along starting it is.
pub const Startup = struct {
    entries: [entries_max]Entry = undefined,
    count: usize = 0,
    next: usize = 0,
    /// The program waited for: its end message, the clock tick it is
    /// waited for until, and which entry it is.
    waiting: ?*run.Ended = null,
    until: u32 = 0,
    current: usize = 0,
};

/// An entry put in its place: after every one of the same or a higher
/// priority, so equals keep the drawer's order.
pub fn insert(startup: *Startup, entry: Entry) void {
    if (startup.count == entries_max) return;
    var at = startup.count;
    while (at > 0 and startup.entries[at - 1].priority < entry.priority) : (at -= 1) {
        startup.entries[at] = startup.entries[at - 1];
    }
    startup.entries[at] = entry;
    startup.count += 1;
}

/// The seconds a `WAIT` tool type gives, up to an hour; null for anything
/// that is not a number.
pub fn seconds(text: []const u8) ?u32 {
    if (text.len == 0 or text.len > 4) return null;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return @min(value, 3600);
}

/// The drawer read, and the first of its programs started. Nothing when
/// it is not there or holds nothing to start.
pub fn begin(d: *Desktop) void {
    const sys = d.sys;
    const dl = d.dl;
    const lock = dl.Lock(drawer_name, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const memory = sys.AllocVec(@sizeOf(Startup) + @sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR) orelse return;
    const startup: *Startup = @ptrCast(@alignCast(memory));
    startup.* = .{};
    const fib: *dos.FileInfoBlock = @ptrCast(@alignCast(@as([*]u8, @ptrCast(memory)) + @sizeOf(Startup)));
    if (dl.Examine(lock, fib)) {
        while (dl.ExNext(lock, fib)) {
            if (fib.dir_entry_type > 0) continue;
            const name = textOf(@ptrCast(&fib.file_name));
            if (name.len <= 5 or !endsInInfo(name)) continue;
            readEntry(d, startup, name[0 .. name.len - 5]);
        }
    }
    if (startup.count == 0) {
        sys.FreeVec(memory);
        return;
    }
    d.startup = startup;
    startNext(d);
}

fn endsInInfo(name: []const u8) bool {
    const tail = name[name.len - 5 ..];
    const wanted = ".info";
    for (tail, wanted) |c, w| {
        const low = if (c >= 'A' and c <= 'Z') c + 32 else c;
        if (low != w) return false;
    }
    return true;
}

/// An icon of the drawer read: kept when it is a program's or a
/// document's, with what its tool types say.
fn readEntry(d: *Desktop, startup: *Startup, name: []const u8) void {
    var full: [dos.path_max + 1:0]u8 = @splat(0);
    _ = drawer_path.join(&full, drawer_name, name) orelse return;
    const object = d.icon_base.GetDiskObject(&full) orelse return;
    defer d.icon_base.FreeDiskObject(object);
    if (object.kind != icon.WBTOOL and object.kind != icon.WBPROJECT) return;
    var entry = Entry{};
    @memcpy(entry.name[0..name.len], name);
    const types = object.tool_types;
    if (d.icon_base.FindToolType(types, "STARTPRI")) |value| {
        if (run.decimal(textOf(value))) |priority| entry.priority = @intCast(priority);
    }
    if (d.icon_base.FindToolType(types, "WAIT")) |value| {
        if (seconds(textOf(value))) |wait| entry.wait = wait;
    }
    entry.no_wait = d.icon_base.FindToolType(types, "DONOTWAIT") != null;
    insert(startup, entry);
}

/// The next program started, and the ones after it that are not waited
/// for; the drawer let go of once the last has started.
fn startNext(d: *Desktop) void {
    const startup = d.startup orelse return;
    while (startup.next < startup.count) {
        const at = startup.next;
        startup.next += 1;
        const entry = &startup.entries[at];
        var full: [dos.path_max + 1:0]u8 = @splat(0);
        _ = drawer_path.join(&full, drawer_name, textOf(@ptrCast(&entry.name))) orelse continue;
        const object = d.icon_base.GetDiskObject(&full) orelse continue;
        const started = run.runFile(d, &full, object);
        d.icon_base.FreeDiskObject(object);
        const message = started orelse continue;
        if (entry.no_wait) continue;
        startup.waiting = message;
        startup.current = at;
        startup.until = d.ticks + ticksOf(entry.wait);
        return;
    }
    finish(d);
}

/// Seconds as the clock's ticks, at least one.
fn ticksOf(wait: u32) u32 {
    return @max(1, (wait + _desktop.tick_seconds - 1) / _desktop.tick_seconds);
}

/// A program the desktop started has ended: the next started when it was
/// the one waited for.
pub fn ended(d: *Desktop, message: *run.Ended) void {
    const startup = d.startup orelse return;
    if (startup.waiting != message) return;
    startup.waiting = null;
    startNext(d);
}

/// The clock ticked: a program waited for past its time is asked about.
pub fn tick(d: *Desktop) void {
    const startup = d.startup orelse return;
    if (startup.waiting == null or d.ticks < startup.until) return;
    const entry = &startup.entries[startup.current];
    const easy = intuition.requesters.EasyStruct{
        .title = "Anvil",
        .text_format = "Program '%s'\nhas not yet ended.\nWait some more?",
        .gadget_format = "Wait|Go On",
    };
    const args = [_]usize{@intFromPtr(&entry.name)};
    if (d.ib.EasyRequestArgs(d.backdrop, &easy, null, &args) == 1) {
        startup.until = d.ticks + ticksOf(entry.wait);
        return;
    }
    startup.waiting = null;
    startNext(d);
}

/// The drawer let go of: all of it started, or the desktop ending.
pub fn finish(d: *Desktop) void {
    const startup = d.startup orelse return;
    d.startup = null;
    d.sys.FreeVec(startup);
}

fn textOf(text: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (text[length] != 0) length += 1;
    return text[0..length];
}
