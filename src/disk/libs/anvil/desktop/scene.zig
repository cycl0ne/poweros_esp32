// SPDX-License-Identifier: MIT
//! What the desktop's window shows, painted over any part of it: the
//! ground, the icons on it, and the box being drawn round icons.
//!
//! **It is all the window's backfill hook paints**, and the desktop draws
//! nothing into the window itself: it changes what is shown - an icon
//! picked, moved, come or gone, the box grown - and has the part that
//! changed painted again (`layers.RefillLayer`). On a composed screen the
//! window then needs no buffer of its own (`WA_NoBuffer`): the hook paints
//! straight on to the display wherever the window is seen, and a shadow
//! over it is laid on what was just painted.
//!
//! **The hook runs on any task** - whichever moves a window, fades one,
//! or uncovers the desktop - with the display's layers held. So it reads
//! only what it is handed here, under the desktop's `scene_lock`, and
//! draws only through the RastPort it is given, which layers.library has
//! clipped to the part: a name that reaches across two parts is drawn
//! where it meets each, and nothing beside a part is drawn twice.
//!
//! **The box** is each pixel of its edge turned round, over what was just
//! painted under it: painted again, it is drawn again, and taken away it
//! is simply no longer painted.

const sdk = @import("sdk");
const exec = sdk.exec;
const graphics = sdk.graphics;
const utility = sdk.utility;
const GraphicsBase = sdk.interface.graphics.GraphicsBase;
const Rect = graphics.Rect;
const Pen = graphics.Pen;
const TagItem = utility.TagItem;
const icons = @import("../icons/_icons.zig");
const Icon = icons.Icon;
const ground_area = @import("ground.zig");

/// What is painted: all of it the desktop's, read while it is held.
pub const Scene = struct {
    gb: *GraphicsBase,
    /// The ground; null - no memory for one - is `background`.
    ground: ?*const ground_area.Ground,
    background: Pen,
    /// The icons on the ground, and how they look.
    icons: *exec.List,
    look: *const icons.Look,
    /// The box being drawn round icons on the ground, or null.
    band: ?Rect = null,
};

/// `area` of the window painted through `rp`: the ground, every icon that
/// reaches into it, and the box.
pub fn paint(scene: Scene, rp: *graphics.RastPort, area: Rect) void {
    const gb = scene.gb;
    if (scene.ground) |ground| {
        ground_area.paint(gb, ground, rp, area);
    } else {
        gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_APen, .data = scene.background }, .{} });
        gb.RectFill(rp, &area);
    }
    var it = scene.icons.iterator();
    while (it.next()) |node| {
        const ic: *Icon = @alignCast(@fieldParentPtr("node", node));
        if (!Rect.intersect(ic.reach(scene.look), area).isEmpty()) ic.draw(gb, rp, scene.look, .{});
    }
    const box = scene.band orelse return;
    if (!meetsEdge(box, area)) return;
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_COMPLEMENT }, .{} });
    gb.DrawRect(rp, &box);
    gb.SetRPAttrs(rp, &[_]TagItem{ .{ .tag = graphics.RPTAG_DrMd, .data = graphics.DRMD_JAM1 }, .{} });
}

/// The four lines a box's edge is: what has to be painted again for it
/// to be drawn, or taken away.
pub fn edges(box: Rect) [4]Rect {
    return .{
        .{ .min_x = box.min_x, .min_y = box.min_y, .max_x = box.max_x, .max_y = box.min_y + 1 },
        .{ .min_x = box.min_x, .min_y = box.max_y - 1, .max_x = box.max_x, .max_y = box.max_y },
        .{ .min_x = box.min_x, .min_y = box.min_y, .max_x = box.min_x + 1, .max_y = box.max_y },
        .{ .min_x = box.max_x - 1, .min_y = box.min_y, .max_x = box.max_x, .max_y = box.max_y },
    };
}

/// Whether any of a box's edge lies in `area`.
fn meetsEdge(box: Rect, area: Rect) bool {
    for (edges(box)) |line| if (!Rect.intersect(line, area).isEmpty()) return true;
    return false;
}
