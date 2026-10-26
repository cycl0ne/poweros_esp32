// SPDX-License-Identifier: MIT
//! The desktop's work on files - copying, deleting, emptying the trash -
//! each on a process of its own, so the desktop answers while it goes on.
//!
//! **A job** is the files picked and what to do with them. Its process
//! first walks them to count what there is - bytes for a copy, files for
//! a delete - then does it, with a window that says which file it is at
//! and how far along it is, and a Stop button that ends it between two
//! pieces. A copy's window says how fast it goes as well: the bytes of
//! the last second, measured on timer.device's E-clock, which a clock
//! set meanwhile does not move. A copy asks before it puts a file where one is already
//! (Replace, Replace All, Skip, Stop); a drawer that is there already is
//! copied into. A file's icon goes with it, and its protection, date and
//! comment are kept. A soft link in a drawer is never gone through: a
//! copy takes the file it names, a delete takes the link itself.
//!
//! **Its life**: StartAnvil's library code runs on it, so it holds the
//! library open (`NP_HoldLibrary`); the desktop counts it among what it
//! started, and the message the process is given (`NP_EndMsg`), which
//! dos replies to the desktop's port when the process is gone, is the
//! start of the job's own block - so the desktop frees the job with it.
//! The drawers it changed see the change through their notification.

const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const wn = intuition.windows;
const wc = intuition.windowclass;
const lg = intuition.layoutgclass;
const gc = intuition.gadgetclass;
const classusr = intuition.classusr;
const fg = sdk.gadgets.fuelgauge;
const tx = sdk.gadgets.text;
const timer = sdk.devices.timer;
const TagItem = utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const IconBase = sdk.interface.icon.IconBase;
const TimerBase = sdk.interface.timer.TimerBase;
const Object = intuition.Object;
const _base = @import("../anvil_base.zig");
const run = @import("run.zig");
const drawer_path = @import("../drawer/path.zig");
const Desktop = @import("_desktop.zig").Desktop;

/// Copying; deleting what was picked; deleting what is in a drawer - the
/// trash - and keeping the drawer.
pub const Kind = enum(u8) { copy, delete, empty };

/// The most files one job is given.
pub const sources_max = 16;
/// The buffer in the job's own block: what a copy reads at a time on the
/// ESP32s, and where memory for a larger one is short.
const chunk = 32768;
/// The most a copy reads at a time: a buffer of the largest file's size,
/// up to 1 MiB where memory is plenty, so a big file costs a read a MiB -
/// a network share answers a read in one round trip, and a disk writes
/// it in one go.
const chunk_most: u32 = if (sdk.hardware.chip == .rv64sbi or sdk.hardware.chip == .a64psci) 1 << 20 else chunk;
/// How deep a copy or a delete goes into drawers within drawers.
const depth_max = 24;
/// How long a copy's rate is measured over, in microseconds.
const rate_period_us = 1_000_000;

const ID_STOP = 1;

/// A job, in one block: the end message first, which the desktop frees
/// the block by. Extern, so that it stays first: Zig orders a plain
/// struct's fields as it likes.
pub const Job = extern struct {
    ended: run.Ended = .{},
    base: *_base.AnvilBase,
    kind: Kind,
    sources: [sources_max][dos.path_max + 1:0]u8 = undefined,
    count: usize = 0,
    /// Where a copy goes: a drawer; empty to copy each file in its own
    /// drawer, as a copy of itself.
    into: [dos.path_max + 1:0]u8 = @splat(0),

    // The process's own.
    sys: *ExecBase = undefined,
    dl: *DosBase = undefined,
    ib: ?*IntuitionBase = null,
    icon_base: ?*IconBase = null,
    libraries: [5]?*exec.Library = @splat(null),
    window_object: ?*Object = null,
    window: ?*intuition.Window = null,
    gauge: ?*Object = null,
    label: ?*Object = null,
    label_text: [64:0]u8 = @splat(0),
    /// A copy's rate, under the gauge.
    rate: ?*Object = null,
    rate_text: [24:0]u8 = @splat(0),
    /// The E-clock the rate is measured on; null without timer.device.
    clock: timer.TimeRequest = .{},
    timer_base: ?*TimerBase = null,
    /// Where the rate shown was measured from: the E-clock then, in
    /// microseconds, and the bytes copied by then.
    rate_since_us: u64 = 0,
    rate_since_done: u64 = 0,
    total: u64 = 0,
    done: u64 = 0,
    /// A copy's largest file, which the copy's buffer is sized by.
    largest: u64 = 0,
    shown_percent: u32 = 101,
    stopped: bool = false,
    replace_all: bool = false,
    /// The copy's buffer, allocated for the job; null for `buffer`.
    pieces: ?[*]u8 = null,
    piece_size: u32 = chunk,
    buffer: [chunk]u8 = undefined,
};

