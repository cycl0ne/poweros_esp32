// SPDX-License-Identifier: MIT
//! paintio.library's base, shared by every opener: exec's Library header,
//! what it was loaded from, and dos.library. The libraries a call works
//! with besides - iffparse, compression, datatypes and intuition - are
//! opened by the call and closed before it answers, so a program that
//! only reads projects never brings in datatypes.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const DosBase = sdk.interface.dos.DosBase;

pub const PaintIOBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    /// What LoadSeg made, handed back at the expunge.
    seg_list: ?*anyopaque = null,
    dos_base: *DosBase,
};

pub fn paintIOBase(lib: *exec.Library) *PaintIOBase {
    return @fieldParentPtr("lib", lib);
}

/// The library as its own callers see it: its calls through its jump
/// table.
pub fn iface(base: *PaintIOBase) *sdk.interface.paintio.PaintIOBase {
    return @ptrCast(base);
}
