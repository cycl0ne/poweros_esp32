// SPDX-License-Identifier: MIT
//! diskfont.library's base: exec's Library header, the libraries it works
//! through, the fonts it has loaded, the lock that loads them one at a
//! time, and the low-memory handler that frees the ones nobody holds.
//! There is one base, shared by every opener.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;

pub const DiskfontBase = extern struct {
    lib: exec.Library,
    sys_base: *ExecBase,
    seg_list: ?*anyopaque = null,
    dos_base: *sdk.interface.dos.DosBase,
    graphics_base: *sdk.interface.graphics.GraphicsBase,
    utility_base: *sdk.interface.utility.UtilityBase,
    /// Every font it loaded or scaled and put on graphics' list: their
    /// records (`font/_font.zig`), linked by `link`.
    fonts: exec.List = .{},
    /// Held while a font is loaded or a record leaves the list, so one
    /// OpenDiskFont at a time reads the disk and the low-memory handler
    /// never frees what is being set up.
    load_lock: exec.SignalSemaphore = .{},
    /// On exec's low-memory list from init to expunge.
    flusher: exec.Interrupt = .{},
    /// truetype.library, opened the first time an outline is rendered and
    /// kept until expunge.
    truetype_base: ?*sdk.interface.truetype.TrueTypeBase = null,
};

/// The base from exec's Library header.
pub fn diskfontBase(lib: *exec.Library) *DiskfontBase {
    return @fieldParentPtr("lib", lib);
}

/// The base as the SDK's interface has it: how the library calls its own
/// functions, through its jump table.
pub fn iface(dfb: *DiskfontBase) *sdk.interface.diskfont.DiskfontBase {
    return @ptrCast(dfb);
}
