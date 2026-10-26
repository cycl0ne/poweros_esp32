// SPDX-License-Identifier: MIT
//! compression.library's base: exec's Library header and the handles it
//! keeps. There is one base, shared by every opener: a stream's state is
//! the caller's, hanging off its Stream.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const CompressionBase = extern struct {
    lib: exec.Library,
    /// For a stream's state and window, allocated on the caller's task.
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

pub fn compressionBase(lib: *exec.Library) *CompressionBase {
    return @fieldParentPtr("lib", lib);
}

/// The library's own jump table, for a call that uses another of its
/// calls: those go through the table like anyone's.
pub fn iface(cb: *CompressionBase) *sdk.interface.compression.CompressionBase {
    return @ptrCast(cb);
}
