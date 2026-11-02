// SPDX-License-Identifier: MIT
//! media.library's base: exec's Library header, what it was loaded
//! from, and the libraries it works through - dos.library for files,
//! utility.library for tags. There is one base, shared by every opener;
//! a file opened is its opener's own.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const MediaBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    utility_base: *UtilityBase,
    /// The container modules found in LIBS:codecs/ (modules/_modules.zig's
    /// Table), read when a file is first opened, and the table the next
    /// reading is built in; both under `modules_lock`.
    modules: ?*anyopaque = null,
    scratch: ?*anyopaque = null,
    modules_lock: exec.SignalSemaphore = .{},
};

pub fn mediaBase(lib: *exec.Library) *MediaBase {
    return @fieldParentPtr("lib", lib);
}
