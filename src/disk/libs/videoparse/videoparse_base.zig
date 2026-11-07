// SPDX-License-Identifier: MIT
//! videoparse.library's base: exec's Library header, what it was loaded
//! from, and utility.library, which reads the tags. There is one base,
//! shared by every opener; a parser is its opener's own.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const VideoParseBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    utility_base: *UtilityBase,
};

pub fn videoParseBase(lib: *exec.Library) *VideoParseBase {
    return @fieldParentPtr("lib", lib);
}
