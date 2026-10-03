// SPDX-License-Identifier: MIT
//! rdb.library's base: exec's Library header and the handles it keeps.
//! There is one base, shared by every opener: what a disk's table is
//! lives in the opener's RDBHandle, not here.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const RDBBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

pub fn rdbBase(lib: *exec.Library) *RDBBase {
    return @fieldParentPtr("lib", lib);
}
