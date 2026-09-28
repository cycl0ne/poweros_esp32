// SPDX-License-Identifier: MIT
//! truetype.library's base: exec's Library header and what it was loaded
//! as. Everything a call works on - an outline, a rendering - is the
//! caller's or made for the call, so one base is shared by every opener
//! and holds nothing else.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const TrueTypeBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
};

/// The base from exec's Library header.
pub fn trueTypeBase(lib: *exec.Library) *TrueTypeBase {
    return @fieldParentPtr("lib", lib);
}
