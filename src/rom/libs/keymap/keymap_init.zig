// SPDX-License-Identifier: MPL-2.0
//! keymap.library's ROM tag, and the init routine it names: the ROM's
//! keymaps on the list, "deutsch" the default.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const km = sdk.keymap;
const ExecBase = sdk.interface.exec.ExecBase;
const keymap_lvo = @import("keymap_lvo.zig");
const KeymapBase = @import("keymap_base.zig").KeymapBase;
const usa = @import("usa.zig");
const deutsch = @import("deutsch.zig");

/// The name it is opened by. The SDK's.
pub const LIBRARY_NAME = km.KEYMAPNAME;
pub const LIBRARY_VERSION = 0;
/// 1: MapRawKey, MapANSI, the default, FindKeyMap; "usa" and "deutsch".
pub const LIBRARY_REVISION = 1;
const BUILD_DATE = "20.9.2026";
const LIBRARY_VERSION_STRING =
    "\x00$VER: " ++ LIBRARY_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ LIBRARY_VERSION, LIBRARY_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn keymapBase(lib: *exec.Library) *KeymapBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// LibInit: the ROM's keymaps on the list, "deutsch" the default.
///
/// INPUTS:
/// - `lib` - the base exec made from the init table.
/// - `seg_list` - null: a module in the ROM has no segments.
/// - `sys_base` - SysBase, kept in the base.
///
/// RESULT:
/// The base; nothing here can fail.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Forbid: not held. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const kb = keymapBase(lib);
    lib.revision = LIBRARY_REVISION;
    kb.sys_base = sys_base;
    kb.maps.init(.unknown);
    kb.rom = .{
        .{ .node = .{ .name = "deutsch" }, .key_map = deutsch.key_map },
        .{ .node = .{ .name = "usa" }, .key_map = usa.key_map },
    };
    for (&kb.rom) |*node| sys_base.AddTail(&kb.maps, &node.node);
    kb.default = &kb.rom[0].key_map;
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(KeymapBase),
    .vectors = &keymap_lvo.vectors,
    .vector_count = keymap_lvo.vectors.len,
    .init = &init,
};

/// Cold start, early: it needs nothing, and input handlers and intuition
/// open it.
pub export const keymap_library_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &keymap_library_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = LIBRARY_VERSION,
    .pri = 40,
    .type = .library,
    .name = LIBRARY_NAME,
    .id_string = LIBRARY_VERSION_STRING[1..],
    .init = &init_table,
};
