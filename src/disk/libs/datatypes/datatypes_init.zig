// SPDX-License-Identifier: MIT
//! datatypes.library's ROM tag, its init, its Open and its Expunge.
//!
//! The first opener brings up everything a data type object is built
//! from - dos, utility, intuition, graphics and iffparse - finds the
//! list `C:AddDataTypes` published, and makes datatypesclass. Without
//! the list there is nothing to recognise anything by, so the open
//! fails and says so; the startup-sequence runs AddDataTypes before
//! anything gets that far.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const dos = sdk.dos;
const utility = sdk.utility;
const intuition = sdk.intuition;
const graphics = sdk.graphics;
const iffparse = sdk.iffparse;
const datatypes = sdk.datatypes;
const ExecBase = sdk.interface.exec.ExecBase;
const _base = @import("datatypes_base.zig");
const DataTypesBase = _base.DataTypesBase;
const datatypes_lvo = @import("datatypes_lvo.zig");
const _class = @import("class/_class.zig");

pub const LIBRARY_NAME = datatypes.DATATYPESNAME;
pub const LIBRARY_VERSION = 1;
pub const LIBRARY_REVISION = 0;
const BUILD_DATE = "29.09.2026";
pub const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    const db = _base.dtBase(lib);
    const header = lib.*;
    db.* = .{
        .lib = header,
        .sys_base = sys_base,
        .seg_list = seg_list,
        .dos_base = undefined,
        .utility_base = undefined,
        .intuition_base = undefined,
        .graphics_base = undefined,
        .iffparse_base = undefined,
    };
    lib.revision = LIBRARY_REVISION;
    return lib;
}

/// What the library opened, closed again in the order it opened them.
fn closeAll(db: *DataTypesBase, how_far: usize) void {
    const sys = db.sys_base;
    const opened = [_]*exec.Library{
        @ptrCast(@alignCast(db.dos_base)),
        @ptrCast(@alignCast(db.utility_base)),
        @ptrCast(@alignCast(db.intuition_base)),
        @ptrCast(@alignCast(db.graphics_base)),
        @ptrCast(@alignCast(db.iffparse_base)),
    };
    var i = how_far;
    while (i > 0) {
        i -= 1;
        sys.CloseLibrary(opened[i]);
    }
}

fn open(lib: *exec.Library) callconv(.c) ?*exec.Library {
    const db = _base.dtBase(lib);
    const sys = db.sys_base;
    if (lib.open_cnt == 0) {
        const wanted = [_][*:0]const u8{
            dos.DOSNAME,
            utility.UTILITYNAME,
            intuition.INTUITIONNAME,
            graphics.GRAPHICSNAME,
            iffparse.IFFPARSENAME,
        };
        var bases: [wanted.len]?*exec.Library = @splat(null);
        for (wanted, 0..) |name, i| {
            bases[i] = sys.OpenLibrary(name, 0) orelse {
                var back = i;
                while (back > 0) {
                    back -= 1;
                    sys.CloseLibrary(bases[back]);
                }
                return null;
            };
        }
        db.dos_base = @ptrCast(bases[0]);
        db.utility_base = @ptrCast(bases[1]);
        db.intuition_base = @ptrCast(bases[2]);
        db.graphics_base = @ptrCast(bases[3]);
        db.iffparse_base = @ptrCast(bases[4]);

        // The list is C:AddDataTypes's, found by name. Without it
        // nothing can be recognised, so the open fails rather than
        // leaving a library that answers null to everything.
        const ub = db.utility_base;
        const named = ub.FindNamedObject(null, datatypes.DATATYPESLIST_NAME, null) orelse {
            closeAll(db, wanted.len);
            return null;
        };
        db.list = @ptrCast(@alignCast(named.object));
        ub.ReleaseNamedObject(named);
        if (db.list == null) {
            closeAll(db, wanted.len);
            return null;
        }
        db.class = _class.make(db) orelse {
            db.list = null;
            closeAll(db, wanted.len);
            return null;
        };
    }
    lib.open_cnt += 1;
    lib.flags &= ~exec.LIBF_DELEXP;
    return lib;
}

fn close(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const db = _base.dtBase(lib);
    if (lib.open_cnt != 0) lib.open_cnt -= 1;
    if (lib.open_cnt != 0) return null;
    // The class stays while objects of it, or of a subclass, are out.
    if (db.class) |cl| {
        if (db.intuition_base.FreeClass(cl)) db.class = null;
    }
    if (db.class == null) {
        db.list = null;
        closeAll(db, 5);
    }
    if (lib.flags & exec.LIBF_DELEXP == 0) return null;
    return expunge(lib);
}

fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    const db = _base.dtBase(lib);
    if (lib.open_cnt != 0 or db.class != null) {
        lib.flags |= exec.LIBF_DELEXP;
        return null;
    }
    const sys = db.sys_base;
    const seg_list = db.seg_list;
    if (lib.node.pred != null) sys.Remove(&lib.node);
    const start: *anyopaque = @ptrFromInt(@intFromPtr(lib) - lib.neg_size);
    sys.FreeMem(start, @as(usize, lib.neg_size) + lib.pos_size);
    return seg_list;
}

pub const openVector = open;
pub const closeVector = close;
pub const expungeVector = expunge;

const init_table = exec.InitTable{
    .data_size = @sizeOf(DataTypesBase),
    .vectors = &datatypes_lvo.vectors,
    .vector_count = datatypes_lvo.vectors.len,
    .init = &init,
};

pub export const datatypes_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &datatypes_library_tag,
    .flags = exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .type = .library,
    .pri = 0,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..], // past the NUL: a C string
    .init = &init_table,
};
