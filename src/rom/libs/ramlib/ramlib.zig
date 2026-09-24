// SPDX-License-Identifier: MPL-2.0
//! ramlib.library: libraries and devices that are not in the ROM, loaded
//! from the disk when something asks for them.
//!
//! `OpenLibrary` and `OpenDevice` look on exec's lists and answer null for
//! a name that is not there. This module puts itself in front of both: it
//! replaces the two vectors in exec's own jump table (`SetFunction`), calls
//! what it replaced first, and only when that comes back empty does it go
//! looking - `LIBS:` for a library, `DEVS:` for a device - loads the file
//! with `LoadSeg`, finds the ROM tag in it and lets `InitResident` make the
//! thing. The second attempt then finds it on the list like any other.
//!
//! A load is disk work: it opens files, waits on a handler and takes as
//! long as a file system takes. A process can do that itself, and does. A
//! bare task cannot - dos wants a process to hang its context on - so the
//! work goes to this module's own process through a message port, and the
//! task waits for the answer. That is the whole reason for the process.
//!
//! The base is ramlib_base.zig, the ROM tag and init ramlib_init.zig, the
//! table - the four standard vectors - ramlib_lvo.zig; this file is what
//! stands in front of exec, and loader.zig does the loading.
//!
//! Where its state lives: the base exec allocates for it. The process is
//! handed it at creation as its tc_UserData (NP_UserData). A replaced
//! vector runs on whatever task is opening something, with exec's
//! arguments and no context of its own, so the one pointer it needs is the
//! one exec keeps with `SetRamLib`.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const dos = sdk.dos;
const vec = exec.vec;

const loader = @import("loader.zig");

/// ramlib.library's base (ramlib_base.zig).
const ramlib_base = @import("ramlib_base.zig");
/// ramlib.library's ROM tag and init routine (ramlib_init.zig).
const ramlib_init = @import("ramlib_init.zig");

// The tag is an export in .resident, found there by its address; this
// keeps it in whatever is built from ramlib.library.
comptime {
    _ = &ramlib_init.ramlib_library_tag;
}

/// The library's base, which the loader works on.
pub const RamLibBase = ramlib_base.RamLibBase;
/// What the library is on exec's list as.
pub const LIBRARY_NAME = ramlib_init.LIBRARY_NAME;

/// What is being asked for.
pub const KIND_LIBRARY: u32 = 0;
pub const KIND_DEVICE: u32 = 1;

/// A module that came off the disk, and the segments it is in.
pub const Loaded = struct {
    node: exec.Node = .{},
    seg_list: ?*dos.SegList = null,
    name_buf: [64]u8 = .{0} ** 64,
};

/// What a task asks the process to do.
const LoadMessage = extern struct {
    message: exec.Message = .{},
    name: [*:0]const u8,
    kind: u32,
    version: u32,
    loaded: u8 = 0,
};

/// The one pointer exec keeps for this module, which is how a replaced
/// vector finds everything else.
fn ourBase(sys: *ExecBase) ?*RamLibBase {
    return @ptrCast(@alignCast(sys.RamLib() orelse return null));
}

// --- what stands in front of exec --------------------------------------------

/// exec's OpenLibrary, with a look on the disk when the list has not got
/// it. The replaced vector is called first, so a library that is already
/// there costs one indirect call and nothing else.
pub fn openLibrary(sys: *ExecBase, name: [*:0]const u8, version: u32) callconv(.c) ?*exec.Library {
    const rlb = ourBase(sys) orelse return null;
    const old: *const fn (*ExecBase, [*:0]const u8, u32) callconv(.c) ?*exec.Library =
        @ptrCast(@alignCast(rlb.old_open_library.?));
    if (old(sys, name, version)) |lib| return lib;
    if (!fetch(rlb, name, KIND_LIBRARY, version)) return null;
    return old(sys, name, version);
}

/// The same for devices. A device answers with an error code rather than a
/// pointer, and anything but zero is a failure worth looking on the disk
/// for.
pub fn openDevice(sys: *ExecBase, name: [*:0]const u8, unit: u32, io: *exec.IORequest, flags: u32) callconv(.c) i32 {
    const rlb = ourBase(sys) orelse return exec.IOERR_OPENFAIL;
    const old: *const fn (*ExecBase, [*:0]const u8, u32, *exec.IORequest, u32) callconv(.c) i32 =
        @ptrCast(@alignCast(rlb.old_open_device.?));
    const answer = old(sys, name, unit, io, flags);
    if (answer == 0) return answer;
    if (!fetch(rlb, name, KIND_DEVICE, 0)) return answer;
    return old(sys, name, unit, io, flags);
}

/// Get it from the disk, whoever is asking. A process does it itself; a
/// bare task has no dos context to do it with, so it asks the process and
/// waits.
fn fetch(rlb: *RamLibBase, name: [*:0]const u8, kind: u32, version: u32) bool {
    const sys = rlb.sys_base;
    const task = sys.FindTask(null) orelse return false;
    if (task.node.type == .process) return loader.load(rlb, name, kind, version);

    // Before the process has made its port there is nobody to ask, which
    // is only ever true of the residents that start between this one and
    // the process's first breath.
    const port = rlb.port orelse return false;
    const reply = sys.CreateMsgPort() orelse return false;
    defer sys.DeleteMsgPort(reply);

    var request = LoadMessage{
        .message = .{ .node = .{ .type = .message }, .reply_port = reply, .length = @sizeOf(LoadMessage) },
        .name = name,
        .kind = kind,
        .version = version,
    };
    sys.PutMsg(port, &request.message);
    _ = sys.WaitPort(reply);
    while (sys.GetMsg(reply) != null) {}
    return request.loaded != 0;
}

/// The process: one load at a time, in the order they were asked for. Its
/// base came with it, as its tc_UserData.
pub fn server(sys: *ExecBase) callconv(.c) void {
    const rlb: *RamLibBase = @ptrCast(@alignCast(sys.FindTask(null).?.user_data orelse return));
    const port = sys.CreateMsgPort() orelse return;
    rlb.port = port;
    while (true) {
        _ = sys.WaitPort(port);
        while (sys.GetMsg(port)) |message| {
            const request: *LoadMessage = @ptrCast(@alignCast(message));
            request.loaded = @intFromBool(loader.load(rlb, request.name, request.kind, request.version));
            sys.ReplyMsg(message);
        }
    }
}

// --- tests (host: ./zig build test) -----------------------------------------

test {
    _ = ramlib_base;
    _ = ramlib_init;
    _ = @import("ramlib_lvo.zig");
    _ = loader;
}
