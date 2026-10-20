// SPDX-License-Identifier: MIT
//! facet.library's ROM tag, its init and its Expunge. Open and Close are
//! exec's standard ones: every opener shares the one base.
//!
//! The init only fills in the base: what draws is described when a
//! program makes an instance, and everything else is made by the program
//! from that. The library goes when nobody has it open and no instance is
//! left: a device's queue runs the library's code on a task of its own,
//! which may outlast the program's hold on the library.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const facet = sdk.facet;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("facet_base.zig");
const FacetBase = _base.FacetBase;
const facet_lvo = @import("facet_lvo.zig");

pub const LIBRARY_NAME = facet.FACETNAME;
pub const LIBRARY_VERSION = 1;
/// 1: a window closed under its surface is found gone, never drawn into,
/// and the surface answers `error_surface_lost` (intuition 0.47's
/// window numbers); the depth pre-pass, a pipeline's own
/// (`PIPELINE_CREATE_DEPTH_PREPASS`).
/// 2: displays of 565 and colour attachments of R5G6B5: the tiles stay
/// 8 bits a channel, dithered 4 x 4 into 16 bits as they are stored;
/// command buffers recorded on the 32-bit chips too, whose chunks put
/// the commands 4 bytes off the 8 they are aligned to.
/// 3: a window's pixels read from intuition 0.48 (`WA_PixelFormat`).
pub const LIBRARY_REVISION = 3;
const BUILD_DATE = "20.10.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The base filled in.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const base = _base.facetBase(lib);
    const header = lib.*;
    base.* = .{ .lib = header, .sys_base = sys_base, .seg_list = seg_list };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// The library goes when nobody has it open and every instance is gone:
/// the base freed, and the file it was loaded from handed back.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const base = _base.facetBase(lib);
    if (lib.open_cnt != 0 or @atomicLoad(u32, &base.instances, .monotonic) != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = base.sys_base;
    const seg_list = base.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(FacetBase),
    .vectors = &facet_lvo.vectors,
    .vector_count = facet_lvo.vectors.len,
    .init = &init,
};

/// AUTOINIT: the library is on the disk, in LIBS:, and is made when
/// something opens it - ramlib loads the file and hands this tag to
/// InitResident. In `.resident`, which program.ld KEEPs.
pub export const facet_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &facet_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
