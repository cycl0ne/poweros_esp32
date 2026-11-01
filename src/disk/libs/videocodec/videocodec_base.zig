// SPDX-License-Identifier: MIT
//! videocodec.library's base: exec's Library header, what it was loaded
//! from, and the libraries every stream works through - dos.library and
//! utility.library. There is one base, shared by every opener; a stream
//! opened is its opener's own, with the libraries it opened for itself.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;
const UtilityBase = sdk.interface.utility.UtilityBase;

pub const VideoCodecBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
    utility_base: *UtilityBase,
    /// The codec modules found in LIBS:codecs/ (codec/_codec.zig's
    /// Table), read when a film is first opened; under `modules_lock`.
    modules: ?*anyopaque = null,
    modules_lock: exec.SignalSemaphore = .{},
};

pub fn videoCodecBase(lib: *exec.Library) *VideoCodecBase {
    return @fieldParentPtr("lib", lib);
}
