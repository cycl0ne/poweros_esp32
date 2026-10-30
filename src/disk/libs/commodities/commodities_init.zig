// SPDX-License-Identifier: MIT
//! commodities.library's ROM tag, its init, its Open, Close and Expunge.
//!
//! The library opens keymap.library when it is first opened itself:
//! ParseIX and InvertKeyMap ask it which key types a character. The
//! handler is not put on input.device's chain here but when the first
//! broker is made, so a program that only reads the broker list costs
//! the input stream nothing. The library stays while a broker is on its
//! list, opened or not: the handler on input.device's chain is its code.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const keymap = sdk.keymap;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("commodities_base.zig");
const _input = @import("input/_input.zig");
const _message = @import("message/_message.zig");
const CxBase = _base.CxBase;
const commodities_lvo = @import("commodities_lvo.zig");

pub const LIBRARY_NAME = sdk.commodities.COMMODITIESNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "30.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.cxBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    base.brokers.init(.unknown);
    base.queue.init(.message);
    base.held.init(.message);
    base.routing.init(.message);
    base.returned.init(.message);
    base.reply_port = .{ .flags = exec.PA_IGNORE };
    base.reply_port.msg_list.init(.message);
    sys_base.InitSemaphore(&base.lock);
    sys_base.InitSemaphore(&base.handler_lock);
    sys_base.InitLock(&base.queue_lock, "commodities queue", exec.LOCKORDER_DRIVER, 0);
    lib.revision = LIBRARY_REVISION;
    return lib;
}

fn open(lib: *exec.Library) callconv(.c) ?*exec.Library {
    const base = _base.cxBase(lib);
    if (lib.open_cnt == 0) {
        const keymap_lib = base.sys_base.OpenLibrary(keymap.KEYMAPNAME, 0) orelse return null;
        base.keymap_base = @ptrCast(keymap_lib);
    }
    lib.open_cnt += 1;
    lib.flags &= ~exec.LIBF_DELEXP;
    return lib;
}

fn close(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const base = _base.cxBase(lib);
    const sys = base.sys_base;
    if (lib.open_cnt != 0) lib.open_cnt -= 1;
    if (lib.open_cnt != 0) return null;
    if (base.keymap_base) |kb| sys.CloseLibrary(@ptrCast(@alignCast(kb)));
    base.keymap_base = null;
    _message.freeReplied(base);
    // A delayed expunge is CloseLibrary's, once this has answered.
    return null;
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const base = _base.cxBase(lib);
    if (lib.open_cnt != 0 or base.handler_on != 0 or !base.brokers.isEmpty()) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = base.sys_base;
    _input.drain(base);
    const seg_list = base.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const openVector = open;
pub const closeVector = close;
pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(CxBase),
    .vectors = &commodities_lvo.vectors,
    .vector_count = commodities_lvo.vectors.len,
    .init = &init,
};

pub export const commodities_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &commodities_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
