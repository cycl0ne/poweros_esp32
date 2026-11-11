// SPDX-License-Identifier: MIT
//! diskfont.library's base: exec's Library header, the libraries it works
//! through, the fonts and outlines it has loaded, the lock that loads them
//! one at a time, the low-memory handler that frees the ones nobody
//! holds, and the fallback families of the font being opened.
//! There is one base, shared by every opener.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const _font = @import("font/_font.zig");

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
    /// The outlines it opened (since 1.4): their records
    /// (`outline/_outline.zig`), linked by `link`.
    outlines: exec.List = .{},
    /// truetype.library, opened the first time an outline is rendered or
    /// opened, and kept until expunge.
    truetype_base: ?*sdk.interface.truetype.TrueTypeBase = null,
    /// The fallback families `font.prefs` names (since 1.8), in its
    /// order, each NUL-terminated: read by the first font an OpenDiskFont
    /// makes and good for that call, under the load lock.
    fallback_names: [sdk.graphics.FONT_FALLBACKS][_font.MAXFONTNAME]u8 = @splat(@splat(0)),
    /// How many of them there are.
    fallback_count: u32 = 0,
    /// Whether this OpenDiskFont has read them.
    fallbacks_read: bool = false,
    /// How many fonts are being given their fallbacks, one inside the
    /// other: a family made as a fallback is given its own.
    fallback_depth: u8 = 0,
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
