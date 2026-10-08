// SPDX-License-Identifier: MPL-2.0
//! The mouse pointer: which picture it has, and whether it is seen.
//!
//! The pointer is the active window's: its own (`WA_Pointer`, a
//! pointerclass object), the busy pointer (`WA_BusyPointer`), the default
//! one - which is also what it is with no window active - or none at all
//! (`WA_HidePointer`), which leaves the board its picture and only stops
//! showing it. `update`
//! works out which, and hands the picture to the board of the front
//! screen with rtg.library's `SetBoardPointer` - which converts it once -
//! only when that changes. The board lays it over the picture on its way
//! to the glass, so nothing that draws ever has to know about it.
//!
//! It moves on a task of its own, "intuition pointer", which the input
//! handler hands each position to as the event arrives: the handler
//! stores it and signals, and the task makes the move. `MoveBoardPointer`
//! may wait - for rtg's pointer semaphore, and on a bus board for the
//! send - which an input handler may not; and a task of its own keeps the
//! pointer moving while intuition's task is busy dragging a window.
//! Intuition's task sees the same event after and moves it to the same
//! place, which the board takes as no move.
//!
//! It is seen only once a mouse has been: until the handler finds an event
//! from mouse.device (IECLASS_RAWMOUSE) in front of a pointer position, the
//! position has come from a finger on a touch panel, where a pointer would
//! only stand where the finger was last lifted. From the first mouse event
//! on it stays.
//!
//! Its own two pictures are an arrow and, for busy, a ring of two arrows
//! chasing each other, drawn in characters and made at compile time.
//!
//! The busy ring turns: an eighth of a turn clockwise on each of
//! input.device's ticks, from eight pictures of it made at compile time
//! (`busy_frames`), each handed to the board as the tick comes. A turned
//! picture's pixel is the drawn one's sixteen points turned back, opaque
//! where half of them are and their colour on average, so the ring keeps
//! its outline at every angle. On a screen opened with `SA_Animate` off it
//! stands still.
//!
//! `WA_PointerDelay` puts a change off for three of input.device's ticks,
//! a tenth of a second each (`tick`), and a change made before then calls
//! it off: a busy pointer put up for work that ends at once never shows.
//!
//! Everything here runs under the screen semaphore, except `moved` and
//! `mouseSeen`, which the handler calls.

const sdk = @import("sdk");
const exec = sdk.exec;
const rtg = sdk.rtg;
const intuition = sdk.intuition;
const Object = intuition.Object;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("../window/_window.zig");
const Window = _window.Window;
const Screen = @import("../screen/_screen.zig").Screen;
const pointerclass = @import("../classes/pointerclass.zig");

/// Which picture the board has - or, `hidden`, that the active window
/// wants none shown.
pub const Kind = enum(u32) { none, default, busy, custom, hidden };

/// intuition.library's pointer, in its base.
pub const State = extern struct {
    /// The board the picture was handed to, and what it was.
    board: ?*rtg.RtgBoard = null,
    kind: Kind = .none,
    object: ?*Object = null,
    /// Whether it is shown on `board`, and whether a mouse has been seen -
    /// which the handler writes.
    shown: u8 = 0,
    mouse: u8 = 0,
    /// Which of `busy_frames` the board has while it is busy.
    frame: u8 = 0,
    pad: u8 = 0,
};

/// The pointer's task, in intuition's base beside `State` - which starts
/// afresh when the front screen's board changes, while the task runs on:
/// the task, the signal the handler wakes it with (0 while there is
/// none), and the newest position for it, under `place_lock`.
pub const Mover = extern struct {
    task: exec.Task = .{},
    mask: u32 = 0,
    place_x: i32 = 0,
    place_y: i32 = 0,
    place_lock: exec.Lock = .{},
    /// Who started the task, told once it has its signal.
    starter: ?*exec.Task = null,
    start_signal: i32 = 0,
};

/// Above input.device's task and intuition's, so the pointer is where the
/// newest event says before either goes on.
const task_pri = 21;
const task_stack = 8192;

