// SPDX-License-Identifier: MIT
//! truetypeshaping.library's base: exec's Library header, what it was
//! loaded as, and truetype.library, through which every font is read.
//! What a call works on - the run, the buffer it shapes in - is the
//! caller's or made for the call, so one base is shared by every opener
//! and holds nothing else.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const TrueTypeBase = sdk.interface.truetype.TrueTypeBase;

pub const TrueTypeShapingBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// Opened at init, closed at Expunge.
    truetype_base: *TrueTypeBase,
};

/// The base from exec's Library header.
pub fn trueTypeShapingBase(lib: *exec.Library) *TrueTypeShapingBase {
    return @fieldParentPtr("lib", lib);
}
