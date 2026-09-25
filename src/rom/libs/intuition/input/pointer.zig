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
//! It moves in intuition's input handler, on input.device's task, as each
//! event arrives: `MoveBoardPointer` never waits, and following it there
//! rather than on intuition's own task keeps it moving while that task is
//! busy dragging a window. The task sees the same event after and moves it
//! to the same place, which the board takes as no move.
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
//! `WA_PointerDelay` puts a change off for three of input.device's ticks,
//! a tenth of a second each (`tick`), and a change made before then calls
//! it off: a busy pointer put up for work that ends at once never shows.
//!
//! Everything here runs under the screen semaphore, except `moved` and
//! `mouseSeen`, which the handler calls.

const sdk = @import("sdk");
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
    pad: [2]u8 = .{ 0, 0 },
};

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
const busy_picture = picture(&.{
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

const default_hot = .{ 0, 0 };
const busy_hot = .{ busy_picture.width / 2, busy_picture.height / 2 };

fn ownSurface(made: anytype) rtg.Surface {
    return .{
        // Read only, by SetBoardPointer.
        .pixels = @ptrCast(@constCast(&made.pixels)),
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
    rb.MoveBoardPointer(now, ib.input.x, ib.input.y);
    const want: u8 = if (st.mouse != 0 and kind != .hidden) 1 else 0;
    if (want != st.shown and rb.ShowBoardPointer(now, want != 0) == rtg.errors.RTGERR_OK) st.shown = want;
}

/// One of the pictures to the board: whether it took it.
fn give(ib: *IntuitionBase, board: *rtg.RtgBoard, kind: Kind, object: ?*Object) bool {
    const rb = ib.rtg_base.?;
    switch (kind) {
        .default, .none, .hidden => {
            const surface = ownSurface(&default_picture);
            return rb.SetBoardPointer(board, &surface, default_hot[0], default_hot[1]) == rtg.errors.RTGERR_OK;
        },
        .busy => {
            const surface = ownSurface(&busy_picture);
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
}

/// A pointer event on intuition's task: shown, if a mouse has now been
/// seen and it is not yet, or if the front screen is on another board.
/// Under the screen semaphore.
pub fn followed(ib: *IntuitionBase) void {
    const st = &ib.pointer;
    const board = if (frontScreen(ib)) |s| s.board else null;
    if (board != st.board or (st.mouse != 0 and st.shown == 0)) return update(ib);
    if (board) |now| {
        if (ib.rtg_base) |rb| rb.MoveBoardPointer(now, ib.input.x, ib.input.y);
    }
}

/// In the input handler: the pointer to where the event says. Never
/// waits, takes no lock.
pub fn moved(ib: *IntuitionBase, x: i32, y: i32) void {
    const board = @as(*volatile ?*rtg.RtgBoard, &ib.pointer.board).* orelse return;
    const rb = ib.rtg_base orelse return;
    rb.MoveBoardPointer(board, x, y);
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
