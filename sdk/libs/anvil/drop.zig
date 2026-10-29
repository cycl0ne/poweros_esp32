// SPDX-License-Identifier: MIT
//! A window files can be dropped on: the desktop's AppWindow, for a
//! program that wants nothing more of it than the name of each file let
//! go there.
//!
//! The program adds its window once it is open (`add`), waits for
//! `signal()` beside its window's, takes each drop with `next`, and gives
//! it all up before the window closes (`remove`). Without the desktop -
//! or without anvil.library - `add` does nothing, `signal()` is 0 and
//! `next` finds nothing, so a program need not ask which it is. When the
//! desktop quits, `next` replies its word of it (`AMTYPE_QUIT`) and finds
//! nothing more.
//!
//!   var target: sdk.anvil.DropTarget = .{};
//!   target.add(sys, window);
//!   defer target.remove();
//!   ...
//!   _ = ib.WaitIMsg(window, target.signal() | exec.SIGBREAKF_CTRL_C);
//!   var name: [dos.path_max + 1]u8 = undefined;
//!   while (target.next(dl, &name)) |dropped| show(dropped.name);
//!
//! A drop of several files gives the first, and the others are let go -
//! right for a program that shows one file. One that takes a list sets
//! `all`, and `next` then gives every file of a drop in turn.

const exec = @import("../exec/exec.zig");
const dos = @import("../dos/dos.zig");
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
    /// Every file of a drop handed out, one at each `next`, rather than
    /// the first alone: set by a program that takes a list.
    all: bool = false,
    /// The drop whose files are being handed out, and how many of them
    /// have been; it is replied at the call after its last.
    held: ?*anvil.AppMessage = null,
    taken: u32 = 0,

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
        target.* = .{ .sys = sys, .library = library, .port = port, .app = app, .all = target.all };
    }

    /// The signal a drop comes with; 0 without one to wait for.
    pub fn signal(target: *const DropTarget) u32 {
        const port = target.port orelse return 0;
        return port.sigMask();
    }

    /// The next file dropped, its full name made in `into`; null when
    /// none waits, and every drop handed out has then been replied.
    pub fn next(target: *DropTarget, dl: *DosBase, into: []u8) ?Dropped {
        while (target.nextFile()) |file| {
            if (!dl.NameFromLock(file.lock, into.ptr, @intCast(into.len))) continue;
            const name = file.name orelse "";
            const is_drawer = name[0] == 0;
            if (!is_drawer and !dl.AddPart(@ptrCast(into.ptr), name, @intCast(into.len))) continue;
            return .{ .name = @ptrCast(into.ptr), .is_drawer = is_drawer };
        }
        return null;
    }

    /// The next file dropped as the desktop gave it - the lock on its
    /// drawer and its name there, which hold until the call after - or
    /// null when none waits. The first file of each drop, or with `all`
    /// each in turn; a drop is replied at the call after its last file is
    /// handed out, so a loop to null leaves none unreplied.
    pub fn nextFile(target: *DropTarget) ?dos.WBArg {
        const sys = target.sys orelse return null;
        const port = target.port orelse return null;
        while (true) {
            if (target.held) |held| {
                const count = if (held.arg_list != null) held.num_args else 0;
                if (target.taken < count and (target.all or target.taken == 0)) {
                    target.taken += 1;
                    return held.arg_list.?[target.taken - 1];
                }
                target.held = null;
                sys.ReplyMsg(&held.message);
            }
            const message = sys.GetMsg(port) orelse return null;
            target.held = @fieldParentPtr("message", message);
            target.taken = 0;
        }
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
        if (target.held) |held| sys.ReplyMsg(&held.message);
        if (target.port) |port| {
            while (sys.GetMsg(port)) |message| sys.ReplyMsg(message);
            sys.DeleteMsgPort(port);
        }
        if (target.library) |library| sys.CloseLibrary(library);
        target.* = .{ .all = target.all };
    }
};
