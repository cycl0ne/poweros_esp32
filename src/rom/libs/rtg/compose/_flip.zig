// SPDX-License-Identifier: MPL-2.0
//! A board that is flipped between two frames.
//!
//! Some displays read their picture where nothing the CPU does to it is
//! safe to be seen half done: out of RAM past the caches, which write
//! their lines back in an order of their own, or out of a buffer that is
//! copied into while it is read. Such a display never reads a buffer
//! anybody draws in. Its driver fills in `flip` - "read this frame from
//! the next blanking on" - and the library keeps **two frames**: the
//! display reads one, and the next picture is made in the other.
//!
//! **What changed** is noted as rectangles (`_damage.zig`): what was
//! written into a shown buffer, turned into the display's rectangles
//! through the bands; where a pointer or an overlay the library lays
//! was and is; the rows that show something else when the bands change.
//! Noting is a spinlock's work, and wakes the board's task.
//!
//! **A task a board** makes the next picture (`service`): what was noted
//! since the last one, and what went into that one - which this frame
//! has not had - fetched as the library composes it (`_compose.zig`
//! `lines`) into the frame the display is not reading, a large rectangle
//! shared between the cores; handed on to the driver (`refresh`: out of
//! the caches); then the display flipped to it (`flip`), and the frame
//! waited for, since until it comes the display reads the other, which
//! the next picture is made in. So a drawing is seen a frame or two after
//! it was made, and whole, and at most one picture is made a frame.
//!
//! **A show** makes its picture itself, and returns when it is on the
//! glass. With another mode the frames are taken for that mode, the
//! whole picture is made in the first, and the driver's `show` is handed
//! it to start the display on (`RtgShow.frame`).
//!
//! **The frames** are the library's, taken from where the board's
//! buffers come from and beside what the board may hold of those - or
//! the driver's own, where they are memory only it can get (`frames`):
//! a device's, a firmware's framebuffer. The library only ever writes a
//! frame: what the other frame lacks is fetched from the bands again,
//! never read back. Where the driver hands the same frame twice, the
//! display reads the one frame the pictures are made in.
//!
//! **A buffer read in place of a frame.** A whole picture is a copy of
//! the whole display, and a program that draws each picture in one
//! buffer while it shows another, and then shows that one, would wait
//! for one each time. A board that says `RTGBF_DIRECT_FLIP` is flipped
//! to such a buffer itself: one whole buffer shown in place of another
//! that nothing was written in while it was shown, with nothing of the
//! library's over the picture, is handed on whole and read as it is, and
//! nothing is copied. Should anything then be written in it, that is
//! handed on at once, and the task takes the frames up again with the
//! next picture, made whole.
//!
//! **A picture copied into a shown buffer all at once** - a window's
//! next frame, by the board's engine (CopyRect, CopyRects) - is not
//! copied while a picture is fetched from the bands (`holdCopy`): the
//! fetch starts at the top as the copy does, and would take the top of
//! the new picture and the rest of the old.
//!
//! Locks, in the order they are taken: the board's lock; the **flip
//! lock**, a semaphore, held while a picture is made, flipped to and
//! waited for - by the task, and by a show or a pointer's change that
//! may show the board another way; the compose lock, inside which the
//! picture is fetched, and which is let go while the driver's `flip`
//! runs and while the frame is waited for, so a pointer moves meanwhile
//! - a driver may wait in its `flip` until it has seen the display take
//! the frame; the read lock,
//! a semaphore, around the fetch and around an engine's copy into a
//! shown buffer; the damage lock, a spinlock, around what was noted, the
//! bands and whether they were written in.

const builtin = @import("builtin");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const rtg = sdk.rtg;
const err = rtg.errors;
const RtgBase = @import("../rtg.zig").RtgBase;
const boards = @import("../board/_board.zig");
const composer = @import("_compose.zig");
const damage = @import("_damage.zig");
const memory_mod = @import("../memory/_memory.zig");

const Box = damage.Box;
const Damage = damage.Damage;

/// The task that makes a board's pictures: above the programs that draw,
/// so that what they drew is shown at the pace of the display, and below
/// intuition's tasks, which move what is drawn.
const task_name = "rtg frames";
const task_priority = 19;

