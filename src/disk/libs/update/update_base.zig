// SPDX-License-Identifier: MIT
//! update.library's base, shared by every opener: exec's Library header,
//! what it was loaded from, and dos.library and utility.library, which
//! every run calls. A run's own state is the run's (`run/_run.zig`).

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const UpdateBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    utility_base: *UtilityBase,
};

pub fn updateBase(lib: *exec.Library) *UpdateBase {
    return @fieldParentPtr("lib", lib);
}
