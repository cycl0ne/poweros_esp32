// SPDX-License-Identifier: MIT
//! The desktop's work on files - copying, deleting, emptying the trash -
//! on a process of its own, so the desktop answers while it goes on, one
//! job after the other.
//!
//! **A job** is the files picked and what to do with them, up to
//! `sources_max` of them; more picked at once are as many jobs as that
//! takes. The process first walks a job's files to count what there is -
//! bytes for a copy, files for a delete - then does it, with a window
//! that says which file it is at and how far along it is, and a Stop
//! button that ends it between two pieces. A copy's window says how fast
//! it goes as well: the bytes of the last second, measured on
//! timer.device's E-clock, which a clock set meanwhile does not move. A
//! file's bytes go by its handler first (dos's CopyFH), a piece at a
//! time: on a network share the server copies them, and they never
//! cross the network; a handler that cannot leaves them to Read and
//! Write, the next piece read (dos's StartRead) while this one is
//! written, so the two handlers work at once. A copy asks before it puts
//! a file where one is already (Replace, Replace All, Skip, Stop); a
//! drawer that is there already is copied into. A file's icon goes with
//! it, and its protection, date and comment are kept. A soft link in a
//! drawer is never gone through: a copy takes the file it names, a
//! delete takes the link itself.
//!
//! **The jobs queue.** The desktop has one work process at a time
//! (`Desktop.work`). A job picked while it has one in hand waits on its
//! list and is done once those before it are, in the same window, which
//! says how many more wait. Stop ends the job in hand and the next one
//! starts; the close gadget ends it and drops the ones waiting. The
//! process ends when it finds its list empty, and a job after that
//! starts another. The desktop adds to the list and the process takes
//! from it under the work's lock, and the process marks itself ending
//! under the same lock - so a job is never put on a list nothing will
//! look at again.
//!
//! **Its life**: StartAnvil's library code runs on it, so it holds the
//! library open (`NP_HoldLibrary`); the desktop counts it among what it
//! started, and the message the process is given (`NP_EndMsg`), which
//! dos replies to the desktop's port when the process is gone, is the
//! start of the work's own block - so the desktop frees the block with
//! it, after `ended` has let go of it. A job is the desktop's
//! allocation, and the process's to free once it is done or dropped.
//! The drawers it changed see the change through their notification.
//! Its words come from the desktop's catalog (`anvil.cd`), which the
//! process opens for itself: it may outlive the desktop that started it.

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
const strings = @import("strings");
const Text = sdk.locale.Strings(strings);
const Id = strings.Id;
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
/// The buffer in the work's own block, two pieces of half its size: what
/// a copy reads at a time on the ESP32s, and where memory for a larger
/// one is short.
const chunk = 32768;
/// The most a copy reads at a time: a piece of the largest file's size,
/// up to 1 MiB where memory is plenty, so a big file costs a read a MiB -
/// a network share answers a read in one round trip, and a disk writes
/// it in one go.
const chunk_most: u32 = if (sdk.hardware.chip == .rv64sbi or sdk.hardware.chip == .a64psci or sdk.hardware.chip == .x64uefi) 1 << 20 else chunk;
/// What one CopyFH asks a file's handler for: as much as a share's
/// server copies at once, so the window moves and Stop is seen between.
const handler_piece: i64 = 16 << 20;
/// How deep a copy or a delete goes into drawers within drawers.
const depth_max = 24;
/// How long a copy's rate is measured over, in microseconds.
const rate_period_us = 1_000_000;

const ID_STOP = 1;

/// A job: the files and what to do with them, on the work's list until
/// the process comes to it.
pub const Job = struct {
    node: exec.Node = .{},
    kind: Kind,
    sources: [sources_max][dos.path_max + 1:0]u8 = undefined,
    count: usize = 0,
    /// Where a copy goes: a drawer; empty to copy each file in its own
    /// drawer, as a copy of itself.
    into: [dos.path_max + 1:0]u8 = @splat(0),
};

fn jobOf(node: *exec.Node) *Job {
    return @alignCast(@fieldParentPtr("node", node));
}

