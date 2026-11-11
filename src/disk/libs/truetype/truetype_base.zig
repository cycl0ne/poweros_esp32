// SPDX-License-Identifier: MIT
//! truetype.library's base: exec's Library header, what it was loaded
//! as, and utility.library, which reads `OpenOutline`'s tags. Everything
//! a call works on - an outline, a rendering - is the caller's or made
//! for the call, so one base is shared by every opener and holds nothing
//! else.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const TrueTypeBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    /// Opened at init, closed at Expunge.
    utility_base: *UtilityBase,
};

/// The base from exec's Library header.
pub fn trueTypeBase(lib: *exec.Library) *TrueTypeBase {
    return @fieldParentPtr("lib", lib);
}
