// SPDX-License-Identifier: MIT
//! icon.library's base, shared by every opener: exec's Library header,
//! what it was loaded from, dos.library, the default icons read so far,
//! and datatypes.library once a file's group has been asked.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const DataTypesBase = sdk.interface.datatypes.DataTypesBase;
const Default = @import("default/_default.zig").Default;
const default_count = @import("default/_default.zig").count;

pub const IconBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    /// The defaults read so far and datatypes.library: under `defaults_lock`,
    /// a semaphore, since filling a default reads a file.
    defaults_lock: exec.SignalSemaphore = .{},
    defaults: [default_count]Default = @splat(.{}),
    datatypes_base: ?*DataTypesBase = null,
    /// datatypes.library has been asked for, and is not asked again.
    datatypes_tried: u8 = 0,
    pad: [3]u8 = .{ 0, 0, 0 },
    /// The count of each picture's users: a spinlock, since giving a
    /// picture back is quick and happens on any task.
    users_lock: exec.Lock = .{},
};

pub fn iconBase(lib: *exec.Library) *IconBase {
    return @fieldParentPtr("lib", lib);
}

/// The library as its own callers see it: its calls through its jump
/// table.
pub fn interface(base: *IconBase) *sdk.interface.icon.IconBase {
    return @ptrCast(base);
}
