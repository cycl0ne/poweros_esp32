// SPDX-License-Identifier: MIT
//! facet.library's base: exec's Library header and what the library
//! keeps beside it. There is one base, shared by every opener; what a
//! program makes - its instance, its devices and all made from them - is
//! the program's, and hangs off none of it.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const FacetBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back by the Expunge.
    seg_list: ?*anyopaque = null,
    /// The instances not yet destroyed: while there are any the library
    /// stays, whoever has closed it.
    instances: u32 = 0,
    /// Set by the host tests, whose exec runs no task but theirs: a
    /// queue's work is played by the task that submits it, and a device
    /// starts no task.
    inline_queues: bool = false,
    /// What the V3D's driver keeps while any device has it, and what guards
    /// its coming and going.
    v3d: ?*anyopaque = null,
    v3d_lock: exec.SignalSemaphore = .{},
};

pub fn facetBase(lib: *exec.Library) *FacetBase {
    return @fieldParentPtr("lib", lib);
}