/// Where a frame of the library's own starts: on a page, which every
/// display that reads RAM reads from.
const page = 4096;

/// The fewest pixels a rectangle has before fetching it is shared
/// between the cores - about 64 KiB of a frame a part, below which
/// handing it out costs more than it saves - and the most parts it is
/// asked to be cut into: exec cuts it into no more than it has cores for.
const smallest = 16384;
const most_parts = 16;

/// What the library keeps for a flipped board (`composer.State.flip`).
pub const State = struct {
    /// The flip lock.
    lock: exec.SignalSemaphore = .{},
    /// The damage lock: `fresh`, `written`, and the board's bands while
    /// what was written is turned into the display's rectangles.
    damage_lock: exec.Lock = .{},
    /// The read lock: held while a picture is fetched from the bands,
    /// and while the engine copies into a buffer a band shows.
    read_lock: exec.SignalSemaphore = .{},
    /// The two frames, null before the board is first put in a mode, and
    /// which of them the display reads.
    frames: [2]?*rtg.RtgBitMap = .{ null, null },
    front: u1 = 0,
    /// Where the frames are the library's own: what they are, and the
    /// memory of each as it was taken - a block of exec's with its size,
    /// or a piece of the board's display memory.
    owned: bool = false,
    own: [2]rtg.RtgBitMap = .{ .{}, .{} },
    own_memory: [2]?*anyopaque = .{ null, null },
    own_bytes: [2]usize = .{ 0, 0 },
    /// What changed since the last picture was made, under the damage
    /// lock; and what went into that picture, which the other frame has
    /// not had.
    fresh: Damage = .{},
    last: Damage = .{},
    /// Whether the bands were written in since they were shown; under
    /// the damage lock.
    written: bool = false,
    /// Whether the display reads a buffer of the board in place of a
    /// frame: neither frame has had what it shows.
    reads_buffer: bool = false,
    /// A flip was made whose frame is still to be waited for, by whoever
    /// holds the flip lock, before it lets go of it.
    awaited: bool = false,
    /// The task, what wakes it, and what a board that is going stops it
    /// with.
    task: ?*exec.Task = null,
    work: exec.Waitable = .{},
    stopping: bool = false,
    stopped: exec.Waitable = .{},
    /// Pictures made in a frame, and buffers flipped to in place of one.
    pictures: u32 = 0,
    direct_flips: u32 = 0,
};

fn stateOf(board: *rtg.RtgBoard) *State {
    return &composer.stateOf(board).flip;
}

/// Whether the board is flipped between frames: its driver filled in
/// `flip`.
///
/// INPUTS:
/// - `board` - the board.
pub fn flipped(board: *const rtg.RtgBoard) bool {
    const ops = board.ops orelse return false;
    return ops.flip != null;
}

/// A board's flip state made ready, as the board is made.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn setUp(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const state = stateOf(board);
    sys.InitSemaphore(&state.lock);
    sys.InitSemaphore(&state.read_lock);
    sys.InitLock(&state.damage_lock, "rtg damage", exec.LOCKORDER_DRIVER, 0);
}

/// Takes a board's flip lock, where the board is flipped: before its
/// compose lock.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn obtain(rb: *RtgBase, board: *rtg.RtgBoard) void {
    if (flipped(board)) rb.sys_base.ObtainSemaphore(&stateOf(board).lock);
}

/// Gives a board's flip lock back, the frame of a flip made under it
/// waited for first: until it comes the display reads the frame the next
/// picture is made in.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its flip lock taken by `obtain`; its compose
///   lock is not held.
pub fn release(rb: *RtgBase, board: *rtg.RtgBoard) void {
    if (!flipped(board)) return;
    const state = stateOf(board);
    if (state.awaited) {
        state.awaited = false;
        _ = rb.iface().WaitVBlank(board, 1);
    }
    rb.sys_base.ReleaseSemaphore(&state.lock);
}

/// Takes the damage lock of a flipped board, around a change to its
/// bands: what is written meanwhile is turned into rectangles through
/// the bands before or after.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board.
pub fn holdBands(rb: *RtgBase, board: *rtg.RtgBoard) void {
    if (flipped(board)) rb.sys_base.AcquireLock(&stateOf(board).damage_lock);
}