/// How many ticks `WA_PointerDelay` waits.
pub const delay_ticks = 3;

// --- the two pictures of its own -------------------------------------------------

/// A picture drawn in characters, a row to a string: `.` clear, `X` the
/// grey outline, `o` white, `p` pink, `t` teal - as rgba32 pixels, made at
/// compile time.
fn Picture(comptime width: usize, comptime height: usize) type {
    return struct { pixels: [width * height]u32, width: u32 = width, height: u32 = height };
}

fn picture(comptime rows: []const []const u8) Picture(rows[0].len, rows.len) {
    @setEvalBranchQuota(10_000);
    var made: Picture(rows[0].len, rows.len) = .{ .pixels = undefined };
    for (rows, 0..) |row, y| {
        if (row.len != rows[0].len) @compileError("a picture's rows differ in length");
        for (row, 0..) |ch, x| {
            made.pixels[y * row.len + x] = switch (ch) {
                '.' => 0,
                'X' => 0x575757FF,
                'o' => 0xFFFFFFFF,
                'p' => 0xD4497FFF,
                't' => 0x46A7ACFF,
                else => @compileError("not a colour of a picture"),
            };
        }
    }
    return made;
}

/// The arrow, its point the top left.
const default_picture = picture(&.{
    "X...........",
    "XX..........",
    "XoX.........",
    "XooX........",
    "XoooX.......",
    "XooooX......",
    "XoooooX.....",
    "XooooooX....",
    "XoooooooX...",
    "XooooooooX..",
    "XoooooooooX.",
    "XooooooXXXXX",
    "XoooXooX....",
    "XooXXooX....",
    "XoX..XooX...",
    "XX...XooX...",
    "X.....XooX..",
    "......XooX..",
    ".......XX...",
});

/// Busy: a ring of two arrows chasing each other, its point the middle.
pub const busy_picture = picture(&.{
    ".....XXXXXXX.....",
    "...XXppppppoXX...",
    "..XXppppppoooXX..",
    ".XXpppXXXXXootXX.",
    ".XpppX.....XtttX.",
    "XpppX.......XtttX",
    "XppX.........XttX",
    "XppX.........XttX",
    "XppX.........XttX",
    "XppX.........XttX",
    "XppX.........XttX",
    "XpppX.......XtttX",
    ".XpppX.....XtttX.",
    ".XXpooXXXXXtttXX.",
    "..XXooottttttXX..",
    "...XXottttttXX...",
    ".....XXXXXXX.....",
});

/// How many pictures a turn of the busy ring is.
pub const busy_turn = 8;

/// The busy ring at each eighth of a turn, clockwise; the first is the
/// drawn one.
pub const busy_frames = frames: {
    var made: [busy_turn]@TypeOf(busy_picture) = undefined;
    for (&made, 0..) |*frame, i| frame.* = turned(&busy_picture, i);
    break :frames made;
};

/// `drawn` turned `eighths` eighths of a turn clockwise about its middle:
/// each pixel sampled at four by four points turned back into `drawn`.
fn turned(comptime drawn: anytype, comptime eighths: usize) @TypeOf(drawn.*) {
    @setEvalBranchQuota(200_000);
    var made = drawn.*;
    if (eighths == 0) return made;
    const angle: f64 = @as(f64, @floatFromInt(eighths)) * std_pi / 4.0;
    const cos = @cos(angle);
    const sin = @sin(angle);
    const middle_x: f64 = @as(f64, @floatFromInt(drawn.width)) / 2.0;
    const middle_y: f64 = @as(f64, @floatFromInt(drawn.height)) / 2.0;
    for (0..drawn.height) |y| {
        for (0..drawn.width) |x| {
            var opaque_points: u32 = 0;
            var sums = [3]u32{ 0, 0, 0 };
            for (0..4) |sy| {
                for (0..4) |sx| {
                    const dx = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4.0 - middle_x;
                    const dy = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4.0 - middle_y;
                    // Turned back: anticlockwise on the screen, whose y
                    // runs down.
                    const from_x = @floor(cos * dx + sin * dy + middle_x);
                    const from_y = @floor(-sin * dx + cos * dy + middle_y);
                    if (from_x < 0 or from_y < 0) continue;
                    const fx: usize = @intFromFloat(from_x);
                    const fy: usize = @intFromFloat(from_y);
                    if (fx >= drawn.width or fy >= drawn.height) continue;
                    const pixel = drawn.pixels[fy * drawn.width + fx];
                    if (pixel & 0xFF == 0) continue;
                    opaque_points += 1;
                    for (&sums, 0..) |*sum, c| sum.* += (pixel >> @intCast(24 - 8 * c)) & 0xFF;
                }
            }
            made.pixels[y * drawn.width + x] = if (opaque_points < 8) 0 else colour: {
                var pixel: u32 = 0xFF;
                for (sums, 0..) |sum, c| pixel |= (sum / opaque_points) << @intCast(24 - 8 * c);
                break :colour pixel;
            };
        }
    }
    return made;
}

