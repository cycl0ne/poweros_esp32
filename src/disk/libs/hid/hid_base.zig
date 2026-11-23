// SPDX-License-Identifier: MIT
//! hid.library's base, shared by every opener: exec's Library header,
//! what it was loaded from, and utility.library, which reads OpenHID's
//! tags and calls a driver's hook.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const HIDBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    utility: *UtilityBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
};

pub fn hidBase(lib: *exec.Library) *HIDBase {
    return @fieldParentPtr("lib", lib);
}