/// Gives the damage lock back.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its damage lock taken by `holdBands`.
pub fn letBands(rb: *RtgBase, board: *rtg.RtgBoard) void {
    if (flipped(board)) rb.sys_base.ReleaseLock(&stateOf(board).damage_lock);
}

/// Before the board's engine copies into `dest`: where a band of a
/// flipped board shows that buffer, the read lock taken, so that no
/// picture is fetched from the bands while the copy runs. Whether it
/// was: `letCopy` gives it back.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the buffer's board.
/// - `dest` - the buffer copied into.
pub fn holdCopy(rb: *RtgBase, board: *rtg.RtgBoard, dest: *const rtg.RtgBitMap) bool {
    if (!flipped(board)) return false;
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const state = &private.compose.flip;
    var shows = false;
    sys.AcquireLock(&state.damage_lock);
    for (private.bands[0..private.band_count]) |band| {
        if (band.bitmap == dest) shows = true;
    }
    sys.ReleaseLock(&state.damage_lock);
    // A buffer that becomes a band meanwhile is a show, whose picture is
    // made whole after it.
    if (shows) sys.ObtainSemaphore(&state.read_lock);
    return shows;
}

/// The read lock given back, after a copy.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board, its read lock taken by `holdCopy`.
pub fn letCopy(rb: *RtgBase, board: *rtg.RtgBoard) void {
    rb.sys_base.ReleaseSemaphore(&stateOf(board).read_lock);
}

// --- what changed --------------------------------------------------------------

/// The whole display, in the mode the bands are shown in.
fn whole(board: *rtg.RtgBoard) Box {
    const compose = composer.stateOf(board);
    return .{ .left = 0, .top = 0, .right = compose.width, .end = compose.height };
}

fn boxOf(rect: rtg.RtgRect) Box {
    return .{
        .left = @intCast(rect.x),
        .top = @intCast(rect.y),
        .right = @intCast(rect.x + rect.width),
        .end = @intCast(rect.y + rect.height),
    };
}

fn rectOf(box: Box) rtg.RtgRect {
    return .{ .x = @intCast(box.left), .y = @intCast(box.top), .width = @intCast(box.right - box.left), .height = @intCast(box.end - box.top) };
}

/// The task woken: something was noted.
fn wake(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const state = stateOf(board);
    if (@atomicLoad(?*exec.Task, &state.task, .acquire) == null) return;
    rb.sys_base.SignalWaitable(&state.work);
}

/// Rectangles of the display noted for the next picture, and the task
/// woken: where an image the library lays was and is.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its compose lock is held.
/// - `rects` - the rectangles, inside the display.
pub fn note(rb: *RtgBase, board: *rtg.RtgBoard, rects: []const rtg.RtgRect) void {
    if (rects.len == 0) return;
    const sys = rb.sys_base;
    const state = stateOf(board);
    sys.AcquireLock(&state.damage_lock);
    for (rects) |rect| state.fresh.add(boxOf(rect));
    sys.ReleaseLock(&state.damage_lock);
    wake(rb, board);
}

