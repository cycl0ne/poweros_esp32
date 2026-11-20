// SPDX-License-Identifier: MIT
//! json.library's base, shared by every opener: exec's Library header and
//! what it was loaded from. The calls need exec for the memory a document
//! is made in, and dos.library - opened for the call - for a file.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const JSONBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

pub fn jsonBase(lib: *exec.Library) *JSONBase {
    return @fieldParentPtr("lib", lib);
}
