// SPDX-License-Identifier: MIT
//! Where a drawer's window has been, for Back and Forward: the drawers it
//! showed before the one it shows (`back`, the last first) and, once it
//! has gone back, those it had gone on to (`forward`, the next first).
//!
//! A window that turns to another drawer in place (`_drawer.browse`) keeps
//! the one it leaves to go back to and forgets what was ahead (`left`); a
//! step back keeps the one it leaves to go forward to again, and a step
//! forward keeps it to go back to (`stepBack`, `stepForward`). A window
//! that opens each drawer in a window of its own never turns, and has
//! nothing to go back to. Each list keeps at most `kept_most`, the oldest
//! let go. A drawer kept is a block of its own, its path after it.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

/// The most drawers kept each way.
pub const kept_most = 32;

/// A drawer the window showed: its path follows the block.
const Visit = struct {
    node: exec.Node = .{},
    length: usize,

    fn path(visit: *Visit) []const u8 {
        const bytes: [*]u8 = @ptrCast(visit);
        return (bytes + @sizeOf(Visit))[0..visit.length];
    }
};

pub const History = struct {
    back: exec.List = .{},
    forward: exec.List = .{},

    /// Nothing either way, as a window opens.
    pub fn init(history: *History) void {
        history.back.init(.unknown);
        history.forward.init(.unknown);
    }

    /// The window turned from the drawer `here` to another, neither back
    /// nor forward: `here` kept to go back to, what was ahead forgotten.
    pub fn left(history: *History, sys: *ExecBase, here: []const u8) void {
        drop(sys, &history.forward);
        keep(sys, &history.back, here);
    }

    /// Whether there is a drawer to go back to.
    pub fn canGoBack(history: *History) bool {
        return !history.back.isEmpty();
    }

    /// Whether there is a drawer to go forward to again.
    pub fn canGoForward(history: *History) bool {
        return !history.forward.isEmpty();
    }

    /// A step back from the drawer `here`: the drawer to turn to, written
    /// into `into`, and `here` kept to go forward to again. Null with
    /// nothing behind.
    pub fn stepBack(history: *History, sys: *ExecBase, here: []const u8, into: []u8) ?[]const u8 {
        return step(sys, &history.back, &history.forward, here, into);
    }

    /// A step forward from the drawer `here`, after a step back: the drawer
    /// to turn to, written into `into`, and `here` kept to go back to. Null
    /// with nothing ahead.
    pub fn stepForward(history: *History, sys: *ExecBase, here: []const u8, into: []u8) ?[]const u8 {
        return step(sys, &history.forward, &history.back, here, into);
    }

    /// Every drawer kept let go, as the window closes.
    pub fn free(history: *History, sys: *ExecBase) void {
        drop(sys, &history.back);
        drop(sys, &history.forward);
    }
};

/// The first of `from` taken off and written into `into`, `here` kept on
/// `to`: what to turn to, or null when `from` is empty.
fn step(sys: *ExecBase, from: *exec.List, to: *exec.List, here: []const u8, into: []u8) ?[]const u8 {
    const node = sys.RemHead(from) orelse return null;
    const visit: *Visit = @alignCast(@fieldParentPtr("node", node));
    defer sys.FreeVec(visit);
    const path = visit.path();
    if (path.len > into.len) return null;
    @memcpy(into[0..path.len], path);
    keep(sys, to, here);
    return into[0..path.len];
}

/// `path` put first on `list`, the last let go past `kept_most`; nothing
/// kept without the memory.
fn keep(sys: *ExecBase, list: *exec.List, path: []const u8) void {
    const memory = sys.AllocVec(@sizeOf(Visit) + path.len, exec.MEMF_ANY) orelse return;
    const visit: *Visit = @ptrCast(@alignCast(memory));
    visit.* = .{ .length = path.len };
    const bytes: [*]u8 = @ptrCast(visit);
    @memcpy((bytes + @sizeOf(Visit))[0..path.len], path);
    sys.AddHead(list, &visit.node);
    var kept: usize = 0;
    var it = list.iterator();
    while (it.next()) |_| kept += 1;
    if (kept <= kept_most) return;
    if (sys.RemTail(list)) |last| sys.FreeVec(@as(*Visit, @alignCast(@fieldParentPtr("node", last))));
}

/// Everything on `list` let go.
fn drop(sys: *ExecBase, list: *exec.List) void {
    while (sys.RemHead(list)) |node| sys.FreeVec(@as(*Visit, @alignCast(@fieldParentPtr("node", node))));
}