/// A rectangle of a buffer that was written, on a flipped board: noted
/// where the bands show it, and the task woken. Nothing is handed on to
/// the driver - the display does not read the buffer - but where it
/// reads it in place of a frame: there it is handed on at once, and the
/// task takes the frames up again.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the buffer's board.
/// - `bitmap` - the buffer.
/// - `cut` - the rectangle, cut down to the buffer.
///
/// RESULT:
/// RTGERR_OK, or what the driver answered for a buffer it reads.
pub fn written(rb: *RtgBase, board: *rtg.RtgBoard, bitmap: *rtg.RtgBitMap, cut: *const rtg.RtgRect) i32 {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const compose = &private.compose;
    const state = &compose.flip;
    const top: u32 = @intCast(cut.y);
    const rows_end: u32 = top + @as(u32, @intCast(cut.height));
    const left: u32 = @intCast(cut.x);

    var noted = false;
    sys.AcquireLock(&state.damage_lock);
    const right: u32 = @min(left + @as(u32, @intCast(cut.width)), compose.width);
    const bands = private.bands[0..private.band_count];
    if (left < right) {
        for (bands, 0..) |band, i| {
            if (band.bitmap != bitmap) continue;
            const band_end = if (i + 1 < bands.len) bands[i + 1].line else compose.height;
            // The display lines that show the rows written: all of a
            // band that repeats its buffer's first row, where that row
            // is among them.
            const repeats = band.flags & rtg.RTGBANDF_REPEAT != 0;
            if (repeats and top != 0) continue;
            const from = if (repeats) band.line else @max(band.line, top +| band.origin);
            const end = if (repeats) band_end else @min(band_end, rows_end +| band.origin);
            if (from >= end) continue;
            state.fresh.add(.{ .left = left, .top = from, .right = right, .end = end });
            noted = true;
        }
    }
    if (noted) state.written = true;
    const read = noted and state.reads_buffer;
    sys.ReleaseLock(&state.damage_lock);

    var code: i32 = err.RTGERR_OK;
    if (read) {
        if (board.ops.?.refresh) |refresh| code = refresh(board, bitmap, cut);
    }
    if (noted) wake(rb, board);
    return code;
}

// --- the frames ---------------------------------------------------------------

/// The library's own frames given back.
fn giveOwn(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const state = &private.compose.flip;
    if (!state.owned) return;
    for (&state.own, &state.own_memory, &state.own_bytes) |*frame, *memory, *bytes| {
        if (memory.*) |block| {
            sys.FreeMem(block, bytes.*);
        } else if (frame.pixels != null) {
            private.arena.give(sys, frame.offset, frame.taken);
        }
        frame.* = .{};
        memory.* = null;
        bytes.* = 0;
    }
    state.owned = false;
    state.frames = .{ null, null };
}

/// One frame of the library's own for a mode: from exec, beside what the
/// board may hold of buffers, where its buffers come from system memory;
/// else a piece of its display memory. False without room.
fn takeOwn(rb: *RtgBase, board: *rtg.RtgBoard, mode: *const rtg.RtgMode, which: usize) bool {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const state = &private.compose.flip;
    const size = @as(usize, mode.pitch) * mode.height;
    var frame = rtg.RtgBitMap{
        .width = mode.width,
        .height = mode.height,
        .pitch = mode.pitch,
        .format = mode.format,
        .size_bytes = size,
        .board = @ptrCast(board),
    };
    if (private.arena.system) {
        const bytes = size + page;
        const block = sys.AllocMem(bytes, private.arena.attributes | exec.MEMF_SYSTEM) orelse return false;
        frame.pixels = @ptrFromInt((@intFromPtr(block) + page - 1) & ~@as(usize, page - 1));
        state.own_memory[which] = block;
        state.own_bytes[which] = bytes;
    } else {
        const piece = private.arena.take(sys, size) orelse return false;
        frame.pixels = @ptrFromInt(piece.pixels);
        frame.offset = piece.offset;
        frame.taken = piece.taken;
    }
    state.own[which] = frame;
    state.frames[which] = &state.own[which];
    return true;
}

/// Two frames for a mode: the driver's, where it hands them over, else
/// the library's own - those it has, where they are that mode's size.
///
/// RESULT:
/// RTGERR_OK, RTGERR_NO_MEMORY, or what the driver answered.
fn prepare(rb: *RtgBase, board: *rtg.RtgBoard, mode: *const rtg.RtgMode) i32 {
    const state = stateOf(board);
    if (board.ops.?.frames) |ask| {
        var handed: [2]?*rtg.RtgBitMap = .{ null, null };
        const code = ask(board, mode, &handed);
        if (code != err.RTGERR_OK) return code;
        const one = handed[0] orelse return err.RTGERR_NO_MEMORY;
        const other = handed[1] orelse return err.RTGERR_NO_MEMORY;
        if (one.pixels == null or other.pixels == null) return err.RTGERR_NO_MEMORY;
        giveOwn(rb, board);
        state.frames = .{ one, other };
        return err.RTGERR_OK;
    }
    if (state.owned) {
        const have = &state.own[0];
        if (have.width == mode.width and have.height == mode.height and have.pitch == mode.pitch and have.format == mode.format) return err.RTGERR_OK;
    }
    giveOwn(rb, board);
    state.owned = true;
    if (!takeOwn(rb, board, mode, 0) or !takeOwn(rb, board, mode, 1)) {
        giveOwn(rb, board);
        return err.RTGERR_NO_MEMORY;
    }
    return err.RTGERR_OK;
}