/// The work process's block: the end message first, which the desktop
/// frees the block by. Extern, so that it stays first: Zig orders a plain
/// struct's fields as it likes.
pub const Work = extern struct {
    ended: run.Ended = .{},
    base: *_base.AnvilBase,
    /// The jobs waiting, oldest first, and how many: under `lock`, as is
    /// `closing` - set once the process found the list empty and ends.
    lock: exec.SignalSemaphore = .{},
    waiting: exec.List = .{},
    waiting_count: u32 = 0,
    closing: bool = false,
    /// The job in hand; null between two.
    job: ?*Job = null,

    // The process's own.
    sys: *ExecBase = undefined,
    dl: *DosBase = undefined,
    /// Its words, opened on its stack; null until they are.
    text: ?*const Text = null,
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
    /// How many jobs wait after this one, under the rate, as shown.
    queued: ?*Object = null,
    queued_text: [64:0]u8 = @splat(0),
    shown_waiting: u32 = 0,
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
    /// The job in hand stopped - Stop, or a question's Stop - and with
    /// the close gadget the ones waiting dropped as well.
    stopped: bool = false,
    stop_all: bool = false,
    replace_all: bool = false,
    /// A copy's buffer, two pieces - one read while the other is written
    /// - allocated for the job; null for `buffer`.
    pieces: ?[*]u8 = null,
    piece_size: u32 = chunk / 2,
    buffer: [chunk]u8 = undefined,
    /// The read of the next piece, out while this one is written; null
    /// without the memory, and the next is read after.
    ahead: ?*dos.DosRequest = null,
};

/// The files `sources` copied into `into` (empty: each beside itself),
/// deleted, or emptied: as many jobs as `sources_max` at a time takes,
/// each queued for the work process (`queue`). A job there is no memory
/// for is not done, said in the title.
pub fn start(d: *Desktop, kind: Kind, sources: []const []const u8, into: []const u8) void {
    if (into.len > dos.path_max) return;
    var from: usize = 0;
    while (from < sources.len) {
        const part = sources[from..@min(sources.len, from + sources_max)];
        from += part.len;
        const memory = d.sys.AllocVec(@sizeOf(Job), exec.MEMF_CLEAR) orelse return d.tell(.MSG_NO_MEMORY_WORK, .{});
        const job: *Job = @ptrCast(@alignCast(memory));
        job.* = .{ .kind = kind };
        for (part) |source| {
            if (source.len > dos.path_max) continue;
            @memcpy(job.sources[job.count][0..source.len], source);
            job.sources[job.count][source.len] = 0;
            job.count += 1;
        }
        @memcpy(job.into[0..into.len], into);
        if (job.count == 0) {
            d.sys.FreeVec(memory);
            continue;
        }
        queue(d, job);
    }
}

/// Files gathered for jobs, any number of them: `sources_max` names to a
/// block - a job's worth - and as many blocks chained as it takes. Made
/// on the desktop's stack, filled (`add`), handed over (`queue`) and
/// given back (`free`).
pub const Files = struct {
    first: ?*Block = null,
    last: ?*Block = null,
    count: usize = 0,
    /// A name too long, or a block there was no memory for: left out.
    lost: bool = false,

    const Block = struct {
        paths: [sources_max][dos.path_max + 1]u8 = undefined,
        lengths: [sources_max]usize = undefined,
        count: usize = 0,
        next: ?*Block = null,
    };

    /// `path` added, in a new block when the last one is full.
    pub fn add(files: *Files, sys: *ExecBase, path: []const u8) void {
        if (path.len > dos.path_max) {
            files.lost = true;
            return;
        }
        const full = if (files.last) |last| last.count == sources_max else true;
        if (full) {
            const memory = sys.AllocVec(@sizeOf(Block), exec.MEMF_ANY) orelse {
                files.lost = true;
                return;
            };
            const block: *Block = @ptrCast(@alignCast(memory));
            block.* = .{};
            if (files.last) |last| last.next = block else files.first = block;
            files.last = block;
        }
        const block = files.last.?;
        @memcpy(block.paths[block.count][0..path.len], path);
        block.lengths[block.count] = path.len;
        block.count += 1;
        files.count += 1;
    }

    /// A job of `kind` started for each block, into `into` for a copy
    /// (`start`).
    pub fn queue(files: *const Files, d: *Desktop, kind: Kind, into: []const u8) void {
        var walk = files.first;
        while (walk) |block| : (walk = block.next) {
            var slices: [sources_max][]const u8 = undefined;
            for (0..block.count) |at| slices[at] = block.paths[at][0..block.lengths[at]];
            start(d, kind, slices[0..block.count], into);
        }
    }

    /// Every block given back.
    pub fn free(files: *Files, sys: *ExecBase) void {
        while (files.first) |block| {
            files.first = block.next;
            sys.FreeVec(block);
        }
        files.last = null;
        files.count = 0;
    }
};

