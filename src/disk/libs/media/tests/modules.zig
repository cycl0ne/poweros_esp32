// SPDX-License-Identifier: MIT
//! The container modules for a host test: each made from its ROM tag, under
//! the name ramlib finds it by on a disk, as exec's own search looks for
//! it. Taken away with the library.
//!
//! The library would read what each reads out of the module's file on the
//! disk; a host test has no such files, so the table it would have read
//! is handed to it (`container_table.test_modules`) - made out of the very
//! tags the modules carry.

const sdk = @import("sdk");
const exec = sdk.exec;
const mp4_init = @import("../mp4/mp4_init.zig");
const mkv_init = @import("../mkv/mkv_init.zig");

const ExecBase = sdk.interface.exec.ExecBase;
const mcontainer = sdk.mcontainer;
const modtable = sdk.dos.modtable;
const container_table = @import("../modules/_modules.zig");

const tags = [_]struct { tag: *const mcontainer.ResidentMContainer, name: [*:0]const u8 }{
    .{ .tag = &mp4_init.mp4_container_tag, .name = "codecs/mp4.container" },
    .{ .tag = &mkv_init.mkv_container_tag, .name = "codecs/mkv.container" },
};

pub const Made = [tags.len]*exec.Library;

/// MP4's module, among them.
pub const mp4 = 0;

/// The table the library would have read from LIBS:codecs/.
var rows: [tags.len]modtable.Found = @splat(.{});

pub fn make(kexec: anytype, made: *Made) !void {
    for (tags, made, &rows) |entry, *lib, *row| {
        const library = kexec.InitResident(kexec.SysBase, &entry.tag.resident, null) orelse return error.NoLibrary;
        lib.* = @ptrCast(@alignCast(library));
        lib.*.node.name = entry.name;
        row.* = container_table.row(nameOf(entry.name), entry.tag.kinds, entry.tag.priority);
    }
    container_table.test_modules = &rows;
}

/// The table handed to the library as a disk with no module for `kind` on
/// it would read. In force until `showAll` or `take`.
pub fn hide(kind: u32) void {
    const bit = mcontainer.kindBit(kind);
    var count: usize = 0;
    for (rows) |row| {
        if (container_table.kindsOf(&row) & bit != 0) continue;
        fewer[count] = row;
        count += 1;
    }
    container_table.test_modules = fewer[0..count];
}

/// Every module there again.
pub fn showAll() void {
    container_table.test_modules = &rows;
}

var fewer: [tags.len]modtable.Found = @splat(.{});

fn nameOf(name: [*:0]const u8) []const u8 {
    var length: usize = 0;
    while (name[length] != 0) length += 1;
    return name[0..length];
}

pub fn take(sys: *ExecBase, made: *const Made) void {
    container_table.test_modules = null;
    for (made) |lib| _ = sys.RemLibrary(lib);
}