// --- a picture made ---------------------------------------------------------------

/// A rectangle fetched into a frame, in parts on several cores.
const Fetch = struct {
    rb: *RtgBase,
    board: *rtg.RtgBoard,
    frame: *rtg.RtgBitMap,
    box: Box,
    bytes: u32,

    /// Part `part` of `parts`: its share of the rectangle's rows.
    fn run(fetch: *const Fetch, part: u32, parts: u32) void {
        const rows = fetch.box.end - fetch.box.top;
        const from = fetch.box.top + @as(u32, @intCast(@as(u64, rows) * part / parts));
        const end = fetch.box.top + @as(u32, @intCast(@as(u64, rows) * (part + 1) / parts));
        if (from >= end) return;
        const frame = fetch.frame;
        const into = frame.pixels.? + @as(usize, from) * frame.pitch + @as(usize, fetch.box.left) * fetch.bytes;
        _ = composer.lines(fetch.rb, fetch.board, &rectOf(.{ .left = fetch.box.left, .top = from, .right = fetch.box.right, .end = end }), into, frame.pitch);
    }
};

/// A part of a fetch, on whichever core exec gave it to. It takes no
/// lock: its caller holds the compose lock for it.
fn fetchPart(data: ?*anyopaque, part: u32, parts: u32) callconv(.c) void {
    const fetch: *const Fetch = @ptrCast(@alignCast(data.?));
    fetch.run(part, parts);
}

/// One rectangle of the picture as the library composes it, fetched into
/// a frame and handed on to the driver.
fn makeBox(rb: *RtgBase, board: *rtg.RtgBoard, frame: *rtg.RtgBitMap, box: Box) void {
    if (box.isEmpty()) return;
    var fetch = Fetch{ .rb = rb, .board = board, .frame = frame, .box = box, .bytes = composer.stateOf(board).bytes };
    const parts: u32 = @intCast(@min(box.area() / smallest, most_parts));
    if (parts > 1) {
        _ = rb.sys_base.ShareWork(&fetchPart, &fetch, parts);
    } else {
        fetch.run(0, 1);
    }
    if (board.ops.?.refresh) |refresh| _ = refresh(board, frame, &rectOf(box));
}

/// The display told to read `frame`: the driver's `flip`, with the
/// compose lock let go for as long as it runs. A driver may wait in it
/// for the display to take the frame, and a pointer the library lays is
/// moved meanwhile - noted for the next picture. The flip lock, which
/// the caller holds, keeps it one at a time and the frames as they are.
fn tell(rb: *RtgBase, board: *rtg.RtgBoard, frame: *rtg.RtgBitMap) i32 {
    composer.release(rb, board);
    const code = board.ops.?.flip.?(board, frame);
    composer.obtain(rb, board);
    return code;
}

/// After a flip that failed: the frames asked of the driver again, where
/// they are its own, and the whole picture noted for the next try.
fn startOver(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const state = &private.compose.flip;
    if (board.ops.?.frames != null) {
        if (private.mode) |record| _ = prepare(rb, board, &record.mode);
    }
    state.last = .{};
    sys.AcquireLock(&state.damage_lock);
    state.fresh.add(whole(board));
    sys.ReleaseLock(&state.damage_lock);
}