/// A job started on its process: the files `sources`, copied into `into`
/// (empty: each beside itself) or deleted. Nothing is done when there is
/// no memory or no process.
pub fn start(d: *Desktop, kind: Kind, sources: []const []const u8, into: []const u8) void {
    if (sources.len == 0) return;
    const memory = d.sys.AllocVec(@sizeOf(Job), exec.MEMF_CLEAR) orelse return;
    const job: *Job = @ptrCast(@alignCast(memory));
    job.* = .{ .base = d.base, .kind = kind };
    job.ended.message = .{ .reply_port = d.reply_port, .length = @sizeOf(run.Ended) };
    for (sources[0..@min(sources.len, sources_max)]) |source| {
        if (source.len > dos.path_max) continue;
        @memcpy(job.sources[job.count][0..source.len], source);
        job.sources[job.count][source.len] = 0;
        job.count += 1;
    }
    @memcpy(job.into[0..into.len], into);
    _base.holdLibrary(d.base, 1);
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr(processName(kind)) },
        .{ .tag = dos.NP_StackSize, .data = 32768 },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(job) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&d.base.lib) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&job.ended.message) },
        .{},
    };
    if (d.dl.CreateNewProc(&tags) == null) {
        _base.holdLibrary(d.base, -1);
        d.sys.FreeVec(memory);
        d.say("No memory to start the work");
        return;
    }
    d.running += 1;
}

fn processName(kind: Kind) [*:0]const u8 {
    return if (kind == .copy) "Anvil copy" else "Anvil delete";
}

fn titleOf(kind: Kind) [*:0]const u8 {
    return if (kind == .copy) "Copying" else "Deleting";
}

/// The job's process: its window up, the files counted, the work done,
/// everything given back. dos replies the end message once it has
/// returned.
fn workMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const job: *Job = @ptrCast(@alignCast(me.user_data orelse return));
    job.sys = sys;
    job.dl = @ptrCast(open(job, 0, dos.DOSNAME) orelse return);
    defer close(job);
    job.ib = @ptrCast(open(job, 1, intuition.INTUITIONNAME));
    job.icon_base = @ptrCast(open(job, 2, sdk.icon.ICONNAME));
    // Its window: without the gadgets' classes it works without one.
    if (job.kind == .copy and sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &job.clock.node, 0) == 0) {
        job.timer_base = @ptrCast(@alignCast(job.clock.node.device.?));
    }
    defer if (job.timer_base != null) sys.CloseDevice(&job.clock.node);
    if (open(job, 3, fg.GAUGE_LIBRARY) != null and open(job, 4, tx.TEXT_LIBRARY) != null) openWindow(job);
    defer closeWindow(job);

    for (job.sources[0..job.count]) |*source| measure(job, source, 0);
    if (job.kind == .copy) allocatePieces(job);
    defer if (job.pieces) |pieces| sys.FreeVec(pieces);
    restartRate(job);
    for (job.sources[0..job.count]) |*source| {
        if (job.stopped) break;
        switch (job.kind) {
            .copy => copyOne(job, source),
            .delete => _ = deleteAll(job, source, 0),
            .empty => emptyDrawer(job, source, 0),
        }
    }
}

fn open(job: *Job, at: usize, name: [*:0]const u8) ?*exec.Library {
    const lib = job.sys.OpenLibrary(name, 0) orelse return null;
    job.libraries[at] = lib;
    return lib;
}

fn close(job: *Job) void {
    var i = job.libraries.len;
    while (i > 0) {
        i -= 1;
        if (job.libraries[i]) |lib| job.sys.CloseLibrary(lib);
    }
}

// --- its window -------------------------------------------------------------------

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

