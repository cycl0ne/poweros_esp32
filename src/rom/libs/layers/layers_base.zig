// SPDX-License-Identifier: MPL-2.0
//! layers.library as a library: its base, and the Expunge vector that
//! keeps it in memory.

const sdk = @import("sdk");
const exec = sdk.exec;
const ExecBase = sdk.interface.exec.ExecBase;
const UtilityBase = sdk.interface.utility.UtilityBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const RtgBase = sdk.interface.rtg.RtgBase;
const graphics = sdk.graphics;

/// The base: everything about the library that can change.
///
/// A library's memory is exec's, not the image's, so nothing here may
/// become a global. What a caller holds is the `lib` field, handed out as
/// the opaque `sdk.interface.layers.LayersBase`.
pub const LayersBase = extern struct {
    /// The Library header, with the jump table in front of it.
    lib: exec.Library,
    /// SysBase. Every call this library makes to exec goes through it.
    sys_base: *ExecBase,
    /// utility.library, opened by the init and kept: a layer is asked for
    /// with tags, and the tag calls are utility's.
    utility_base: *UtilityBase,
    /// graphics.library, opened by the init and kept: the regions the
    /// tiling is done with are its, and so is the RastPort a layer draws
    /// through. This is what keeps a caller from needing either.
    graphics_base: *GraphicsBase,
    /// rtg.library, opened by the init and kept: a composed layer's own
    /// buffer is attached to its display's board, so that the board's
    /// engine draws in it as it does on the display, and what is drawn in
    /// it is told to this library rather than to the board.
    rtg_base: *RtgBase,

    /// This library as a caller sees it, to call its own functions through
    /// the jump table.
    pub fn iface(lb: *LayersBase) *sdk.interface.layers.LayersBase {
        return @ptrCast(lb);
    }

    /// A new region for the tiling, the system's: what layers keeps for a
    /// layer - what of it is seen, what it is owed - outlives the call
    /// that made it, and whichever task moved a window made it. Its
    /// rectangles are graphics' own, from its pool.
    pub fn newRegion(lb: *LayersBase) ?*graphics.Region {
        const region = lb.graphics_base.NewRegion() orelse return null;
        _ = lb.sys_base.SetMemOwner(region, null);
        return region;
    }
};

/// A ROM library stays: its code is in the image and its base costs a few
/// words, so there is nothing to win by taking it off the list.
///
/// INPUTS:
/// - `lib` - the library, unused.
///
/// RESULT:
/// Null: nothing is given back.
pub fn expunge(lib: *exec.Library) callconv(.c) ?*anyopaque {
    _ = lib;
    return null;
}
