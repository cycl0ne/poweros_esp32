// SPDX-License-Identifier: MIT
//! v3d.fdriver: facet.library's driver of the BCM2712's V3D, a module in
//! LIBS:facet/. The library opens it and reads its table from the base
//! (driver/_driver.zig); the driver is driver/v3d/.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const vec = exec.vec;
const ExecBase = sdk.interface.exec.ExecBase;
const _driver = @import("driver/_driver.zig");
const v3d_driver = @import("driver/v3d/driver.zig");
const facet_version = @import("facet_version.zig");

const LIBRARY_NAME = "v3d.fdriver";
const LIBRARY_VERSION = facet_version.LIBRARY_VERSION;
const LIBRARY_REVISION = facet_version.LIBRARY_REVISION;
const BUILD_DATE = "01.11.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

const Base = _driver.ModuleBase;

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base: *Base = @alignCast(@fieldParentPtr("lib", lib));
    const header = lib.*;
    base.* = .{ .lib = header, .stamp = _driver.stamp, .ops = &v3d_driver.ops, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// It goes when nobody has it open: the base freed, and the file it was loaded
/// from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const base: *Base = @alignCast(@fieldParentPtr("lib", lib));
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

const vectors = [_]*const anyopaque{
    vec(exec.libOpen),
    vec(exec.libClose),
    vec(expunge),
    vec(exec.libExtFunc),
};

const init_table = exec.InitTable{
    .data_size = @sizeOf(Base),
    .vectors = &vectors,
    .vector_count = vectors.len,
    .init = &init,
};

/// AUTOINIT: on the disk in LIBS:facet/, made when facet.library opens it -
/// ramlib loads the file and hands this tag to InitResident. In `.resident`,
/// which program.ld KEEPs.
pub export const v3d_fdriver_tag: exec.Resident linksection(".resident") = .{
    .match_tag = @ptrCast(&v3d_fdriver_tag),
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};

/// A module is not a command.
export fn _program_entry(sys: *ExecBase, args: [*]const u8, len: usize) callconv(.c) i32 {
    _ = args;
    _ = len;
    exec.kprintf(sys, "%s is facet.library's driver, not a command\n", .{LIBRARY_NAME});
    return 20; // RETURN_FAIL, without opening dos.library to say it
}

/// The "$VER:" string, which `Version <file>` looks for.
export const version_tag: [LIBRARY_VERSION_STRING.len:0]u8 linksection(".version") = LIBRARY_VERSION_STRING.*;

comptime {
    _ = &v3d_fdriver_tag;
}