/// A job put on the work process's list - or a process started for it
/// where there is none, or the one there is has found its list empty and
/// is ending. Without the memory or a process the job is dropped, said
/// in the title.
fn queue(d: *Desktop, job: *Job) void {
    const sys = d.sys;
    if (d.work) |work| {
        sys.ObtainSemaphore(&work.lock);
        const taken = !work.closing;
        if (taken) {
            sys.AddTail(&work.waiting, &job.node);
            work.waiting_count += 1;
        }
        sys.ReleaseSemaphore(&work.lock);
        if (taken) return;
    }
    const memory = sys.AllocVec(@sizeOf(Work), exec.MEMF_CLEAR) orelse {
        sys.FreeVec(job);
        d.tell(.MSG_NO_MEMORY_WORK, .{});
        return;
    };
    const work: *Work = @ptrCast(@alignCast(memory));
    work.* = .{ .base = d.base };
    work.ended.message = .{ .reply_port = d.reply_port, .length = @sizeOf(run.Ended) };
    sys.InitSemaphore(&work.lock);
    work.waiting.init(.unknown);
    sys.AddTail(&work.waiting, &job.node);
    work.waiting_count = 1;
    _base.holdLibrary(d.base, 1);
    const tags = [_]TagItem{
        .{ .tag = dos.NP_Entry, .data = @intFromPtr(&workMain) },
        .{ .tag = dos.NP_Name, .data = @intFromPtr("Anvil work") },
        .{ .tag = dos.NP_StackSize, .data = 32768 },
        .{ .tag = dos.NP_UserData, .data = @intFromPtr(work) },
        .{ .tag = dos.NP_HoldLibrary, .data = @intFromPtr(&d.base.lib) },
        .{ .tag = dos.NP_EndMsg, .data = @intFromPtr(&work.ended.message) },
        .{},
    };
    if (d.dl.CreateNewProc(&tags) == null) {
        _base.holdLibrary(d.base, -1);
        sys.FreeVec(job);
        sys.FreeVec(memory);
        d.tell(.MSG_NO_MEMORY_WORK, .{});
        return;
    }
    d.running += 1;
    d.work = work;
}

/// A process's end message come back to the desktop: the work process
/// that ended is the desktop's no more. The desktop frees its block
/// after.
pub fn ended(d: *Desktop, message: *run.Ended) void {
    const work = d.work orelse return;
    if (&work.ended == message) d.work = null;
}

fn titleOf(work: *const Work, kind: Kind) [*:0]const u8 {
    return wordOf(work, switch (kind) {
        .copy => .MSG_WORK_COPYING,
        .delete, .empty => .MSG_WORK_DELETING,
    });
}

/// The string `id` in the language the user prefers; the one built in
/// before the process has its words.
fn wordOf(work: *const Work, id: Id) [*:0]const u8 {
    const text = work.text orelse return strings.builtin(id);
    return text.get(id);
}

/// The work process: its window up, then each job in turn counted and
/// done, until the list is empty; everything given back. dos replies the
/// end message once it has returned.
fn workMain(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    const work: *Work = @ptrCast(@alignCast(me.user_data orelse return));
    work.sys = sys;
    // However it ends, it ends closed, with nothing left waiting.
    defer finish(work);
    work.dl = @ptrCast(open(work, 0, dos.DOSNAME) orelse return);
    defer close(work);
    var text = Text.open(sys);
    defer text.close();
    work.text = &text;
    defer work.text = null;
    // The first job before the window, which is titled for it.
    var job = takeNext(work) orelse return;
    work.ib = @ptrCast(open(work, 1, intuition.INTUITIONNAME));
    work.icon_base = @ptrCast(open(work, 2, sdk.icon.ICONNAME));
    if (sys.OpenDevice(sdk.interface.timer.NAME, timer.UNIT_MICROHZ, &work.clock.node, 0) == 0) {
        work.timer_base = @ptrCast(@alignCast(work.clock.node.device.?));
    }
    defer if (work.timer_base != null) sys.CloseDevice(&work.clock.node);
    // Its window: without the gadgets' classes it works without one.
    if (open(work, 3, fg.GAUGE_LIBRARY) != null and open(work, 4, tx.TEXT_LIBRARY) != null) openWindow(work);
    defer closeWindow(work);
    work.ahead = @ptrCast(@alignCast(work.dl.AllocDosObject(dos.DOS_REQUEST, null)));
    defer if (work.ahead) |request| work.dl.FreeDosObject(dos.DOS_REQUEST, request);
    while (true) {
        doJob(work, job);
        work.job = null;
        sys.FreeVec(job);
        job = takeNext(work) orelse break;
    }
}

