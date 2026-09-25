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
const _window = @import("../window/_window.zig");

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
///   `SA_Width`, `SA_Height`, `SA_Depth`, `SA_Title` (what the bar shows
///   now), `SA_DefaultTitle`, `SA_Font`, `SA_PubName` (0 for a private
///   screen), `SA_Type`, `SA_ShowTitle`, `SA_RastPort`, `SA_LayerInfo`,
///   `SA_BarHeight`, `SA_BarVBorder`, `SA_BarHBorder`, `SA_MouseX`,
///   `SA_MouseY`, `SA_WBorTop`, `SA_WBorLeft`, `SA_WBorRight`,
///   `SA_WBorBottom`. A tag it does not know, or a null data, is passed
///   over.
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
            sc.SA_Type => out.* = screen.screen_type,
            sc.SA_DefaultTitle => out.* = @intFromPtr(screen.default_title),
            // The pointer is on the display, and a screen is the display's
            // size: its coordinates are the screen's.
            sc.SA_MouseX => out.* = @bitCast(@as(isize, ib.input.x)),
            sc.SA_MouseY => out.* = @bitCast(@as(isize, ib.input.y)),
            // What OpenWindowTagList gives a window with a title bar and no
            // size gadget on this screen.
            sc.SA_WBorTop => out.* = fontHeight(ib, screen) + 3,
            sc.SA_WBorLeft, sc.SA_WBorRight => out.* = _window.side_border,
            sc.SA_WBorBottom => out.* = _window.bottom_border,
            sc.SA_BarVBorder => out.* = _screen.bar_border,
            sc.SA_BarHBorder => out.* = _screen.bar_left,
            else => {},
        }
    }
}

fn fontHeight(ib: *IntuitionBase, screen: *Screen) usize {
    var height: u32 = 0;
    const metric = [_]TagItem{ .{ .tag = sdk.graphics.RPTAG_FontHeight, .data = @intFromPtr(&height) }, .{} };
    ib.graphics_base.GetRPAttrs(screen.rp, &metric);
    return height;
}
