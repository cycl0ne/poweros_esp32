// SPDX-License-Identifier: MIT
//! The desktop's work on files - copying, deleting, emptying the trash -
//! each on a process of its own, so the desktop answers while it goes on.
//!
//! **A job** is the files picked and what to do with them. Its process
//! first walks them to count what there is - bytes for a copy, files for
//! a delete - then does it, with a window that says which file it is at
//! and how far along it is, and a Stop button that ends it between two
//! pieces. A copy asks before it puts a file where one is already
//! (Replace, Replace All, Skip, Stop); a drawer that is there already is
//! copied into. A file's icon goes with it, and its protection, date and
//! comment are kept.
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
const TagItem = utility.TagItem;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const IntuitionBase = sdk.interface.intuition.IntuitionBase;
const IconBase = sdk.interface.icon.IconBase;
const Object = intuition.Object;
const _base = @import("../anvil_base.zig");
const run = @import("run.zig");
const drawer_path = @import("../drawer/path.zig");
const Desktop = @import("_desktop.zig").Desktop;

/// Copying; deleting what was picked; deleting what is in a drawer - the
/// trash - and keeping the drawer.
pub const Kind = enum { copy, delete, empty };

/// The most files one job is given.
pub const sources_max = 16;
/// How many bytes are copied at a time.
const chunk = 32768;
/// How deep a copy or a delete goes into drawers within drawers.
const depth_max = 24;

const ID_STOP = 1;

/// A job, in one block: the end message first, which the desktop frees
/// the block by.
pub const Job = struct {
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
    total: u64 = 0,
    done: u64 = 0,
    shown_percent: u32 = 101,
    stopped: bool = false,
    replace_all: bool = false,
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
    if (open(job, 3, fg.GAUGE_LIBRARY) != null and open(job, 4, tx.TEXT_LIBRARY) != null) openWindow(job);
    defer closeWindow(job);

    for (job.sources[0..job.count]) |*source| measure(job, source, 0);
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
    const stop = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr("_Stop")),
        pair(gc.GA_ID, ID_STOP),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &[_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(job.label)),
        pair(lg.CHILDA_MinWidth, 300),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(job.gauge)),
        pair(lg.CHILDA_WeightHeight, 0),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(stop)),
        pair(lg.CHILDA_WeightHeight, 0),
        .{},
    }) orelse return;
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
/// for each file for a delete - a drawer and everything in it.
fn measure(job: *Job, path: [*:0]const u8, depth: usize) void {
    const dl = job.dl;
    const lock = dl.Lock(path, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(job) orelse return;
    defer job.sys.FreeVec(fib);
    if (!dl.Examine(lock, fib)) return;
    if (fib.dir_entry_type <= 0) {
        job.total += if (job.kind == .copy) fib.size else 1;
        return;
    }
    job.total += 1;
    if (depth == depth_max) return;
    var below: [dos.path_max + 1:0]u8 = @splat(0);
    while (dl.ExNext(lock, fib)) {
        _ = drawer_path.join(&below, textOf(path), textOf(@ptrCast(&fib.file_name))) orelse continue;
        measure(job, &below, depth + 1);
    }
}

// --- copying --------------------------------------------------------------------------

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

/// `source` - a file, or a drawer with all in it - copied as `target`.
fn copyTree(job: *Job, source: [*:0]const u8, target: [*:0]const u8, depth: usize) void {
    if (job.stopped) return;
    const dl = job.dl;
    const lock = dl.Lock(source, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(job) orelse return;
    defer job.sys.FreeVec(fib);
    if (!dl.Examine(lock, fib)) return;
    if (fib.dir_entry_type <= 0) {
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
        copyTree(job, &from, &to, depth + 1);
    }
}

/// One file's bytes copied, its protection, date and comment after them.
/// One that is there already is asked about first. False when it was
/// not copied.
fn copyFile(job: *Job, source: [*:0]const u8, target: [*:0]const u8) bool {
    const dl = job.dl;
    if (dl.Lock(target, dos.SHARED_LOCK)) |there| {
        dl.UnLock(there);
        if (!job.replace_all) switch (ask(job, target)) {
            .replace => {},
            .replace_all => job.replace_all = true,
            .skip => return false,
            .stop => {
                job.stopped = true;
                return false;
            },
        };
    }
    const from = dl.Open(source, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(from);
    const to = dl.Open(target, dos.MODE_NEWFILE) orelse return false;
    var whole = true;
    while (!job.stopped) {
        const got = dl.Read(from, &job.buffer, chunk);
        if (got <= 0) {
            whole = got == 0;
            break;
        }
        if (dl.Write(to, &job.buffer, got) != got) {
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
/// when something in it could not be.
fn deleteAll(job: *Job, path: [*:0]const u8, depth: usize) bool {
    if (job.stopped) return false;
    const dl = job.dl;
    var whole = true;
    if (dl.Lock(path, dos.SHARED_LOCK)) |lock| {
        const fib = newFib(job) orelse {
            dl.UnLock(lock);
            return false;
        };
        defer job.sys.FreeVec(fib);
        const is_drawer = dl.Examine(lock, fib) and fib.dir_entry_type > 0;
        if (is_drawer and depth < depth_max) {
            // What is in it first; the walk starts again after each, since
            // a drawer changes under ExNext as it is emptied.
            var below: [dos.path_max + 1:0]u8 = @splat(0);
            var skipped: usize = 0;
            outer: while (!job.stopped) {
                if (!dl.Examine(lock, fib)) break;
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
        }
        dl.UnLock(lock);
    }
    if (!whole) return false;
    show(job, textOf(dl.FilePart(path)));
    if (!dl.DeleteFile(path)) return false;
    job.done += 1;
    // Its icon goes with it.
    var info: [dos.path_max + 6:0]u8 = @splat(0);
    if (withInfo(&info, textOf(path))) _ = dl.DeleteFile(&info);
    return true;
}
