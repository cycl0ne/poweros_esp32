// SPDX-License-Identifier: MIT
//! paintfx.library's base, shared by every opener: exec's Library header
//! and what it was loaded from. The calls need nothing besides exec, for
//! the memory a blur or a scale works in.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const PaintFXBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

pub fn paintFXBase(lib: *exec.Library) *PaintFXBase {
    return @fieldParentPtr("lib", lib);
}
