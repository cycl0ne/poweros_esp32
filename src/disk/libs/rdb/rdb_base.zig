// SPDX-License-Identifier: MIT
//! rdb.library's base: exec's Library header, exec's handle, and whether
//! a node MountPartition made holds on to the library. There is one base,
//! shared by every opener: what a disk's table is lives in the opener's
//! RDBHandle, not here.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const RDBBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    /// MountPartition has put a node on dos's list. A node names its
    /// handler by a string the library holds, so the library stays for the
    /// system's life from then on.
    mounted: bool = false,
};

pub fn rdbBase(lib: *exec.Library) *RDBBase {
    return @fieldParentPtr("lib", lib);
}
