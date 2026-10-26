// SPDX-License-Identifier: MPL-2.0
//! What a LayerInfo and a Layer are made of, and the pool and region
//! helpers every area of the library uses.
//!
//! Both are this library's alone - the SDK has them as opaque types - so
//! everything about them can change for as long as the system lives.
//!
//! A LayerInfo is the layers of one display, front to back, and the things
//! they all share: the buffer they are drawn on, the pool their clip
//! targets come from, and the locks. A Layer is one window's worth: where
//! it is, what of it can be seen, what it still owes a redraw, and the
//! RastPort that draws it.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const layers = sdk.layers;
const rtg = sdk.rtg;
const utility = sdk.utility;
const ExecBase = sdk.interface.exec.ExecBase;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const LayersBase = @import("../layers.zig").LayersBase;
const effects = @import("../compose/_effects.zig");
const Rect = graphics.Rect;

/// Every layer of one display.
pub const LayerInfo = struct {
    /// The layers, frontmost first. A `Layer`'s `node` is on this.
    layers: exec.List = .{},
    /// Every layer's own lock, so `LockLayers` can take them all in one
    /// `ObtainSemaphoreList` instead of one at a time, which two callers
    /// going opposite ways would deadlock on.
    locks: exec.List = .{},
    /// The lock over the list itself: which layers there are and in what
    /// order.
    lock: exec.SignalSemaphore = .{},
    /// How deep `LockLayers` is nested.
    locked_all: u32 = 0,
    /// Where the clip targets come from. A retile builds every layer's
    /// list again, so they are small, many, and taken and given back in
    /// bursts - which is what a pool is for.
    pool: ?*anyopaque = null,
    /// The display: how big it is, and where its pixels are.
    bounds: Rect = .{},
    surface: *rtg.Surface,
    /// The board's buffer, when the display is one: the engine and the
    /// hand-on after a write are its.
    bitmap: ?*rtg.bitmaps.RtgBitMap = null,
    /// A RastPort on the display, this library's own. Putting a covered
    /// piece back when it is uncovered is a blit on to the display, and it
    /// has to be clipped to the display and handed on to the board
    /// afterwards - which is what a RastPort does and a bare surface does
    /// not. The caller's own RastPort is not used: it belongs to the
    /// caller, who may have set a clip on it.
    display_rp: ?*graphics.RastPort = null,
    /// The library, so a layer can reach exec and graphics from anything
    /// that has only the layer.
    lb: *anyopaque,
    /// A count each look at a layer's stores moves on, so that a store
    /// several pieces share is counted once (`Store.visit`).
    visit: u32 = 0,
    /// Each layer draws into a buffer of its own, which is copied on to
    /// the display (`LATAG_Compose`, compose/_compose.zig). Never set on
    /// a machine the composing is not built for.
    compose: bool = false,
    /// Composed, as the last retile left it: some layer is seen through
    /// (`LATAG_Opacity`), and some layer's shadow can be seen
    /// (compose/_effects.zig).
    veiled: bool = false,
    shaded: bool = false,
    /// The pictures of the shadows in use, one a size, kept until the
    /// LayerInfo goes.
    shadows: ?*effects.Shadow = null,
};

/// The buffer a layer of a composed LayerInfo draws into: a handle on
/// the display's board, so its engine draws there, and the memory behind
/// it when this library allocated it - none for a super layer, whose
/// buffer is its own bitmap.
pub const Buffer = struct {
    bitmap: *rtg.RtgBitMap,
    /// What exec gave, and how much: the pixels start in it at the first
    /// cache line.
    memory: ?*anyopaque = null,
    bytes: usize = 0,
};

/// A surface a covered part of a layer was put into. It stays as long as
/// any of that part is still covered: the pieces that are share it, and
/// the last of them to go frees it.
pub const Store = struct {
    surface: *rtg.Surface,
    /// Where the surface's (0,0) is, in the **layer's** coordinates.
    x: i32,
    y: i32,
    /// How many pieces keep their pixels in it.
    refs: u32 = 0,
    /// The `LayerInfo.visit` it was last counted at.
    visit: u32 = 0,
};

/// A piece of a layer that is covered, and where its pixels are being kept
/// while it is. Only a `LAYERSMART` layer has any: with the simple refresh
/// the pixels are simply lost.
pub const Kept = struct {
    next: ?*Kept = null,
    /// What of the layer this is, in the **layer's** coordinates: a part
    /// of what its store holds.
    area: Rect = .{},
    store: *Store,
};