/// The next job off the list; null when there is none, and the work
/// closed under the same lock, so a job after it starts another process.
/// After the close gadget the ones waiting are dropped first.
fn takeNext(work: *Work) ?*Job {
    const sys = work.sys;
    sys.ObtainSemaphore(&work.lock);
    defer sys.ReleaseSemaphore(&work.lock);
    if (work.stop_all) drop(work);
    const node = sys.RemHead(&work.waiting) orelse {
        work.closing = true;
        return null;
    };
    work.waiting_count -= 1;
    const job = jobOf(node);
    work.job = job;
    return job;
}

/// The work closed, and whatever still waits dropped: a process that
/// ends early - no dos.library - leaves no job behind on a list nothing
/// looks at.
fn finish(work: *Work) void {
    const sys = work.sys;
    sys.ObtainSemaphore(&work.lock);
    defer sys.ReleaseSemaphore(&work.lock);
    work.closing = true;
    drop(work);
}

/// Every job waiting freed. Under the work's lock.
fn drop(work: *Work) void {
    while (work.sys.RemHead(&work.waiting)) |node| work.sys.FreeVec(jobOf(node));
    work.waiting_count = 0;
}

/// One job: its files counted, then copied, deleted or emptied, in the
/// window made ready for it.
fn doJob(work: *Work, job: *Job) void {
    work.total = 0;
    work.done = 0;
    work.largest = 0;
    work.stopped = false;
    work.replace_all = false;
    readyWindow(work, job);
    for (job.sources[0..job.count]) |*source| measure(work, source, 0);
    if (job.kind == .copy) allocatePieces(work);
    defer {
        if (work.pieces) |pieces| work.sys.FreeVec(pieces);
        work.pieces = null;
        work.piece_size = chunk / 2;
    }
    restartRate(work);
    for (job.sources[0..job.count]) |*source| {
        if (work.stopped) break;
        switch (job.kind) {
            .copy => copyOne(work, source),
            .delete => _ = deleteAll(work, source),
            .empty => emptyDrawer(work, source),
        }
    }
}

fn open(work: *Work, at: usize, name: [*:0]const u8) ?*exec.Library {
    const lib = work.sys.OpenLibrary(name, 0) orelse return null;
    work.libraries[at] = lib;
    return lib;
}

fn close(work: *Work) void {
    var i = work.libraries.len;
    while (i > 0) {
        i -= 1;
        if (work.libraries[i]) |lib| work.sys.CloseLibrary(lib);
    }
}

// --- its window -------------------------------------------------------------------

fn pair(tag: utility.Tag, data: usize) TagItem {
    return .{ .tag = tag, .data = data };
}

