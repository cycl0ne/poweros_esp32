// SPDX-License-Identifier: MIT
//! A window files can be dropped on: the desktop's AppWindow, for a
//! program that wants nothing more of it than the name of each file let
//! go there.
//!
//! The program adds its window once it is open (`add`), waits for
//! `signal()` beside its window's, takes each drop with `next`, and gives
//! it all up before the window closes (`remove`). Without the desktop -
//! or without anvil.library - `add` does nothing, `signal()` is 0 and
//! `next` finds nothing, so a program need not ask which it is.
//!
//!   var target: sdk.anvil.DropTarget = .{};
//!   target.add(sys, window);
//!   defer target.remove();
//!   ...
//!   _ = ib.WaitIMsg(window, target.signal() | exec.SIGBREAKF_CTRL_C);
//!   var name: [dos.path_max + 1]u8 = undefined;
//!   while (target.next(dl, &name)) |dropped| show(dropped.name);
//!
//! A drop of several files gives the first; the others are let go.

const exec = @import("../exec/exec.zig");
const intuition = @import("../intuition/intuition.zig");
const anvil = @import("anvil.zig");
const ExecBase = @import("../../interface/exec.zig").ExecBase;
const DosBase = @import("../../interface/dos.zig").DosBase;
const AnvilBase = @import("../../interface/anvil.zig").AnvilBase;

/// A file dropped.
pub const Dropped = struct {
    /// Its full name, in the buffer `next` was given.
    name: [*:0]const u8,
    /// A drawer or a disk, which comes as a lock on itself and no name.
    is_drawer: bool,
};

pub const DropTarget = struct {
    sys: ?*ExecBase = null,
    library: ?*exec.Library = null,
    port: ?*exec.MsgPort = null,
    app: ?*anvil.AppWindow = null,

    /// `window` made one files can be dropped on, when the desktop runs.
    pub fn add(target: *DropTarget, sys: *ExecBase, window: *intuition.Window) void {
        const library = sys.OpenLibrary(anvil.ANVILNAME, 1) orelse return;
        const port = sys.CreateMsgPort() orelse {
            sys.CloseLibrary(library);
            return;
        };
        const ab: *AnvilBase = @ptrCast(library);
        const app = ab.AddAppWindow(0, 0, window, port, null) orelse {
            sys.DeleteMsgPort(port);
            sys.CloseLibrary(library);
            return;
        };
        target.* = .{ .sys = sys, .library = library, .port = port, .app = app };
    }

    /// The signal a drop comes with; 0 without one to wait for.
    pub fn signal(target: *const DropTarget) u32 {
        const port = target.port orelse return 0;
        return port.sigMask();
    }

    /// The next file dropped, its full name made in `into`, and the
    /// desktop's message replied; null when none waits.
    pub fn next(target: *DropTarget, dl: *DosBase, into: []u8) ?Dropped {
        const sys = target.sys orelse return null;
        const port = target.port orelse return null;
        while (sys.GetMsg(port)) |message| {
            const am: *anvil.AppMessage = @fieldParentPtr("message", message);
            defer sys.ReplyMsg(message);
            if (am.num_args == 0) continue;
            const first = am.arg_list.?[0];
            if (!dl.NameFromLock(first.lock, into.ptr, @intCast(into.len))) continue;
            const name = first.name orelse "";
            const is_drawer = name[0] == 0;
            if (!is_drawer and !dl.AddPart(@ptrCast(into.ptr), name, @intCast(into.len))) continue;
            return .{ .name = @ptrCast(into.ptr), .is_drawer = is_drawer };
        }
        return null;
    }

    /// The window taken off the desktop's list - nothing is sent for it
    /// after this - what came meanwhile replied, and the port and the
    /// library let go.
    pub fn remove(target: *DropTarget) void {
        const sys = target.sys orelse return;
        if (target.library) |library| {
            const ab: *AnvilBase = @ptrCast(library);
            _ = ab.RemoveAppWindow(target.app);
        }
        if (target.port) |port| {
            while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
            sys.DeleteMsgPort(port);
        }
        if (target.library) |library| sys.CloseLibrary(library);
        target.* = .{};
    }
};