/// The next picture made in the frame the display is not reading, and
/// the display flipped to it: what was noted since the last one, and
/// what went into that one, which this frame has not had. Where the
/// display read a buffer in place of a frame, neither frame has had what
/// it showed: the picture is made whole, and the next one too.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its flip lock and its compose lock are held.
///
/// RESULT:
/// RTGERR_OK - also where nothing was noted, and nothing made - or what
/// the driver answered the flip with: the display then reads what it
/// read.
fn picture(rb: *RtgBase, board: *rtg.RtgBoard) i32 {
    const sys = rb.sys_base;
    const compose = composer.stateOf(board);
    const state = &compose.flip;

    sys.AcquireLock(&state.damage_lock);
    const fresh = state.fresh;
    state.fresh = .{};
    sys.ReleaseLock(&state.damage_lock);
    if (fresh.isEmpty()) return err.RTGERR_OK;
    const reading = state.frames[state.front] orelse return err.RTGERR_OK;
    const back = state.frames[state.front ^ 1] orelse return err.RTGERR_OK;
    if (compose.bytes == 0) return err.RTGERR_OK;

    // A buffer read until now: the frames are taken up again, whole.
    const stale = state.reads_buffer;
    var boxes = fresh;
    if (stale) {
        boxes.add(whole(board));
    } else if (back.pixels != reading.pixels) {
        boxes.addAll(&state.last);
    }
    // No copy lands in a band's buffer while the bands are read.
    sys.ObtainSemaphore(&state.read_lock);
    for (boxes.list()) |box| makeBox(rb, board, back, box);
    sys.ReleaseSemaphore(&state.read_lock);

    const code = tell(rb, board, back);
    if (code < 0) {
        startOver(rb, board);
        return code;
    }
    state.last = if (stale) boxes else fresh;
    state.front ^= 1;
    state.reads_buffer = false;
    compose.direct = false;
    state.awaited = code != rtg.boards.RTGFLIP_TAKEN;
    state.pictures +%= 1;
    return err.RTGERR_OK;
}

/// The frame a flipped board's display is to read as it is put in a
/// mode: the frames taken for the mode, and the whole picture made in
/// the first - the bands the show put in place, black where there are
/// none - and handed on.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its flip lock and its compose lock are held,
///   and the show's bands are in place.
/// - `mode` - the mode the board is being put in.
/// - `frame` - where the frame is answered.
///
/// RESULT:
/// RTGERR_OK, RTGERR_NO_MEMORY without room for the frames,
/// RTGERR_BAD_FORMAT for a mode whose pixels are not whole bytes, or
/// what the driver answered when it was asked for its frames.
pub fn first(rb: *RtgBase, board: *rtg.RtgBoard, mode: *const rtg.RtgMode, frame: *?*rtg.RtgBitMap) i32 {
    if (composer.stateOf(board).bytes == 0) return err.RTGERR_BAD_FORMAT;
    const code = prepare(rb, board, mode);
    if (code != err.RTGERR_OK) return code;
    const state = stateOf(board);
    const begins = state.frames[0].?;
    makeBox(rb, board, begins, whole(board));
    frame.* = begins;
    return err.RTGERR_OK;
}

/// The board was put in a mode, its display reading the frame `first`
/// answered: from here on pictures are made in the other, which has had
/// nothing yet. The board's task is made, where it has none.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its flip lock and its compose lock are held.
pub fn begun(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const state = stateOf(board);
    state.front = 0;
    state.last = .{};
    state.last.add(whole(board));
    state.reads_buffer = false;
    sys.AcquireLock(&state.damage_lock);
    state.fresh = .{};
    state.written = false;
    sys.ReleaseLock(&state.damage_lock);
    start(rb, board);
}

/// A flipped board was shown other bands, or the same another way, in
/// the mode it is in: the picture of it made and flipped to, as a flip
/// is - the rows that show something else than before, nothing when none
/// does - or, where the display is to read a buffer in place of a frame,
/// that buffer handed on whole and flipped to.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; its flip lock and its compose lock are held,
///   and the bands shown are in place.
/// - `old` - the bands shown before.
///
/// RESULT:
/// RTGERR_OK, or what the driver answered the flip with: the display
/// then reads what it read.
pub fn shown(rb: *RtgBase, board: *rtg.RtgBoard, old: []const rtg.RtgBand) i32 {
    const sys = rb.sys_base;
    const private = boards.privateOf(board);
    const compose = &private.compose;
    const state = &compose.flip;
    const bands = private.bands[0..private.band_count];

    if (compose.direct and bands.len == 1) {
        const bitmap = bands[0].bitmap;
        const area = rtg.RtgRect{ .width = @intCast(bitmap.width), .height = @intCast(bitmap.height) };
        // Nothing of it was handed on as it was drawn: out it goes,
        // whole.
        if (board.ops.?.refresh) |refresh| _ = refresh(board, bitmap, &area);
        const code = tell(rb, board, bitmap);
        if (code < 0) return code;
        // The frames are made whole when they are taken up again.
        sys.AcquireLock(&state.damage_lock);
        state.fresh = .{};
        state.written = false;
        sys.ReleaseLock(&state.damage_lock);
        state.reads_buffer = true;
        state.awaited = code != rtg.boards.RTGFLIP_TAKEN;
        state.direct_flips +%= 1;
        return err.RTGERR_OK;
    }

    var changed: Damage = .{};
    if (state.reads_buffer) {
        changed.add(whole(board));
    } else {
        changed.rebanded(old, bands, compose.width, compose.height);
    }
    sys.AcquireLock(&state.damage_lock);
    state.fresh.addAll(&changed);
    state.written = false;
    sys.ReleaseLock(&state.damage_lock);
    return picture(rb, board);
}

