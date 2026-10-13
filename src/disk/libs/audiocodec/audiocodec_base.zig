// SPDX-License-Identifier: MIT
//! audiocodec.library's base: exec's Library header, what it was loaded
//! from, and the libraries it works through - dos.library for files,
//! utility.library for tags. There is one base, shared by every opener;
//! a stream is its opener's own.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const AudioCodecBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    utility_base: *UtilityBase,
};

pub fn audioCodecBase(lib: *exec.Library) *AudioCodecBase {
    return @fieldParentPtr("lib", lib);
}