fn openWindow(work: *Work) void {
    const ib = work.ib orelse return;
    work.label = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.label_text)), .{} });
    work.gauge = ib.NewObjectTagList(null, fg.GAUGE_CLASS, &[_]TagItem{
        pair(fg.GAUGE_Level, 0),
        pair(fg.GAUGE_Percent, 1),
        pair(fg.GAUGE_Format, @intFromPtr("%ld%%")),
        .{},
    });
    if (work.timer_base != null) {
        work.rate = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.rate_text)), .{} });
    }
    work.queued = ib.NewObjectTagList(null, tx.TEXT_CLASS, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.queued_text)), .{} });
    const stop = ib.NewObjectTagList(null, classusr.FRBUTTONCLASS, &[_]TagItem{
        pair(gc.GA_Text, @intFromPtr(wordOf(work, .MSG_WORK_STOP))),
        pair(gc.GA_ID, ID_STOP),
        pair(gc.GA_RelVerify, 1),
        .{},
    });
    var tags: [16]TagItem = undefined;
    var n: usize = 0;
    for ([_]TagItem{
        pair(lg.LAYOUTA_Orientation, lg.LORIENT_VERT),
        pair(lg.LAYOUTA_Margin, 6),
        pair(lg.LAYOUTA_Spacing, 6),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(work.label)),
        pair(lg.CHILDA_MinWidth, 300),
        pair(lg.LAYOUTA_AddChild, @intFromPtr(work.gauge)),
        pair(lg.CHILDA_WeightHeight, 0),
    }) |tag| {
        tags[n] = tag;
        n += 1;
    }
    for ([_]?*Object{ work.rate, work.queued }) |maybe| {
        const line = maybe orelse continue;
        tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(line));
        tags[n + 1] = pair(lg.CHILDA_WeightHeight, 0);
        n += 2;
    }
    tags[n] = pair(lg.LAYOUTA_AddChild, @intFromPtr(stop));
    tags[n + 1] = pair(lg.CHILDA_WeightHeight, 0);
    tags[n + 2] = .{};
    const layout = ib.NewObjectTagList(null, classusr.LAYOUTGCLASS, &tags) orelse return;
    const first = if (work.job) |held| held.kind else Kind.copy;
    work.window_object = ib.NewObjectTagList(null, classusr.WINDOWCLASS, &[_]TagItem{
        pair(wn.WA_Title, @intFromPtr(titleOf(work, first))),
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
    if (ib.SendMessage(work.window_object, @ptrCast(&opening)) == 0) return;
    var window: usize = 0;
    _ = ib.GetAttr(wc.WINDOWA_Window, work.window_object.?, &window);
    work.window = @ptrFromInt(window);
}

fn closeWindow(work: *Work) void {
    const ib = work.ib orelse return;
    // The window object disposes of its layout, and the layout of its
    // gadgets.
    if (work.window_object) |object| ib.DisposeObject(object);
}

/// The window made ready for the next job: its title, nothing yet of
/// which file or how fast, the gauge back at the start, and how many
/// wait after it.
fn readyWindow(work: *Work, job: *Job) void {
    work.shown_percent = 101;
    @memset(&work.label_text, 0);
    @memset(&work.rate_text, 0);
    const ib = work.ib orelse return;
    const window = work.window orelse return;
    ib.SetWindowTitles(window, titleOf(work, job.kind), wn.TITLE_UNCHANGED);
    if (work.label) |label| _ = ib.SetGadgetAttrsTagList(label, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.label_text)), .{} });
    if (work.rate) |rate| _ = ib.SetGadgetAttrsTagList(rate, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.rate_text)), .{} });
    work.shown_waiting = ~@as(u32, 0);
    showWaiting(work);
}

/// The window's input taken: Stop ends the job in hand, its close gadget
/// that one and every one waiting.
fn poll(work: *Work) void {
    const ib = work.ib orelse return;
    const object = work.window_object orelse return;
    var code: u32 = 0;
    var handle = wc.WmHandleInput{ .code = &code };
    while (true) {
        const word = ib.SendMessage(object, @ptrCast(&handle));
        if (word == wc.WMHI_LASTMSG) break;
        switch (word & wc.WMHI_CLASSMASK) {
            wc.WMHI_CLOSEWINDOW => {
                work.stopped = true;
                work.stop_all = true;
            },
            wc.WMHI_GADGETUP => if (word & wc.WMHI_GADGETMASK == ID_STOP) {
                work.stopped = true;
            },
            else => {},
        }
    }
}

/// "2 more waiting" under the rate, when the count has changed; nothing
/// there with none. The count is the desktop's to raise, and read here
/// without the lock: a line shown a moment late is all it costs.
fn showWaiting(work: *Work) void {
    const ib = work.ib orelse return;
    const window = work.window orelse return;
    const line = work.queued orelse return;
    const count = @atomicLoad(u32, &work.waiting_count, .monotonic);
    if (count == work.shown_waiting) return;
    work.shown_waiting = count;
    @memset(&work.queued_text, 0);
    if (count != 0) if (work.text) |text| {
        _ = text.format(&work.queued_text, .MSG_WORK_WAITING, .{@as(u64, count)});
    };
    _ = ib.SetGadgetAttrsTagList(line, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.queued_text)), .{} });
}

