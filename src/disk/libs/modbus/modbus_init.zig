// SPDX-License-Identifier: MIT
//! modbus.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const modbus = sdk.modbus;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("modbus_base.zig");
const ModbusBase = _base.ModbusBase;
const modbus_lvo = @import("modbus_lvo.zig");

pub const LIBRARY_NAME = modbus.MODBUSNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "03.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in and utility.library opened. Without it there is
/// no library: null, and exec frees the base.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.modbusBase(lib);
    const header = lib.*;
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 1) orelse return null;
    base.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .utility_base = @ptrCast(utility_lib),
    };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// The library goes when nobody has it open: utility.library closed,
/// the base freed, and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base = _base.modbusBase(lib);
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    sys.CloseLibrary(@ptrCast(@alignCast(base.utility_base)));
    if (lib.node.pred != null) sys.Remove(&lib.node);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(ModbusBase),
    .vectors = &modbus_lvo.vectors,
    .vector_count = modbus_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
pub export const modbus_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &modbus_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
