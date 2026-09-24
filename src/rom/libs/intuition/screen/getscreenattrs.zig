// SPDX-License-Identifier: MPL-2.0
//! GetScreenAttrs: reads a screen.

const sdk = @import("sdk");
const utility = sdk.utility;
const intuition = sdk.intuition;
const sc = intuition.screens;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;

/// Reads a screen.
///
/// SYNOPSIS:
/// ```zig
/// fn GetScreenAttrs(ib: *IntuitionBase, screen: *Screen,
///     tags: ?[*]const TagItem) void
/// ```
///
/// SINCE: 0.4. LVO -104.
///
/// INPUTS:
/// - `screen` - the screen.
/// - `tags` - which values, each tag's data a `*usize` the value goes to:
///   `SA_Width`, `SA_Height`, `SA_Depth`, `SA_Title`, `SA_Font`,
///   `SA_PubName` (0 for a private screen), `SA_ShowTitle`,
///   `SA_RastPort`, `SA_LayerInfo`, `SA_BarHeight`. A tag it does not
///   know, or a null data, is passed over.
///
/// RESULT:
/// Nothing; the values are where the tags point.
///
/// BEHAVIOR:
/// The screen is opaque, and this is how a program learns how big it is
/// and where to draw.
///
/// CONTEXT:
/// - Waits: no.
/// - Interrupts: no.
/// - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Pointers read back are the screen's, good until it closes.
///
/// NOTES:
/// - The RastPort covers the whole display under no layer: what is drawn
///   through it lands beneath every window.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenScreenTagList`, `GetScreenDrawInfo`
///
/// EXAMPLES:
/// ```zig
/// var width: usize = 0;
/// const ask = [_]TagItem{ .{ .tag = SA_Width, .data = @intFromPtr(&width) }, .{} };
/// ib.GetScreenAttrs(screen, &ask);
/// ```
pub fn GetScreenAttrs(ib: *IntuitionBase, screen: *Screen, tags: ?[*]const TagItem) void {
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        if (item.data == 0) continue;
        const out: *usize = @ptrFromInt(item.data);
        switch (item.tag) {
            sc.SA_Width => out.* = @intCast(screen.width),
            sc.SA_Height => out.* = @intCast(screen.height),
            sc.SA_Depth => out.* = screen.depth,
            sc.SA_Title => out.* = @intFromPtr(screen.title),
            sc.SA_Font => out.* = @intFromPtr(screen.font),
            sc.SA_PubName => out.* = if (screen.public) @intFromPtr(&screen.pub_name) else 0,
            sc.SA_ShowTitle => out.* = @intFromBool(screen.bar != null),
            sc.SA_RastPort => out.* = @intFromPtr(screen.rp),
            sc.SA_LayerInfo => out.* = @intFromPtr(screen.layer_info),
            sc.SA_BarHeight => out.* = @intCast(screen.bar_height),
            else => {},
        }
    }
}