/// The window says which file the job is at, how far along it is, and
/// how many more wait.
fn show(work: *Work, name: []const u8) void {
    poll(work);
    showWaiting(work);
    const ib = work.ib orelse return;
    const window = work.window orelse return;
    const percent: u32 = if (work.total == 0) 100 else @intCast(@min(100, work.done * 100 / work.total));
    const shown = name[0..@min(name.len, work.label_text.len)];
    if (!eqlText(&work.label_text, shown)) {
        @memset(&work.label_text, 0);
        @memcpy(work.label_text[0..shown.len], shown);
        if (work.label) |label| _ = ib.SetGadgetAttrsTagList(label, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.label_text)), .{} });
    }
    if (percent != work.shown_percent) {
        work.shown_percent = percent;
        if (work.gauge) |gauge| _ = ib.SetGadgetAttrsTagList(gauge, window, &[_]TagItem{ pair(fg.GAUGE_Level, percent), .{} });
    }
    const job = work.job orelse return;
    if (job.kind != .copy) return;
    const rate = work.rate orelse return;
    const now = nowUs(work);
    if (now - work.rate_since_us < rate_period_us) return;
    const per_second = (work.done - work.rate_since_done) * 1_000_000 / (now - work.rate_since_us);
    work.rate_since_us = now;
    work.rate_since_done = work.done;
    var text: [24]u8 = undefined;
    const length = rateText(&text, per_second);
    if (eqlText(&work.rate_text, text[0..length])) return;
    @memset(&work.rate_text, 0);
    @memcpy(work.rate_text[0..length], text[0..length]);
    _ = ib.SetGadgetAttrsTagList(rate, window, &[_]TagItem{ pair(tx.TEXT_Text, @intFromPtr(&work.rate_text)), .{} });
}

/// The E-clock in microseconds; 0 without timer.device.
fn nowUs(work: *Work) u64 {
    const timer_base = work.timer_base orelse return 0;
    var value: timer.EClockVal = .{};
    const rate = timer_base.ReadEClock(&value);
    const count = @as(u64, value.hi) << 32 | value.lo;
    return count / rate * 1_000_000 + count % rate * 1_000_000 / rate;
}