// --- the task ------------------------------------------------------------------

/// What a board's task does when it is woken: the next picture made and
/// flipped to, and its frame waited for.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - a flipped board.
pub fn service(rb: *RtgBase, board: *rtg.RtgBoard) void {
    obtain(rb, board);
    composer.obtain(rb, board);
    _ = picture(rb, board);
    composer.release(rb, board);
    release(rb, board);
}

fn taskCode(sys: *ExecBase) callconv(.c) void {
    const me = sys.FindTask(null).?;
    while (@atomicLoad(?*anyopaque, &me.user_data, .acquire) == null) _ = sys.Wait(exec.SIGF_SINGLE);
    const board: *rtg.RtgBoard = @ptrCast(@alignCast(me.user_data.?));
    const rb: *RtgBase = @ptrCast(@alignCast(board.rtg_base.?));
    const state = stateOf(board);
    while (true) {
        _ = sys.WaitForAny(&[_]*exec.Waitable{&state.work}, 1, exec.WAIT_FOREVER);
        // Reset before what was noted is taken: whatever is noted after
        // it wakes the task again.
        sys.ResetWaitable(&state.work);
        if (@atomicLoad(bool, &state.stopping, .acquire)) break;
        service(rb, board);
    }
    // The last it does with the board: it is freed once this is seen.
    sys.SignalWaitable(&state.stopped);
}

/// The board's task made, where it has none: the system's, not the
/// task's that happened to show first. Without memory there is none, and
/// pictures are made by the shows alone.
fn start(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const state = stateOf(board);
    if (state.task != null) return;
    sys.BeginSystemMemory();
    const task = sys.CreateTask(task_name, task_priority, &taskCode, 0);
    sys.EndSystemMemory();
    const made = task orelse return;
    @atomicStore(?*anyopaque, &made.user_data, board, .release);
    @atomicStore(?*exec.Task, &state.task, made, .release);
    sys.Signal(made, exec.SIGF_SINGLE);
}

/// The board's task stopped: on a machine told and waited for; in a
/// host test, where no task but the test's own runs, taken off. From
/// then on pictures are made by the shows alone.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - a flipped board; none of its locks is held.
pub fn stopTask(rb: *RtgBase, board: *rtg.RtgBoard) void {
    const sys = rb.sys_base;
    const state = stateOf(board);
    const task = @atomicLoad(?*exec.Task, &state.task, .acquire) orelse return;
    @atomicStore(?*exec.Task, &state.task, null, .release);
    if (builtin.is_test) {
        sys.RemTask(task);
        return;
    }
    @atomicStore(bool, &state.stopping, true, .release);
    sys.SignalWaitable(&state.work);
    _ = sys.WaitForAny(&[_]*exec.Waitable{&state.stopped}, 1, exec.WAIT_FOREVER);
}

/// A board that is going: its task stopped and its frames given back.
///
/// INPUTS:
/// - `rb` - the library.
/// - `board` - the board; none of its locks is held.
pub fn stop(rb: *RtgBase, board: *rtg.RtgBoard) void {
    if (!flipped(board)) return;
    stopTask(rb, board);
    giveOwn(rb, board);
    stateOf(board).frames = .{ null, null };
}