/// pi, for the compiler's turning.
const std_pi: f64 = 3.14159265358979323846;

const default_hot = .{ 0, 0 };
const busy_hot = .{ busy_picture.width / 2, busy_picture.height / 2 };

/// A picture's pixels laid out as rgba32 is in memory - red, green, blue
/// and coverage, a byte each - from the values above, which are
/// 0xRRGGBBAA.
fn bytesOf(comptime made: anytype) [made.pixels.len * 4]u8 {
    var bytes: [made.pixels.len * 4]u8 = undefined;
    for (made.pixels, 0..) |pixel, i| {
        bytes[i * 4] = @truncate(pixel >> 24);
        bytes[i * 4 + 1] = @truncate(pixel >> 16);
        bytes[i * 4 + 2] = @truncate(pixel >> 8);
        bytes[i * 4 + 3] = @truncate(pixel);
    }
    return bytes;
}

const default_bytes = bytesOf(default_picture);
const busy_bytes = all: {
    @setEvalBranchQuota(100_000);
    var made: [busy_turn][busy_picture.pixels.len * 4]u8 = undefined;
    for (&made, 0..) |*frame, i| frame.* = bytesOf(busy_frames[i]);
    break :all made;
};

fn ownSurface(made: anytype, bytes: []const u8) rtg.Surface {
    return .{
        // Read only, by SetBoardPointer.
        .pixels = @constCast(bytes.ptr),
        .width = made.width,
        .height = made.height,
        .pitch = made.width * 4,
        .size_bytes = made.width * made.height * 4,
        .format = .rgba32,
    };
}

// --- which picture ------------------------------------------------------------------

/// The front screen, whose board the pointer is on.
fn frontScreen(ib: *IntuitionBase) ?*Screen {
    const first = ib.screen_list.head orelse return null;
    if (first.succ == null) return null;
    return @ptrCast(@alignCast(first));
}

/// Hand the board the picture it ought to have, and show it or not.
pub fn update(ib: *IntuitionBase) void {
    const rb = ib.rtg_base orelse return;
    const st = &ib.pointer;
    const board = if (frontScreen(ib)) |s| s.board else null;
    if (board != st.board) {
        if (st.board) |old| {
            if (st.shown != 0) _ = rb.ShowBoardPointer(old, false);
        }
        st.* = .{ .board = board, .mouse = st.mouse };
    }
    const now = board orelse return;
    if (now.info.caps & rtg.boards.RTGBC_POINTER == 0) return;

    var kind: Kind = .default;
    var object: ?*Object = null;
    if (ib.active_window) |w| {
        if (w.pointer_hidden != 0) {
            kind = .hidden;
        } else if (w.pointer_busy != 0) {
            kind = .busy;
        } else if (w.pointer) |o| {
            kind = .custom;
            object = o;
        }
    }
    // Hidden keeps whatever picture the board has: nothing is converted
    // for a pointer that is not seen.
    if (kind == .hidden) {
        st.kind = .hidden;
        st.object = null;
    } else if (kind != st.kind or object != st.object) {
        if (!give(ib, now, kind, object)) {
            // A picture the board will not take is the default one.
            kind = .default;
            object = null;
            _ = give(ib, now, kind, null);
        }
        st.kind = kind;
        st.object = object;
    }
    rb.MoveBoardPointer(now, ib.input.disp_x, ib.input.disp_y);
    const want: u8 = if (st.mouse != 0 and kind != .hidden) 1 else 0;
    if (want != st.shown and rb.ShowBoardPointer(now, want != 0) == rtg.errors.RTGERR_OK) st.shown = want;
}