fn openWindow(job: *Job) void {
    const ib = job.ib orelse return;
    job.label = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&job.label_text)), .{} });
    job.gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        pair(fg.GAUGE_Level, 0),
        pair(fg.GAUGE_Percent, 1),
        pair(fg.GAUGE_Format, @intFromPtr("%ld%%")),
        .{},
    });
    if (job.timer_base != null) {
        job.rate = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&job.rate_text)), .{} });
    }
    const stop = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr("_Stop")),
        pair(gc.GA_ID, ID_STOP),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
    var tags: [12]TagItem = undefined;
    var n: usize = 0;
    for ([_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(job.label)),
        pair(lg.CHILDA_MinWidth, 300),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(job.gauge)),
        pair(lg.CHILDA_WeightHeight, 0),
    }) |tag| {
        tags[n] = tag;
        n += 1;
    }
    if (job.rate) |rate| {
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(rate));
        tags[n + 1] = pair(lg.CHILDA_WeightHeight, 0);
        n += 2;
    }
    tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(stop));
    tags[n + 1] = pair(lg.CHILDA_WeightHeight, 0);
    tags[n + 2] = .{};
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags) orelse return;
    job.window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(titleOf(job.kind))),
        pair(wn.WA_DragBar, 1),
        pair(wn.WA_DepthGadget, 1),
        pair(wn.WA_CloseGadget, 1),
        pair(wn.WA_Position, wn.WPOS_CENTERSCREEN),
        pair(wc.WINDOWA_Layout, @intFromPtr(layout)),
        .{},
    }) orelse {
        ib.DisposeObject(layout);
        return;
    };
    var opening = wc.WmOpen{};
    if (ib.SendMessage(job.window_object, @ptrCast(&opening)) == 0) return;
    var window: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, job.window_object.?, &window);
    job.window = @ptrFromInt(window);
}

fn closeWindow(job: *Job) void {
    const ib = job.ib orelse return;
    // The window object disposes of its layout, and the layout of its
    // gadgets.
    if (job.window_object) |object| ib.DisposeObject(object);
}

/// The window's input taken: Stop, or its close gadget, ends the job.
fn poll(job: *Job) void {
    const ib = job.ib orelse return;
    const object = job.window_object orelse return;
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const word = ib.SendMessage(object, @ptrCast(&handle));
        if (word == wc.WMHI_LASTMSG) break;
        switch (word & wc.WMHI_CLASSMASK) {
            wc.WMHI_CLOSEWINDOW => job.stopped = true,
            wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_STOP) {
                job.stopped = true;
            },
            else => {},
        }
    }
}

/// The window says which file the job is at, and how far along it is.
fn show(job: *Job, name: []const u8) void {
    poll(job);
    const ib = job.ib orelse return;
    const window = job.window orelse return;
    const percent: u32 = if (job.total == 0) 100 else @intCast(@min(100, job.done * 100 / job.total));
    const shown = name[0..@min(name.len, job.label_text.len)];
    if (!eqlText(&job.label_text, shown)) {
        @memset(&job.label_text, 0);
        @memcpy(job.label_text[0..shown.len], shown);
        if (job.label) |label| _ = ib.SetGadgetAttrsTagList(label, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&job.label_text)), .{} });
    }
    if (percent != job.shown_percent) {
        job.shown_percent = percent;
        if (job.gauge) |gauge| _ = ib.SetGadgetAttrsTagList(gauge, window, &[_]TagItem{ pair(fg.GAUGE_Level, percent), .{} });
    }
    const rate = job.rate orelse return;
    const now = nowUs(job);
    if (now - job.rate_since_us < rate_period_us) return;
    const per_second = (job.done - job.rate_since_done) * 1_000_000 / (now - job.rate_since_us);
    job.rate_since_us = now;
    job.rate_since_done = job.done;
    var text: [24]u8 = undefined;
    const length = rateText(&text, per_second);
    if (eqlText(&job.rate_text, text[0..length])) return;
    @memset(&job.rate_text, 0);
    @memcpy(job.rate_text[0..length], text[0..length]);
    _ = ib.SetGadgetAttrsTagList(rate, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&job.rate_text)), .{} });
}

