// SPDX-License-Identifier: MIT
//! diskfont.library's ROM tag, its init and its Expunge. Open and Close
//! are exec's standard ones: every opener shares the one base.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const diskfont = sdk.diskfont;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("diskfont_base.zig");
const DiskfontBase = _base.DiskfontBase;
const _font = @import("font/_font.zig");
const diskfont_lvo = @import("diskfont_lvo.zig");

pub const LIBRARY_NAME = diskfont.DISKFONTNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "28.09.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

/// The low-memory handler's place among exec's: before exec's own, which
/// expunges whole libraries - a font nobody holds is the cheaper thing to
/// read again.
const flusher_priority = 10;

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const dfb = _base.diskfontBase(lib);
    const header = lib.*;
    const utility_lib = sys_base.OpenLibrary(sdk.interface.utility.NAME, 0) orelse return null;
    const dos_lib = sys_base.OpenLibrary(sdk.dos.DOSNAME, 0) orelse {
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    const graphics_lib = sys_base.OpenLibrary(sdk.graphics.GRAPHICSNAME, 0) orelse {
        sys_base.CloseLibrary(dos_lib);
        sys_base.CloseLibrary(utility_lib);
        return null;
    };
    dfb.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .dos_base = @ptrCast(dos_lib),
        .graphics_base = @ptrCast(graphics_lib),
        .utility_base = @ptrCast(utility_lib),
    };
    lib.revision = LIBRARY_REVISION;
    dfb.fonts.init(.unknown);
    sys_base.InitSemaphore(&dfb.load_lock);
    dfb.flusher = .{
        .node = .{ .type = .interrupt, .pri = flusher_priority, .name = LIBRARY_NAME },
        .data = dfb,
        .code = @ptrCast(&_font.flushFonts),
    };
    sys_base.AddMemHandler(&dfb.flusher);
    return lib;
}

/// Gone once nobody has it open and every font it made has gone - which
/// it tries first, freeing each that nobody holds. A font still held
/// keeps it: its memory is the library's.
fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const dfb = _base.diskfontBase(lib);
    const sys = dfb.sys_base;
    if (lib.open_cnt != 0) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    // Inside AllocMem when exec flushes, whose caller may hold anything:
    // nothing here waits.
    if (!sys.AttemptSemaphore(&dfb.load_lock)) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    while (_font.freeOne(dfb)) {}
    const empty = dfb.fonts.isEmpty();
    sys.ReleaseSemaphore(&dfb.load_lock);
    if (!empty) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    sys.RemMemHandler(&dfb.flusher);
    if (dfb.truetype_base) |tb| sys.CloseLibrary(tb.lib());
    sys.CloseLibrary(dfb.graphics_base.lib());
    sys.CloseLibrary(dfb.dos_base.lib());
    sys.CloseLibrary(dfb.utility_base.lib());
    const seg_list = dfb.seg_list;
    sys.DetachLibrary(lib);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(DiskfontBase),
    .vectors = &diskfont_lvo.vectors,
    .vector_count = diskfont_lvo.vectors.len,
    .init = &init,
};

pub export const diskfont_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &diskfont_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