/// One of the pictures to the board: whether it took it.
fn give(ib: *IntuitionBase, board: *rtg.RtgBoard, kind: Kind, object: ?*Object) bool {
    const rb = ib.rtg_base.?;
    switch (kind) {
        .default, .none, .hidden => {
            const surface = ownSurface(&default_picture, &default_bytes);
            return rb.SetBoardPointer(board, &surface, default_hot[0], default_hot[1]) == rtg.errors.RTGERR_OK;
        },
        .busy => {
            const surface = ownSurface(&busy_frames[0], &busy_bytes[ib.pointer.frame % busy_turn]);
            return rb.SetBoardPointer(board, &surface, busy_hot[0], busy_hot[1]) == rtg.errors.RTGERR_OK;
        },
        .custom => {
            const data = pointerclass.dataOf(ib, object.?);
            const surface = data.bitmap orelse return false;
            if (data.x_offset > 0 or data.y_offset > 0) return false;
            return rb.SetBoardPointer(board, surface, @intCast(-data.x_offset), @intCast(-data.y_offset)) == rtg.errors.RTGERR_OK;
        },
    }
}

// --- what changes it -----------------------------------------------------------------

/// A window's pointer set, now or after the delay. Under the screen
/// semaphore.
pub fn set(ib: *IntuitionBase, w: *Window, object: ?*Object, busy: bool, hidden: bool, delayed: bool) void {
    if (delayed) {
        w.deferred_pointer = object;
        w.deferred_busy = @intFromBool(busy);
        w.deferred_hidden = @intFromBool(hidden);
        w.deferred_ticks = delay_ticks;
        return;
    }
    w.deferred_ticks = 0;
    w.deferred_pointer = null;
    w.pointer = object;
    w.pointer_busy = @intFromBool(busy);
    w.pointer_hidden = @intFromBool(hidden);
    if (ib.active_window == w) update(ib);
}

/// A tick of input.device: the delayed changes that are due. Under the
/// screen semaphore.
pub fn tick(ib: *IntuitionBase) void {
    _window.eachWindow(ib, ib, struct {
        fn visit(base: *IntuitionBase, w: *Window) void {
            if (w.deferred_ticks == 0) return;
            w.deferred_ticks -= 1;
            if (w.deferred_ticks != 0) return;
            set(base, w, w.deferred_pointer, w.deferred_busy != 0, w.deferred_hidden != 0, false);
        }
    }.visit);
    turn(ib);
}

/// The busy ring an eighth of a turn on, if the board has it and its
/// screen moves. Under the screen semaphore.
fn turn(ib: *IntuitionBase) void {
    const st = &ib.pointer;
    if (st.kind != .busy) return;
    const screen = frontScreen(ib) orelse return;
    if (screen.draw_info.flags & sdk.intuition.screens.DRIF_STILL != 0) return;
    const board = st.board orelse return;
    st.frame = (st.frame + 1) % busy_turn;
    _ = give(ib, board, .busy, null);
}

/// A pointer event on intuition's task: shown, if a mouse has now been
/// seen and it is not yet, or if the front screen is on another board.
/// Under the screen semaphore.
pub fn followed(ib: *IntuitionBase) void {
    const st = &ib.pointer;
    const board = if (frontScreen(ib)) |s| s.board else null;
    if (board != st.board or (st.mouse != 0 and st.shown == 0)) return update(ib);
    if (board) |now| {
        if (ib.rtg_base) |rb| rb.MoveBoardPointer(now, ib.input.disp_x, ib.input.disp_y);
    }
}

