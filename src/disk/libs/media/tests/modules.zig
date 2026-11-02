// SPDX-License-Identifier: MIT
//! The container modules for a host test: each made from its ROM tag, under
//! the name ramlib finds it by on a disk, as exec's own search looks for
//! it. Taken away with the library.

const sdk = @import("sdk");
const exec = sdk.exec;
const mp4_init = @import("../mp4/mp4_init.zig");
const mkv_init = @import("../mkv/mkv_init.zig");

const ExecBase = sdk.interface.exec.ExecBase;

const tags = [_]struct { tag: *const exec.Resident, name: [*:0]const u8 }{
    .{ .tag = &mp4_init.mp4_container_tag.resident, .name = "codecs/mp4.container" },
    .{ .tag = &mkv_init.mkv_container_tag.resident, .name = "codecs/mkv.container" },
};

pub const Made = [tags.len]*exec.Library;

/// MP4's module, among them.
pub const mp4 = 0;

pub fn make(kexec: anytype, made: *Made) !void {
    for (tags, made) |entry, *lib| {
        const library = kexec.InitResident(kexec.SysBase, entry.tag, null) orelse return error.NoLibrary;
        lib.* = @ptrCast(@alignCast(library));
        lib.*.node.name = entry.name;
    }
}

pub fn take(sys: *ExecBase, made: *const Made) void {
    for (made) |lib| _ = sys.RemLibrary(lib);
}
