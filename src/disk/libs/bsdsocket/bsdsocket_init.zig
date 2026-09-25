// SPDX-License-Identifier: MIT
//! bsdsocket.library's ROM tag, and the four standard vectors: the init
//! that makes the stack, the Open that makes an opener its own base, the
//! Close that takes one down, and the Expunge.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const bsd = sdk.bsdsocket;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("bsdsocket_base.zig");
const StackBase = _base.StackBase;
const SocketBase = _base.SocketBase;
const Socket = @import("socket/_socket.zig").Socket;
const _socket = @import("socket/_socket.zig");
const _netif = @import("netif/_netif.zig");
const bsdsocket_lvo = @import("bsdsocket_lvo.zig");

pub const LIBRARY_NAME = bsd.SOCKETNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "25.09.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The stack: its lists, its lock, the frame pool and `lo0`. The stack's
/// base is the one on exec's list, which nobody is handed: Open answers
/// each opener a base of its own.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const stack = _base.stackBase(lib);
    const header = lib.*;
    stack.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    stack.utility = @ptrCast(utility_lib);
    sys_base.InitSemaphore(&stack.lock);
    stack.sockets.init(.unknown);
    stack.frames.init();
    _netif.addLoopback(stack);
    return lib;
}

/// A base of the opener's own: the same jump table, with its descriptor
/// table, its error number and its readiness signal. It runs on the
/// opener's task, under OpenLibrary's Forbid, so the signal is the
/// opener's. Null when there is no memory or no signal free.
fn open(lib: *exec.Library, version: u32) callconv(.c) ?*exec.Library {
    _ = version;
    const stack = _base.stackBase(lib);
    const sys = stack.sys_base;
    const task = sys.FindTask(null) orelse return null;
    const copy = sys.MakeLibrary(&bsdsocket_lvo.vectors, bsdsocket_lvo.vectors.len, @sizeOf(SocketBase), null, null) orelse return null;
    const sb = _base.socketBase(copy);
    var header = copy.*;
    header.node.name = lib.node.name;
    header.version = lib.version;
    header.revision = lib.revision;
    header.id_string = lib.id_string;
    header.open_cnt = 1;
    sb.* = .{ .lib = header, .stack = stack, .sys_base = sys, .task = task };
    const signal = sys.AllocSignal(-1);
    if (signal < 0) return freeCopy(sb);
    sb.ready_signal = signal;
    sb.ready_mask = @as(u32, 1) << @intCast(signal);
    const table = sys.AllocMem(_base.table_size_default * @sizeOf(?*Socket), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        sys.FreeSignal(signal);
        return freeCopy(sb);
    };
    sb.table = @ptrCast(@alignCast(table));
    sb.table_size = _base.table_size_default;
    lib.open_cnt += 1;
    lib.flags &= ~exec.LIBF_DELEXP;
    return copy;
}

fn freeCopy(sb: *SocketBase) ?*exec.Library {
    const lib = &sb.lib;
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sb.sys_base.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return null;
}

/// An opener's base taken down: its sockets closed, its signal, table and
/// timer given back, and the base freed. The last close of a stack
/// marked for expunging expunges it.
fn close(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const sb = _base.socketBase(lib);
    const stack = sb.stack;
    const sys = sb.sys_base;
    _socket.destroyAll(sb);
    _socket.closeTimer(sb);
    sys.FreeSignal(sb.ready_signal);
    sys.FreeMem(@ptrCast(sb.table), sb.table_size * @sizeOf(?*Socket));
    _ = freeCopy(sb);
    stack.lib.open_cnt -= 1;
    if (stack.lib.open_cnt == 0 and stack.lib.flags & exec.LIBF_DELEXP != 0) return expunge(&stack.lib);
    return null;
}

/// The stack goes when nobody has it open: its frames and its base freed,
/// and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const stack = _base.stackBase(lib);
    const sys = stack.sys_base;
    const seg_list = stack.seg_list;
    stack.frames.deinit(sys);
    if (stack.utility) |utility| sys.CloseLibrary(utility.lib());
    sys.Remove(&lib.node);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const openVector = open;
pub const closeVector = close;
pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(StackBase),
    .vectors = &bsdsocket_lvo.vectors,
    .vector_count = bsdsocket_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
pub export const bsdsocket_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &bsdsocket_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