/// In the input handler: the pointer to where the event says, handed to
/// the pointer's task - the position stored under its spinlock and the
/// task signalled. Never waits.
pub fn moved(ib: *IntuitionBase, x: i32, y: i32) void {
    const st = &ib.pointer_mover;
    if (st.mask == 0) return;
    const sys = ib.sys_base;
    sys.AcquireLock(&st.place_lock);
    st.place_x = x;
    st.place_y = y;
    sys.ReleaseLock(&st.place_lock);
    sys.Signal(&st.task, st.mask);
}

/// The pointer's task: the newest position the handler stored, put on the
/// board each time it is woken. Moves that came while it was moving are
/// one move, to the last of them.
fn pointerTask(sys: *exec.ExecBase) callconv(.c) void {
    const st: *Mover = @alignCast(@fieldParentPtr("task", sys.FindTask(null).?));
    const ib: *IntuitionBase = @alignCast(@fieldParentPtr("pointer_mover", st));
    const signal = sys.AllocSignal(-1);
    if (signal >= 0) st.mask = @as(u32, 1) << @intCast(signal);
    if (st.starter) |starter| {
        st.starter = null;
        sys.Signal(starter, @as(u32, 1) << @intCast(st.start_signal));
    }
    if (signal < 0) return;
    while (true) {
        _ = sys.Wait(st.mask);
        sys.AcquireLock(&st.place_lock);
        const x = st.place_x;
        const y = st.place_y;
        sys.ReleaseLock(&st.place_lock);
        const board = @as(*volatile ?*rtg.RtgBoard, &ib.pointer.board).* orelse continue;
        const rb = ib.rtg_base orelse continue;
        rb.MoveBoardPointer(board, x, y);
    }
}

/// The pointer's task started, before the input handler that feeds it is
/// added. Without it - no memory, no signal - the handler leaves the
/// pointer to intuition's task, which moves it on every event as well.
pub fn start(ib: *IntuitionBase) void {
    const st = &ib.pointer_mover;
    const sys = ib.sys_base;
    sys.InitLock(&st.place_lock, "intuition pointer", exec.LOCKORDER_DRIVER, 0);
    const stack = sys.AllocMem(task_stack, exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return;
    const signal = sys.AllocSignal(-1);
    if (signal < 0) {
        sys.FreeMem(stack, task_stack);
        return;
    }
    defer sys.FreeSignal(signal);
    st.task = .{
        .node = .{ .type = .task, .pri = task_pri, .name = "intuition pointer" },
        .sp_lower = @intFromPtr(stack),
        .sp_upper = @intFromPtr(stack) + task_stack,
    };
    st.starter = sys.FindTask(null);
    st.start_signal = signal;
    _ = sys.AddTask(&st.task, &pointerTask, null);
    _ = sys.Wait(@as(u32, 1) << @intCast(signal));
}

/// In the input handler: an event came from a mouse. The task shows the
/// pointer at the position event after it.
pub fn mouseSeen(ib: *IntuitionBase) void {
    @as(*volatile u8, &ib.pointer.mouse).* = 1;
}

/// A pointerclass object's attributes changed: shown again if it is the
/// one up.
pub fn changed(ib: *IntuitionBase, o: *Object) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    if (ib.pointer.object != o) return;
    ib.pointer.kind = .none;
    update(ib);
}

/// A pointerclass object is being disposed of: no window has it any more.
pub fn forget(ib: *IntuitionBase, o: *Object) void {
    _window.lock(ib);
    defer _window.unlock(ib);
    _window.eachWindow(ib, o, struct {
        fn visit(gone: *Object, w: *Window) void {
            if (w.pointer == gone) w.pointer = null;
            if (w.deferred_pointer == gone) w.deferred_pointer = null;
        }
    }.visit);
    if (ib.pointer.object == o) update(ib);
}
