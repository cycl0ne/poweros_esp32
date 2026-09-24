// SPDX-License-Identifier: MPL-2.0
//! GetWindowAttrs: reads a window.

const sdk = @import("sdk");
const utility = sdk.utility;
const layers = sdk.layers;
const intuition = sdk.intuition;
const wn = intuition.windows;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _window = @import("_window.zig");
const WF_ACTIVE = _window.WF_ACTIVE;
const WF_BACKDROP = _window.WF_BACKDROP;
const WF_IN_REFRESH = _window.WF_IN_REFRESH;
const WF_SIMPLE = _window.WF_SIMPLE;
const Window = _window.Window;
const innerLayer = _window.innerLayer;
const innerRastPort = _window.innerRastPort;
const interior = _window.interior;

/// Reads a window.
///
/// SYNOPSIS:
/// ```zig
/// fn GetWindowAttrs(ib: *IntuitionBase, window: *Window,
///     tags: ?[*]const TagItem) void
/// ```
///
/// SINCE: 0.5. LVO -140.
///
/// INPUTS:
/// - `window` - the window.
/// - `tags` - which values, each tag's data a `*usize`: `WA_Left`,
///   `WA_Top`, `WA_Width`, `WA_Height`, `WA_InnerWidth`, `WA_InnerHeight`,
///   the limits, `WA_Title`, `WA_IDCMP`, `WA_RastPort`, `WA_UserPort`,
///   `WA_Screen`, `WA_Layer`, `WA_BorderLeft`/`Top`/`Right`/`Bottom`,
///   `WA_Active`, `WA_SimpleRefresh`, `WA_Backdrop`, `WA_Checkmark`,
///   `WA_AmigaKey`, `WA_MenuHelp`.
///
/// RESULT:
/// Nothing; the values are where the tags point.
///
/// BEHAVIOR:
/// The window is opaque, and this is how a program learns where to draw:
/// inside the border widths of its RastPort.
///
/// CONTEXT:
/// - Waits: no. - Interrupts: no. - Forbid: not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// Pointers read back are the window's, good until it closes.
///
/// NOTES:
/// - A program drawing through the RastPort holds the layer's lock
///   (layers.library's LockLayer on `WA_Layer`) while it does.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `OpenWindowTagList`
///
/// EXAMPLES:
/// ```zig
/// var port: usize = 0;
/// const ask = [_]TagItem{ .{ .tag = WA_UserPort, .data = @intFromPtr(&port) }, .{} };
/// ib.GetWindowAttrs(window, &ask);
/// ```
pub fn GetWindowAttrs(ib: *IntuitionBase, window: *Window, tags: ?[*]const TagItem) void {
    var state = tags;
    while (ib.utility_base.NextTagItem(&state)) |item| {
        if (item.data == 0) continue;
        const out: *usize = @ptrFromInt(item.data);
        switch (item.tag) {
            wn.WA_Left => out.* = @intCast(window.left),
            wn.WA_Top => out.* = @intCast(window.top),
            wn.WA_Width => out.* = @intCast(window.width),
            wn.WA_Height => out.* = @intCast(window.height),
            wn.WA_InnerWidth => out.* = @intCast(interior(window).width),
            wn.WA_InnerHeight => out.* = @intCast(interior(window).height),
            wn.WA_MinWidth => out.* = @intCast(window.min_width),
            wn.WA_MinHeight => out.* = @intCast(window.min_height),
            wn.WA_MaxWidth => out.* = @intCast(window.max_width),
            wn.WA_MaxHeight => out.* = @intCast(window.max_height),
            wn.WA_Title => out.* = @intFromPtr(window.title),
            wn.WA_ScreenTitle => out.* = @intFromPtr(window.screen_title),
            wn.WA_IDCMP => out.* = window.idcmp,
            // What the window is, as the word `WA_Flags` takes. The bits
            // this library keeps for itself are not part of the answer.
            wn.WA_Flags => out.* = window.flags & wn.WFLG_SETTABLE,
            wn.WA_DetailPen => out.* = window.detail_pen,
            wn.WA_BlockPen => out.* = window.block_pen,
            // The program's own: the interior's for a GimmeZeroZero
            // window, the window's for any other.
            wn.WA_RastPort => out.* = @intFromPtr(innerRastPort(window)),
            wn.WA_UserPort => out.* = @intFromPtr(window.user_port),
            wn.WA_Screen => out.* = @intFromPtr(window.screen),
            wn.WA_Layer => out.* = @intFromPtr(innerLayer(window)),
            wn.WA_Damage => {
                out.* = 0;
                if (window.flags & WF_IN_REFRESH != 0) {
                    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetDamage, .data = @intFromPtr(out) }, .{} };
                    ib.layers_base.GetLayerAttrs(innerLayer(window), &ask);
                }
            },
            wn.WA_BorderLeft => out.* = @intCast(window.border_left),
            wn.WA_BorderTop => out.* = @intCast(window.border_top),
            wn.WA_BorderRight => out.* = @intCast(window.border_right),
            wn.WA_BorderBottom => out.* = @intCast(window.border_bottom),
            wn.WA_Active => out.* = @intFromBool(window.flags & WF_ACTIVE != 0),
            wn.WA_SimpleRefresh => out.* = @intFromBool(window.flags & WF_SIMPLE != 0),
            wn.WA_Backdrop => out.* = @intFromBool(window.flags & WF_BACKDROP != 0),
            wn.WA_Checkmark => out.* = @intFromPtr(window.check_mark),
            wn.WA_AmigaKey => out.* = @intFromPtr(window.amiga_key),
            wn.WA_MenuHelp => out.* = @intFromBool(window.more_flags & _window.WMF_MENUHELP != 0),
            else => {},
        }
    }
}