/// The rate measured from now on: at the start, and after a question,
/// whose wait copied nothing.
fn restartRate(work: *Work) void {
    work.rate_since_us = nowUs(work);
    work.rate_since_done = work.done;
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

/// A FileInfoBlock of the work's own; null without memory.
fn newFib(work: *Work) ?*dos.FileInfoBlock {
    const memory = work.sys.AllocVec(@sizeOf(dos.FileInfoBlock), exec.MEMF_CLEAR) orelse return null;
    return @ptrCast(@alignCast(memory));
}

/// What `path` holds counted into the total: its bytes for a copy, one
/// for each file for a delete - a drawer and everything in it. A soft
/// link in a drawer counts as a file: the walk never goes through one.
fn measure(work: *Work, path: [*:0]const u8, depth: usize) void {
    const dl = work.dl;
    const lock = dl.Lock(path, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(work) orelse return;
    defer work.sys.FreeVec(fib);
    if (!dl.Examine(lock, fib)) return;
    if (!dos.isDirectory(fib.dir_entry_type)) {
        counted(work, fib.size);
        return;
    }
    work.total += 1;
    if (depth == depth_max) return;
    var below: [dos.path_max + 1:0]u8 = @splat(0);
    while (dl.ExNext(lock, fib)) {
        if (!dos.isDirectory(fib.dir_entry_type)) {
            counted(work, fib.size);
            continue;
        }
        _ = drawer_path.join(&below, textOf(path), textOf(@ptrCast(&fib.file_name))) orelse continue;
        measure(work, &below, depth + 1);
    }
}

/// A file counted: its bytes for a copy, which notes the largest, or one
/// more file.
fn counted(work: *Work, size: u64) void {
    if (work.job.?.kind != .copy) {
        work.total += 1;
        return;
    }
    work.total += size;
    work.largest = @max(work.largest, size);
}

// --- copying --------------------------------------------------------------------------

/// The copy's two pieces: each the largest file's size, between half the
/// work's own 32 KiB and `chunk_most`. Without the memory the work's own
/// will do.
fn allocatePieces(work: *Work) void {
    const size: u32 = @intCast(@min(work.largest, chunk_most));
    if (size <= chunk / 2) return;
    const memory = work.sys.AllocVec(2 * size, exec.MEMF_ANY) orelse return;
    work.pieces = @ptrCast(memory);
    work.piece_size = size;
}

/// One picked file copied, with its icon: into the job's drawer, or as a
/// copy of itself beside it.
fn copyOne(work: *Work, source: [*:0]const u8) void {
    const name = textOf(work.dl.FilePart(source));
    var target: [dos.path_max + 1:0]u8 = @splat(0);
    if (work.job.?.into[0] != 0) {
        _ = drawer_path.join(&target, textOf(&work.job.?.into), name) orelse return;
    } else if (!copyName(work, source, &target)) return;
    copyTree(work, source, &target, 0);
    if (work.stopped) return;
    // Its icon, beside it under the new name.
    var from_icon: [dos.path_max + 6:0]u8 = @splat(0);
    var to_icon: [dos.path_max + 6:0]u8 = @splat(0);
    if (!withInfo(&from_icon, textOf(source)) or !withInfo(&to_icon, textOf(&target))) return;
    const lock = work.dl.Lock(&from_icon, dos.SHARED_LOCK) orelse return;
    work.dl.UnLock(lock);
    _ = copyFile(work, &from_icon, &to_icon);
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
fn copyName(work: *Work, source: [*:0]const u8, into: *[dos.path_max + 1:0]u8) bool {
    const ib = work.icon_base orelse return false;
    const dl = work.dl;
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
fn copyTree(work: *Work, source: [*:0]const u8, target: [*:0]const u8, depth: usize) void {
    if (work.stopped) return;
    const dl = work.dl;
    const lock = dl.Lock(source, dos.SHARED_LOCK) orelse return;
    defer dl.UnLock(lock);
    const fib = newFib(work) orelse return;
    defer work.sys.FreeVec(fib);
    if (!dl.Examine(lock, fib)) return;
    if (!dos.isDirectory(fib.dir_entry_type)) {
        _ = copyFile(work, source, target);
        return;
    }
    // A drawer: made, or copied into when it is there already.
    if (dl.CreateDir(target)) |made| dl.UnLock(made) else if (dl.Lock(target, dos.SHARED_LOCK)) |there| {
        dl.UnLock(there);
    } else return;
    work.done += 1;
    if (depth == depth_max) return;
    var from: [dos.path_max + 1:0]u8 = @splat(0);
    var to: [dos.path_max + 1:0]u8 = @splat(0);
    while (dl.ExNext(lock, fib)) {
        if (work.stopped) return;
        const name = textOf(@ptrCast(&fib.file_name));
        _ = drawer_path.join(&from, textOf(source), name) orelse continue;
        _ = drawer_path.join(&to, textOf(target), name) orelse continue;
        if (dos.isDirectory(fib.dir_entry_type)) copyTree(work, &from, &to, depth + 1) else _ = copyFile(work, &from, &to);
    }
}

/// One file's bytes copied, its protection, date and comment after them.
/// One that is there already is asked about first. False when it was
/// not copied.
fn copyFile(work: *Work, source: [*:0]const u8, target: [*:0]const u8) bool {
    const dl = work.dl;
    if (dl.Lock(target, dos.SHARED_LOCK)) |there| {
        dl.UnLock(there);
        if (!work.replace_all) {
            // The window says which file the question is about first,
            // and how many jobs wait behind this one.
            show(work, textOf(dl.FilePart(source)));
            if (work.stopped) return false;
            const answer = ask(work, target);
            restartRate(work);
            switch (answer) {
                .replace => {},
                .replace_all => work.replace_all = true,
                .skip => return false,
                .stop => {
                    work.stopped = true;
                    return false;
                },
            }
        }
    }
    const from = dl.Open(source, dos.MODE_OLDFILE) orelse return false;
    defer _ = dl.Close(from);
    const to = dl.Open(target, dos.MODE_NEWFILE) orelse return false;
    const bytes: [*]u8 = work.pieces orelse &work.buffer;
    const size: isize = @intCast(work.piece_size);
    const pieces = [2][*]u8{ bytes, bytes + work.piece_size };
    var whole = true;
    // By the handler, until it says it cannot.
    var by_handler = true;
    // The bytes in pieces[at]; null before the first read.
    var got: ?isize = null;
    var at: usize = 0;
    while (!work.stopped) {
        if (by_handler) {
            const copied = dl.CopyFH(to, from, handler_piece);
            if (copied > 0) {
                work.done += @intCast(copied);
                show(work, textOf(dl.FilePart(source)));
                continue;
            }
            if (copied == 0) break;
            if (dl.IoErr() != dos.ERROR_ACTION_NOT_KNOWN) {
                whole = false;
                break;
            }
            by_handler = false;
        }
        const have = got orelse dl.Read(from, pieces[at], size);
        if (have <= 0) {
            whole = have == 0;
            break;
        }
        // The next piece into the other half while this one is written:
        // the two handlers at work at once. Without a request, after it.
        const ahead = if (work.ahead) |request| dl.StartRead(from, pieces[at ^ 1], size, request) else false;
        const written = dl.Write(to, pieces[at], have);
        const next = if (ahead) dl.WaitRequest(work.ahead) else if (written == have) dl.Read(from, pieces[at ^ 1], size) else 0;
        if (written != have) {
            whole = false;
            break;
        }
        work.done += @intCast(have);
        show(work, textOf(dl.FilePart(source)));
        got = next;
        at ^= 1;
    }
    _ = dl.Close(to);
    if (!whole or work.stopped) {
        _ = dl.DeleteFile(target);
        return false;
    }
    // What the file was, kept.
    const fib = newFib(work) orelse return true;
    defer work.sys.FreeVec(fib);
    const lock = dl.Lock(source, dos.SHARED_LOCK) orelse return true;
    defer dl.UnLock(lock);
    if (!dl.Examine(lock, fib)) return true;
    _ = dl.SetProtection(target, fib.protection);
    _ = dl.SetFileDate(target, &fib.date);
    if (fib.comment[0] != 0) _ = dl.SetComment(target, @ptrCast(&fib.comment));
    return true;
}

const Answer = enum { replace, replace_all, skip, stop };

fn ask(work: *Work, target: [*:0]const u8) Answer {
    const ib = work.ib orelse return .skip;
    const easy = intuition.requesters.EasyStruct{
        .title = titleOf(work, .copy),
        .text_format = wordOf(work, .MSG_WORK_REPLACE_ASK),
        .gadget_format = wordOf(work, .MSG_WORK_REPLACE_BUTTONS),
    };
    const args = [_]usize{@intFromPtr(target)};
    return switch (ib.EasyRequestArgs(work.window, &easy, null, &args)) {
        1 => .replace,
        2 => .replace_all,
        3 => .skip,
        else => .stop,
    };
}

// --- deleting ------------------------------------------------------------------------

/// What is in the drawer `path` deleted, and the drawer kept: by dos's
/// DeleteTree, on past what will not go.
fn emptyDrawer(work: *Work, path: [*:0]const u8) void {
    if (work.stopped) return;
    var hook: utility.Hook = .{ .entry = deleted, .data = work };
    _ = work.dl.DeleteTree(path, dos.DELF_KEEP | dos.DELF_ONWARD, &hook);
}

/// `path` deleted by dos's DeleteTree, a drawer with all that is in it,
/// and its icon; false when something in it could not be, which is
/// passed over and the rest deleted. A soft link goes itself, never what
/// it names.
fn deleteAll(work: *Work, path: [*:0]const u8) bool {
    if (work.stopped) return false;
    const dl = work.dl;
    show(work, textOf(dl.FilePart(path)));
    var hook: utility.Hook = .{ .entry = deleted, .data = work };
    if (!dl.DeleteTree(path, dos.DELF_ONWARD, &hook)) return false;
    // Its icon goes with it.
    var info: [dos.path_max + 6:0]u8 = @splat(0);
    if (withInfo(&info, textOf(path))) _ = dl.DeleteFile(&info);
    return true;
}

/// DeleteTree's hook: each object tried counted when it went, and shown;
/// Stop ends the walk.
fn deleted(hook: *utility.Hook, object: ?*anyopaque, message: ?*anyopaque) callconv(.c) usize {
    _ = object;
    const work: *Work = @ptrCast(@alignCast(hook.data.?));
    const told: *const dos.DeleteMsg = @ptrCast(@alignCast(message.?));
    if (told.failure == 0) work.done += 1;
    show(work, textOf(work.dl.FilePart(told.name)));
    return @intFromBool(work.stopped);
}
