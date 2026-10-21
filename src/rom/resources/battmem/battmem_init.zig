// SPDX-License-Identifier: MPL-2.0
//! battmem.resource's ROM tag, and the init routine it names: the bits
//! found where the chip keeps them, and cleared when they do not add up.

const std = @import("std");
const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const battmem_lvo = @import("battmem_lvo.zig");
const BattMemBase = @import("battmem_base.zig").BattMemBase;
const _bits = @import("bits/_bits.zig");

/// The name it is opened by. The SDK's.
pub const RESOURCE_NAME = sdk.resources.battmem.BATTMEMNAME;
pub const RESOURCE_VERSION = 1;
pub const RESOURCE_REVISION = 0;
const BUILD_DATE = "20.10.2026";
const RESOURCE_VERSION_STRING =
    "\x00$VER: " ++ RESOURCE_NAME ++ " " ++
    std.fmt.comptimePrint("{d}.{d}", .{ RESOURCE_VERSION, RESOURCE_REVISION }) ++
    " (" ++ BUILD_DATE ++ ")\r\n";

fn battMemBase(lib: *exec.Library) *BattMemBase {
    return @alignCast(@fieldParentPtr("lib", lib));
}

/// ResInit: the bits where the chip keeps them - what a reset left there,
/// or all 0 after a power-on, a reset in the middle of a write, or on a
/// chip that keeps nothing over a reset.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no; it runs on the exec task at cold start.
/// - Locks: none needed. - Process: a Task will do.
fn init(lib: *exec.Library, seg_list: ?*anyopaque, sys_base: *ExecBase) callconv(.c) ?*exec.Library {
    _ = seg_list;
    const mb = battMemBase(lib);
    lib.revision = RESOURCE_REVISION;
    mb.sys_base = sys_base;
    mb.own = .{ .magic = 0, .checksum = 0, .bytes = @splat(0) };
    sys_base.InitSemaphore(&mb.lock);
    mb.store = _bits.storeOf(mb);
    _bits.settle(mb.store);
    return lib;
}

const init_table = exec.InitTable{
    .data_size = @sizeOf(BattMemBase),
    .vectors = &battmem_lvo.vectors,
    .vector_count = battmem_lvo.vectors.len,
    .init = &init,
};

/// Cold start at 80: it needs nothing but exec, and is there before
/// anything that keeps a setting in it - the file systems, which read the
/// time zone from it.
pub export const battmem_resource_tag: exec.Resident linksection(".resident") = .{
    .match_tag = &battmem_resource_tag,
    .flags = exec.RTF_COLDSTART | exec.RTF_AUTOINIT,
    .version = RESOURCE_VERSION,
    .type = .resource,
    .pri = 80,
    .name = RESOURCE_NAME,
    .id_string = RESOURCE_VERSION_STRING[1..],
    .init = &init_table,
};