/// One window's worth of a display.
pub const Layer = struct {
    /// On the LayerInfo's list, frontmost first.
    node: exec.Node = .{},
    info: *LayerInfo,
    /// Where it is, in the display's coordinates.
    bounds: Rect = .{},
    /// `LAYER*`.
    flags: u32 = 0,
    /// What draws into it. Its coordinates are the layer's own, and its
    /// clip targets are what this library puts there.
    rp: *graphics.RastPort,
    /// What of the layer is not covered, in the **display's** coordinates,
    /// which is the space the tiling works in.
    visible: *graphics.Region,
    /// What has been uncovered and not yet drawn again, in the **layer's**
    /// coordinates, which is the space its program works in.
    damage: *graphics.Region,
    /// The program's own clip, in the layer's coordinates, or null. It is
    /// the caller's to dispose of; this library only reads it.
    clip_region: ?*graphics.Region = null,
    /// What the RastPort is drawing into now.
    targets: ?*graphics.ClipTarget = null,
    /// The whole list, while `BeginUpdate` has narrowed `targets` to the
    /// damage.
    saved_targets: ?*graphics.ClipTarget = null,
    /// The bitmap a `LAYERSUPER` layer draws into, which is the caller's.
    /// Null for every other kind.
    super: ?*rtg.Surface = null,
    /// Where in that bitmap the layer is showing.
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    /// What paints a part of the layer that has nothing in it yet: 0 for
    /// the layer's background pen, `LAYERS_NOBACKFILL` for nothing at all,
    /// or a `*Hook`.
    backfill: usize = 0,
    /// The covered pieces whose pixels are being kept, for a `LAYERSMART`
    /// layer. Null for a simple one, which keeps nothing.
    kept: ?*Kept = null,
    /// Between the two passes of a retile: the keeping that replaces
    /// `kept`, and what the layer can see now, which replaces `visible`.
    pending: ?*Kept = null,
    next_visible: ?*graphics.Region = null,
    /// The first pass made `pending`, so the second may put back and swap.
    pending_made: bool = false,
    /// Between a move and the paint that follows it: what the layer can
    /// see now and had no kept pixels for. It is already this layer's
    /// damage; this holds it until the clipping is the new one, so that
    /// the paint goes where the layer's pixels go.
    owed: ?*graphics.Region = null,
    /// Held while this layer's clipping must not change.
    lock: exec.SignalSemaphore = .{ .link = .{ .type = .signalsem } },
    /// What went wrong in the last call on this layer.
    last_error: i32 = layers.LERR_OK,
    /// The layer this one moves and sizes with (`LATAG_MovesWith`), or
    /// null.
    moves_with: ?*Layer = null,
    /// In a composed LayerInfo, the buffer it draws into, all of it, and
    /// the hook its handle tells of what was drawn. Null in any other.
    own: ?Buffer = null,
    watch: utility.Hook = .{},
    /// Composed and with no buffer of its own (`LATAG_NoBuffer`): a handle
    /// on the display's memory, which its backfill paints through where
    /// it is seen. Its hook is `watch`, told nothing: what is painted is
    /// handed on with what the compositor copies. Null for every other.
    through: ?*rtg.RtgBitMap = null,
    /// A picture of the caller's shown over `picture_area` - the layer's
    /// coordinates - in place of the buffer there (`ShowLayerPicture`),
    /// or null.
    picture: ?*const rtg.Surface = null,
    picture_area: Rect = .{},
    /// Composed, what it looks like: the radius of its corners, the size
    /// of its shadow, how much it covers (255, all), and whether it counts
    /// (`LATAG_Corners`, `LATAG_Shadow`, `LATAG_Opacity`, `LATAG_Ghost`).
    corners: u16 = 0,
    shadow: u16 = 0,
    opacity: u8 = 255,
    ghost: bool = false,
    /// Where its shadow can be seen, in the display's coordinates, and
    /// the rectangle round that; null with no shadow, or none that falls
    /// on anything (compose/_effects.zig).
    shade: ?*graphics.Region = null,
    shade_box: Rect = .{},
};

/// Room for one kept piece, from the LayerInfo's pool.
///
/// INPUTS:
/// - `sys` - exec, for the pool.
/// - `info` - the display whose pool it is.
pub fn newKept(sys: *ExecBase, info: *LayerInfo) ?*Kept {
    const mem = sys.AllocPooled(info.pool, @sizeOf(Kept)) orelse return null;
    return @ptrCast(@alignCast(mem));
}

/// Room for one store, from the LayerInfo's pool.
///
/// INPUTS:
/// - `sys` - exec, for the pool.
/// - `info` - the display whose pool it is.
pub fn newStore(sys: *ExecBase, info: *LayerInfo) ?*Store {
    const mem = sys.AllocPooled(info.pool, @sizeOf(Store)) orelse return null;
    return @ptrCast(@alignCast(mem));
}

/// Room for one clip target, from the LayerInfo's pool.
///
/// INPUTS:
/// - `sys` - exec, for the pool.
/// - `info` - the display whose pool it is.
pub fn newTarget(sys: *ExecBase, info: *LayerInfo) ?*graphics.ClipTarget {
    const mem = sys.AllocPooled(info.pool, @sizeOf(graphics.ClipTarget)) orelse return null;
    return @ptrCast(@alignCast(mem));
}

/// Put a whole list of them back.
///
/// INPUTS:
/// - `sys` - exec, for the pool.
/// - `info` - the display whose pool it is.
/// - `from` - the first target of the list.
pub fn freeTargets(sys: *ExecBase, info: *LayerInfo, from: ?*graphics.ClipTarget) void {
    var at = from;
    while (at) |t| {
        const next = t.next;
        sys.FreePooled(info.pool, t, @sizeOf(graphics.ClipTarget));
        at = next;
    }
}

/// A region with the same rectangles in it, or null if there was no
/// memory. The region calls all work on a region that is already there, so
/// this is how anything gets a second one to work on without spoiling the
/// first.
///
/// INPUTS:
/// - `lb` - the library: graphics for the region calls, and the region
///   made the system's (`newRegion`).
/// - `from` - the region to copy.
pub fn copyRegion(lb: *LayersBase, from: *graphics.Region) ?*graphics.Region {
    const gb = lb.graphics_base;
    const to = lb.newRegion() orelse return null;
    if (!gb.OrRegionRegion(from, to)) {
        gb.DisposeRegion(to);
        return null;
    }
    return to;
}

/// Whether a region has nothing in it.
///
/// INPUTS:
/// - `gb` - graphics.library, for the region calls.
/// - `region` - the region.
pub fn isEmpty(gb: *GraphicsBase, region: *graphics.Region) bool {
    return gb.RegionRectangles(region, null, 0) == 0;
}