/// The E-clock in microseconds; 0 without timer.device.
fn nowUs(job: *Job) u64 {
    const timer_base = job.timer_base orelse return 0;
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// The rate measured from now on: at the start, and after a question,
/// whose wait copied nothing.
fn restartRate(job: *Job) void {
    job.rate_since_us = nowUs(job);
    job.rate_since_done = job.done;
}

const KiB: u64 = 1024;
const MiB: u64 = 1024 * KiB;
const GiB: u64 = 1024 * MiB;

/// Bytes a second in the unit that suits them, rounded down, 1024 to the
/// next as the desktop's title counts: bytes below a kilobyte ("512
/// B/s"), kilobytes and megabytes to a tenth ("12.5 KB/s", "45.6 MB/s"),
/// gigabytes to a hundredth ("2.05 GB/s"). At most 19 characters.
pub fn rateText(into: []u8, per_second: u64) usize {
    var n: usize = 0;
    if (per_second < KiB) {
        n += digits(into[n..], per_second);
        n += put(into[n..], " B/s");
    } else if (per_second < MiB) {
        const tenths = per_second * 10 / KiB;
        n += digits(into[n..], tenths / 10);
        n += put(into[n..], ".");
        n += digits(into[n..], tenths % 10);
        n += put(into[n..], " KB/s");
    } else if (per_second < GiB) {
        const tenths = per_second * 10 / MiB;
        n += digits(into[n..], tenths / 10);
        n += put(into[n..], ".");
        n += digits(into[n..], tenths % 10);
        n += put(into[n..], " MB/s");
    } else {
        const hundredths = per_second / GiB * 100 + per_second % GiB * 100 / GiB;
        n += digits(into[n..], hundredths / 100);
        n += put(into[n..], if (hundredths % 100 < 10) ".0" else ".");
        n += digits(into[n..], hundredths % 100);
        n += put(into[n..], " GB/s");
    }
    return n;
}

fn digits(into: []u8, value: u64) usize {
    var reversed: [20]u8 = undefined;
    var count: usize = 0;
    var left = value;
    while (true) {
        reversed[count] = '0' + @as(u8, @intCast(left % 10));
        count += 1;
        left /= 10;
        if (left == 0) break;
    }
    for (0..count) |i| into[i] = reversed[count - 1 - i];
    return count;
}

fn put(into: []u8, text: []const u8) usize {
    @memcpy(into[0..text.len], text);
    return text.len;
}

fn eqlText(held: []const u8, text: []const u8) bool {
    var n: usize = 0;
    while (n < held.len and held[n] != 0) n += 1;
    if (n != text.len) return false;
    for (held[0..n], text) |a, b| if (a != b) return false;
    return true;
}

// --- walking ------------------------------------------------------------------------

fn textOf(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

/// A FileInfoBlock of the job's own; null without memory.
fn newFib(job: *Job) ?*dos.FileInfoBlock {
    const memory = job.sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// What `path` holds counted into the total: its bytes for a copy, one
/// for each file for a delete - a drawer and everything in it. A soft
/// link in a drawer counts as a file: the walk never goes through one.
fn measure(job: *Job, path: [*:0]const u8, depth: usize) void {
    const dl = job.dl;
    const lock = dl.Lock(path, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(job) orelse return;
    defer job.sys.FreeVec(fib);
    if (!dl.Examine(lock, fib)) return;
    if (!dos.isDirectory(fib.dir_entry_type)) {
        counted(job, fib.size);
        return;
    }
    job.total += 1;
    if (depth == depth_max) return;
    var below: [dos.path_max + 1:0]u8 = @splat(0);
    while (dl.ExNext(lock, fib)) {
        if (!dos.isDirectory(fib.dir_entry_type)) {
            counted(job, fib.size);
            continue;
        }
        _ = drawer_path.join(&below, textOf(path), textOf(@ptrCast(&fib.file_name))) orelse continue;
        measure(job, &below, depth + 1);
    }
}

/// A file counted: its bytes for a copy, which notes the largest, or one
/// more file.
fn counted(job: *Job, size: u64) void {
    if (job.kind != .copy) {
        job.total += 1;
        return;
    }
    job.total += size;
    job.largest = @max(job.largest, size);
}

// --- copying --------------------------------------------------------------------------

/// The copy's buffer: the largest file's size, between the job's own 32
/// KiB and `chunk_most`. Without the memory the job's own will do.
fn allocatePieces(job: *Job) void {
    const size: u32 = @intCast(@min(job.largest, chunk_most));
    if (size <= chunk) return;
    const memory = job.sys.AllocVec(size, exec.MEMF_ANY) orelse return;
    job.pieces = @ptrCast(memory);
    job.piece_size = size;
}

/// One picked file copied, with its icon: into the job's drawer, or as a
/// copy of itself beside it.
fn copyOne(job: *Job, source: [*:0]const u8) void {
    const name = textOf(job.dl.FilePart(source));
    var target: [dos.path_max + 1:0]u8 = @splat(0);
    if (job.into[0] != 0) {
        _ = drawer_path.join(&target, textOf(&job.into), name) orelse return;
    } else if (!copyName(job, source, &target)) return;
    copyTree(job, source, &target, 0);
    // Its icon, beside it under the new name.
    var from_icon: [dos.path_max + 6:0]u8 = @splat(0);
    var to_icon: [dos.path_max + 6:0]u8 = @splat(0);
    if (!withInfo(&from_icon, textOf(source)) or !withInfo(&to_icon, textOf(&target))) return;
    const lock = job.dl.Lock(&from_icon, dos.SHARED_LOCK) orelse return;
    job.dl.UnLock(lock);
    _ = copyFile(job, &from_icon, &to_icon);
}

fn withInfo(into: []u8, path: []const u8) bool {
    if (path.len + 6 > into.len) return false;
    @memcpy(into[0..path.len], path);
    @memcpy(into[path.len..][0..5], ".info");
    into[path.len + 5] = 0;
    return true;
}

/// The name of a copy of `source` in its own drawer, the first that is
/// free: `Copy_of_x`, `Copy_2_of_x`, ...
fn copyName(job: *Job, source: [*:0]const u8, into: *[dos.path_max + 1:0]u8) bool {
    const ib = job.icon_base orelse return false;
    const dl = job.dl;
    const name = dl.FilePart(source);
    const drawer_length = @intFromPtr(name) - @intFromPtr(source);
    var seed: [dos.name_max + 1:0]u8 = @splat(0);
    const own = textOf(name);
    @memcpy(seed[0..own.len], own);
    var tries: usize = 0;
    while (tries < 100) : (tries += 1) {
        var made: [256]u8 = undefined;
        const fresh = textOf(ib.BumpRevision(&made, &seed));
        if (drawer_length + fresh.len > dos.path_max) return false;
        @memcpy(into[0..drawer_length], textOf(source)[0..drawer_length]);
        @memcpy(into[drawer_length..][0..fresh.len], fresh);
        into[drawer_length + fresh.len] = 0;
        const there = dl.Lock(into, dos.SHARED_LOCK) orelse return true;
        dl.UnLock(there);
        @memset(&seed, 0);
        @memcpy(seed[0..fresh.len], fresh);
    }
    return false;
}

/// `source` - a file, or a drawer with all in it - copied as `target`. A
/// soft link in a drawer is copied as the file it names, never gone
/// through.
fn copyTree(job: *Job, source: [*:0]const u8, target: [*:0]const u8, depth: usize) void {
    if (job.stopped) return;
    const dl = job.dl;
    const lock = dl.Lock(source, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(job) orelse return;
    defer job.sys.FreeVec(fib);
    if (!dl.Examine(lock, fib)) return;
    if (!dos.isDirectory(fib.dir_entry_type)) {
        _ = copyFile(job, source, target);
        return;
    }
    // A drawer: made, or copied into when it is there already.
    if (dl.CreateDir(target)) |made| dl.UnLock(made) else if (dl.Lock(target, dos.SHARED_LOCK)) |there| {
        dl.UnLock(there);
    } else return;
    job.done += 1;
    if (depth == depth_max) return;
    var from: [dos.path_max + 1:0]u8 = @splat(0);
    var to: [dos.path_max + 1:0]u8 = @splat(0);
    while (dl.ExNext(lock, fib)) {
        if (job.stopped) return;
        const name = textOf(@ptrCast(&fib.file_name));
        _ = drawer_path.join(&from, textOf(source), name) orelse continue;
        _ = drawer_path.join(&to, textOf(target), name) orelse continue;
        if (dos.isDirectory(fib.dir_entry_type)) copyTree(job, &from, &to, depth + 1) else _ = copyFile(job, &from, &to);
    }
}

/// One file's bytes copied, its protection, date and comment after them.
/// One that is there already is asked about first. False when it was
/// not copied.
fn copyFile(job: *Job, source: [*:0]const u8, target: [*:0]const u8) bool {
    const dl = job.dl;
    if (dl.Lock(target, dos.SHARED_LOCK)) |there| {
        dl.UnLock(there);
        if (!job.replace_all) {
            const answer = ask(job, target);
            restartRate(job);
            switch (answer) {
                .replace => {},
                .replace_all => job.replace_all = true,
                .skip => return false,
                .stop => {
                    job.stopped = true;
                    return false;
                },
            }
        }
    }
    const from = dl.Open(source, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(from);
    const to = dl.Open(target, dos.MODE_NEWFILE) orelse return false;
    const bytes: [*]u8 = job.pieces orelse &job.buffer;
    var whole = true;
    while (!job.stopped) {
        const got = dl.Read(from, bytes, @intCast(job.piece_size));
        if (got <= 0) {
            whole = got == 0;
            break;
        }
        if (dl.Write(to, bytes, got) != got) {
            whole = false;
            break;
        }
        job.done += @intCast(got);
        show(job, textOf(dl.FilePart(source)));
    }
    _ = dl.Close(to);
    if (!whole or job.stopped) {
        _ = dl.DeleteFile(target);
        return false;
    }
    // What the file was, kept.
    const fib = newFib(job) orelse return true;
    defer job.sys.FreeVec(fib);
    const lock = dl.Lock(source, dos.SHARED_LOCK) orelse return true;
    defer dl.UnLock(lock);
    if (!dl.Examine(lock, fib)) return true;
    _ = dl.SetProtection(target, fib.protection);
    _ = dl.SetFileDate(target, &fib.date);
    if (fib.comment[0] != 0) _ = dl.SetComment(target, @ptrCast(&fib.comment));
    return true;
}

const Answer = enum { replace, replace_all, skip, stop };

fn ask(job: *Job, target: [*:0]const u8) Answer {
    const ib = job.ib orelse return .skip;
    const easy = intuition.requesters.EasyStruct{
        .title = "Copying",
        .text_format = "%s is there already.\nReplace it?",
        .gadget_format = "Replace|Replace All|Skip|Stop",
    };
    const args = [_]usize{@intFromPtr(target)};
    return switch (ib.EasyRequestArgs(job.window, &easy, null, &args)) {
        1 => .replace,
        2 => .replace_all,
        3 => .skip,
        else => .stop,
    };
}

// --- deleting ------------------------------------------------------------------------

/// What is in the drawer `path` deleted, and the drawer kept.
fn emptyDrawer(job: *Job, path: [*:0]const u8, depth: usize) void {
    const dl = job.dl;
    const lock = dl.Lock(path, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(job) orelse return;
    defer job.sys.FreeVec(fib);
    var below: [dos.path_max + 1:0]u8 = @splat(0);
    var skipped: usize = 0;
    outer: while (!job.stopped) {
        if (!dl.Examine(lock, fib)) return;
        var n: usize = 0;
        while (dl.ExNext(lock, fib)) : (n += 1) {
            if (n < skipped) continue;
            _ = drawer_path.join(&below, textOf(path), textOf(@ptrCast(&fib.file_name))) orelse continue;
            if (!deleteAll(job, &below, depth + 1)) skipped += 1;
            continue :outer;
        }
        return;
    }
}

/// `path` deleted, a drawer after all that is in it, and its icon; false
/// when something in it could not be. The name is deleted first, and only
/// a drawer that is not empty is gone into: so a soft link goes itself,
/// never what it names.
fn deleteAll(job: *Job, path: [*:0]const u8, depth: usize) bool {
    if (job.stopped) return false;
    const dl = job.dl;
    show(job, textOf(dl.FilePart(path)));
    if (!dl.DeleteFile(path)) {
        if (dl.IoErr() != dos.ERROR_DIRECTORY_NOT_EMPTY or depth >= depth_max) return false;
        if (!deleteInside(job, path, depth)) return false;
        if (!dl.DeleteFile(path)) return false;
    }
    job.done += 1;
    // Its icon goes with it.
    var info: [dos.path_max + 6:0]u8 = @splat(0);
    if (withInfo(&info, textOf(path))) _ = dl.DeleteFile(&info);
    return true;
}

/// Everything in the drawer `path` deleted; false when something could
/// not be. The walk starts again after each, since a drawer changes under
/// ExNext as it is emptied.
fn deleteInside(job: *Job, path: [*:0]const u8, depth: usize) bool {
    const dl = job.dl;
    const lock = dl.Lock(path, dos.SHARED_LOCK) orelse return false;
    defer dl.UnLock(lock);
    const fib = newFib(job) orelse return false;
    defer job.sys.FreeVec(fib);
    var below: [dos.path_max + 1:0]u8 = @splat(0);
    var whole = true;
    var skipped: usize = 0;
    outer: while (!job.stopped) {
        if (!dl.Examine(lock, fib)) return false;
        var n: usize = 0;
        while (dl.ExNext(lock, fib)) : (n += 1) {
            if (n < skipped) continue;
            _ = drawer_path.join(&below, textOf(path), textOf(@ptrCast(&fib.file_name))) orelse continue;
            if (!deleteAll(job, &below, depth + 1)) {
                skipped += 1;
                whole = false;
            }
            continue :outer;
        }
        break;
    }
    return whole and !job.stopped;
}
