// SPDX-License-Identifier: MPL-2.0
//! OpenWindowTagList: opens a window.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const gadgetclass = @import("../classes/gadgetclass.zig");
const sc = intuition.screens;
const wn = intuition.windows;
const ic = intuition.imageclass;
const TagItem = utility.TagItem;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _gadget = @import("../gadget/_gadget.zig");
const _window = @import("_window.zig");
const WF_BACKDROP = _window.WF_BACKDROP;
const WF_BORDERLESS = _window.WF_BORDERLESS;
const WF_CLOSE = _window.WF_CLOSE;
const WF_DEPTH = _window.WF_DEPTH;
const WF_DRAG = _window.WF_DRAG;
const WF_GZZ = _window.WF_GZZ;
const WF_HASZOOM = _window.WF_HASZOOM;
const WF_NOCARE = _window.WF_NOCARE;
const WF_NOTIFYDEPTH = _window.WF_NOTIFYDEPTH;
const WF_REPORTMOUSE = _window.WF_REPORTMOUSE;
const WF_RMBTRAP = _window.WF_RMBTRAP;
const WF_SIMPLE = _window.WF_SIMPLE;
const WF_SIZE = _window.WF_SIZE;
const WF_SIZE_BBOTTOM = _window.WF_SIZE_BBOTTOM;
const WF_SIZE_BRIGHT = _window.WF_SIZE_BRIGHT;
const WF_SUPER = _window.WF_SUPER;
const Window = _window.Window;
const activate = _window.activate;
const backfill = _window.backfill;
const bottom_border = _window.bottom_border;
const close_width = _window.close_width;
const depth_width = _window.depth_width;
const disposeParts = _window.disposeParts;
const drawBorder = _window.drawBorder;
const flagIf = _window.flagIf;
const gadgetImage = _window.gadgetImage;
const innerRastPort = _window.innerRastPort;
const lock = _window.lock;
const side_border = _window.side_border;
const size_height = _window.size_height;
const size_width = _window.size_width;
const targetScreen = _window.targetScreen;
const unlock = _window.unlock;
const zoom_width = _window.zoom_width;

/// Opens a window.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenWindowTagList(ib: *IntuitionBase,
///     tags: ?[*]const TagItem) ?*Window
/// ```
///
/// SINCE: 0.5. LVO -132.
///
/// INPUTS:
/// - `tags` - the `WA_` names. Where: `WA_Left`, `WA_Top`, `WA_Width`,
///   `WA_Height` (or `WA_InnerWidth`/`WA_InnerHeight`), `WA_MinWidth` and
///   the other limits. On what: `WA_CustomScreen`, `WA_PubScreen`,
///   `WA_PubScreenName`, or by default the default public screen. How:
///   `WA_Title` (not copied), `WA_CloseGadget`, `WA_DepthGadget`,
///   `WA_SizeGadget`, `WA_DragBar`, `WA_Borderless`, `WA_Backdrop`,
///   `WA_SimpleRefresh`/`WA_SmartRefresh`, `WA_NoCareRefresh`,
///   `WA_Activate`, and `WA_IDCMP` for a message port. Its menus:
///   `WA_Checkmark`, `WA_AmigaKey`, `WA_MenuHelp`, `WA_NewLookMenus`. May
///   be null.
///
/// RESULT:
/// The window, or null: no screen to open it on (the default one could not
/// be opened, or a named one is not open), or no memory.
///
/// BEHAVIOR:
/// It is a layer of its screen, made to fit: sized down to the screen and
/// moved onto it when asked for more. Its border is drawn - a frame, a
/// title bar the font's height and a little, and the images of the border
/// gadgets it asked for - and the part inside is the screen's background
/// pen. Its RastPort draws in `TEXTPEN` on `BACKGROUNDPEN` in the screen's
/// font. With `WA_IDCMP` it has a message port of its own, made for the
/// calling task. With `WA_Activate` it becomes the active window.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore, and the layers' locks.
/// - Interrupts: no.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `CloseWindow`, which the same task must call: the
/// message port's signal is that task's.
///
/// NOTES:
/// - A window on a public screen keeps it from closing, so no lock needs
///   to be held for the window's life.
/// - The border gadgets are pictures until there is input.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseWindow`, `GetWindowAttrs`, `ModifyIDCMP`
///
/// EXAMPLES:
/// ```zig
/// const tags = [_]TagItem{
///     .{ .tag = WA_Title, .data = @intFromPtr("Hello") },
///     .{ .tag = WA_CloseGadget, .data = 1 },
///     .{ .tag = WA_IDCMP, .data = IDCMP_REFRESHWINDOW },
///     .{},
/// };
/// const window = ib.OpenWindowTagList(&tags) orelse return;
/// ```
pub fn OpenWindowTagList(ib: *IntuitionBase, tags: ?[*]const TagItem) ?*Window {
    const ub = ib.utility_base;
    const gb = ib.graphics_base;
    const lb = ib.layers_base;
    const it = ib.iface();

    const target = targetScreen(ib, tags) orelse return null;
    const s = target.screen;
    // A window opened on a public screen by name is a visitor: the lock it
    // was found with is kept until it closes. One that fails gives it back.
    var visiting = false;
    defer if (target.locked and !visiting) it.UnlockPubScreen(null, @ptrCast(s));

    lock(ib);
    defer unlock(ib);

    // The whole word first, so a tag of its own can still say otherwise.
    var flags: u32 = @as(u32, @truncate(ub.GetTagData(wn.WA_Flags, 0, tags))) & wn.WFLG_SETTABLE;
    flags |= flagIf(ub, wn.WA_CloseGadget, tags, WF_CLOSE);
    flags |= flagIf(ub, wn.WA_DepthGadget, tags, WF_DEPTH);
    flags |= flagIf(ub, wn.WA_SizeGadget, tags, WF_SIZE);
    flags |= flagIf(ub, wn.WA_DragBar, tags, WF_DRAG);
    flags |= flagIf(ub, wn.WA_Backdrop, tags, WF_BACKDROP);
    flags |= flagIf(ub, wn.WA_SimpleRefresh, tags, WF_SIMPLE);
    flags |= flagIf(ub, wn.WA_Borderless, tags, WF_BORDERLESS);
    flags |= flagIf(ub, wn.WA_NoCareRefresh, tags, WF_NOCARE);
    flags |= flagIf(ub, wn.WA_RMBTrap, tags, WF_RMBTRAP);
    flags |= flagIf(ub, wn.WA_SizeBRight, tags, WF_SIZE_BRIGHT);
    // A window has a zoom gadget when it asks for a box to flip to, or when
    // it has both a sizing and a depth gadget: the two together are what a
    // window that can change size and come back needs.
    const zoom_asked = ub.FindTagItem(wn.WA_Zoom, tags);
    if (zoom_asked != null or flags & (WF_SIZE | WF_DEPTH) == WF_SIZE | WF_DEPTH) flags |= WF_HASZOOM;
    flags |= flagIf(ub, wn.WA_SizeBBottom, tags, WF_SIZE_BBOTTOM);
    flags |= flagIf(ub, wn.WA_GimmeZeroZero, tags, WF_GZZ);
    flags |= flagIf(ub, wn.WA_ReportMouse, tags, WF_REPORTMOUSE);
    flags |= flagIf(ub, wn.WA_NotifyDepth, tags, WF_NOTIFYDEPTH);
    flags |= flagIf(ub, wn.WA_NewLookMenus, tags, wn.WFLG_NEWLOOKMENUS);
    // A window that says where it goes is put there or not at all; one that
    // says nothing has nothing to be moved away from, so it is adjusted.
    // Nothing keeps this - it is only true while the window is being opened.
    const placed = ub.FindTagItem(wn.WA_Left, tags) != null or ub.FindTagItem(wn.WA_Top, tags) != null;
    const auto_adjust = ub.GetTagData(wn.WA_AutoAdjust, @intFromBool(!placed), tags) != 0;
    if (ub.GetTagData(wn.WA_SmartRefresh, 0, tags) != 0) flags &= ~WF_SIMPLE;
    // A backdrop window sits behind everything and is not moved, sized or
    // reordered, so it has none of the furniture for doing so.
    if (flags & WF_BACKDROP != 0) flags &= ~(WF_SIZE | WF_DRAG | WF_DEPTH | WF_HASZOOM);
    const title: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wn.WA_Title, 0, tags));
    // Without one of its own, the window shows the screen's title.
    const screen_title: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(wn.WA_ScreenTitle, @intFromPtr(s.default_title), tags));

    // The border: a title bar the font's height and a little when there is
    // anything to put in it, thin sides, and one border made deep enough to
    // hold the size gadget when there is one.
    //
    // Which border that is, the window says: `WA_SizeBBottom` the bottom,
    // `WA_SizeBRight` the right, and the right when it says neither, since
    // the gadget has to be somewhere. Both is allowed and takes room from
    // each.
    var bl: i32 = 0;
    var bt: i32 = 0;
    var br: i32 = 0;
    var bb: i32 = 0;
    if (flags & WF_BORDERLESS == 0) {
        var font_height: u32 = 0;
        const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) }, .{} };
        gb.GetRPAttrs(s.rp, &metric);
        const has_bar = title != null or flags & (WF_CLOSE | WF_DEPTH | WF_DRAG | WF_HASZOOM) != 0;
        const sizing = flags & WF_SIZE != 0;
        const at_bottom = sizing and flags & WF_SIZE_BBOTTOM != 0;
        const at_right = sizing and (flags & WF_SIZE_BRIGHT != 0 or flags & WF_SIZE_BBOTTOM == 0);
        bl = side_border;
        br = if (at_right) size_width else side_border;
        bt = if (has_bar) @as(i32, @intCast(font_height)) + 3 else bottom_border;
        bb = if (at_bottom) size_height else bottom_border;
    }

    // A border is deep enough for the gadgets that live in it, even in a
    // window that has no border otherwise. A right or bottom one placed
    // from that edge needs as much as it reaches in from it; one placed
    // from the left or top, as much as it reaches in from the size the
    // window asks for.
    const asked_w: i32 = @intCast(ub.GetTagData(wn.WA_Width, 200, tags));
    const asked_h: i32 = @intCast(ub.GetTagData(wn.WA_Height, 100, tags));
    var next: ?*intuition.Object = @ptrFromInt(ub.GetTagData(wn.WA_Gadgets, 0, tags));
    while (next) |o| : (next = gadgetclass.gadgetOf(ib, o).next) {
        const g = gadgetclass.gadgetOf(ib, o);
        const rel_w: i32 = if (g.flags & gadgetclass.GFLG_RELWIDTH != 0) asked_w else 0;
        const rel_h: i32 = if (g.flags & gadgetclass.GFLG_RELHEIGHT != 0) asked_h else 0;
        if (g.activation & gadgetclass.GACT_LEFTBORDER != 0) bl = @max(bl, g.left + g.width + rel_w);
        if (g.activation & gadgetclass.GACT_TOPBORDER != 0) bt = @max(bt, g.top + g.height + rel_h);
        if (g.activation & gadgetclass.GACT_RIGHTBORDER != 0)
            br = @max(br, if (g.flags & gadgetclass.GFLG_RELRIGHT != 0) 1 - g.left else asked_w - g.left);
        if (g.activation & gadgetclass.GACT_BOTTOMBORDER != 0)
            bb = @max(bb, if (g.flags & gadgetclass.GFLG_RELBOTTOM != 0) 1 - g.top else asked_h - g.top);
    }

    // Where and how big, kept on the screen.
    var width: i32 = asked_w;
    var height: i32 = asked_h;
    if (ub.FindTagItem(wn.WA_InnerWidth, tags)) |item| width = @as(i32, @intCast(item.data)) + bl + br;
    if (ub.FindTagItem(wn.WA_InnerHeight, tags)) |item| height = @as(i32, @intCast(item.data)) + bt + bb;
    var left: i32 = @intCast(ub.GetTagData(wn.WA_Left, 0, tags));
    var top: i32 = @intCast(ub.GetTagData(wn.WA_Top, 0, tags));
    if (auto_adjust) {
        // Squeezed to the screen and then moved onto it.
        width = @max(@min(width, s.width), bl + br + 1);
        height = @max(@min(height, s.height), bt + bb + 1);
        left = @max(@min(left, s.width - width), 0);
        top = @max(@min(top, s.height - height), 0);
    } else {
        // Asked for a place and not to be moved from it: it goes there or
        // the window does not open. A picture laid out to the pixel would
        // rather hear that than be shifted without being told.
        if (width < bl + br + 1 or height < bt + bb + 1) return null;
        if (left < 0 or top < 0) return null;
        if (left + width > s.width or top + height > s.height) return null;
    }

    // A gadget that sits on top of its neighbours is worse than no gadget.
    // The zoom one is the one a window is given without asking, so it is
    // the one to go without when the title bar is too narrow to hold it
    // beside the close and depth gadgets and leave a bar to drag by.
    if (flags & WF_HASZOOM != 0) {
        var taken: i32 = zoom_width;
        if (flags & WF_CLOSE != 0) taken += close_width;
        if (flags & WF_DEPTH != 0) taken += depth_width;
        if (taken > width) flags &= ~WF_HASZOOM;
    }

    const memory = ib.sys_base.AllocMem(@sizeOf(Window), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse return null;
    const w: *Window = @ptrCast(@alignCast(memory));
    // The hook is in place before the layer exists, since making the layer
    // is the first thing it paints.
    w.screen = s;
    w.base = ib;
    w.backfill = .{ .entry = &backfill, .data = w };

    const bounds = graphics.Rect{ .min_x = left, .min_y = top, .max_x = left + width, .max_y = top + height };
    // A surface of the caller's makes the window a superbitmap one: it
    // keeps everything drawn in it, covered or not.
    const super = ub.GetTagData(wn.WA_SuperBitMap, 0, tags);
    if (super != 0) flags |= WF_SUPER;
    const refresh: usize = if (super != 0)
        layers.LAYERSUPER
    else if (flags & WF_SIMPLE != 0)
        layers.LAYERSIMPLE
    else
        layers.LAYERSMART;

    // How a part with nothing in it yet is painted: the caller's hook when
    // it gave one - `LAYERS_NOBACKFILL` included, which is a word and not a
    // hook - and the window's own otherwise.
    const paints_it = ub.GetTagData(wn.WA_BackFill, @intFromPtr(&w.backfill), tags);

    const layer_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = layers.LATAG_Refresh, .data = refresh },
        .{ .tag = layers.LATAG_Backdrop, .data = @intFromBool(flags & WF_BACKDROP != 0) },
        .{ .tag = layers.LATAG_BackFill, .data = paints_it },
        .{ .tag = layers.LATAG_SuperBitMap, .data = super },
        .{},
    };
    const layer = lb.CreateLayerTagList(s.layer_info, &layer_tags) orelse {
        ib.sys_base.FreeMem(memory, @sizeOf(Window));
        return null;
    };
    // A new backdrop layer goes behind every other, the screen's ground
    // included; a backdrop window belongs just in front of the ground,
    // behind the title bar and every ordinary window - or in front of the
    // bar, when `ShowTitle` has put the bar behind the backdrop windows.
    if (flags & WF_BACKDROP != 0) {
        const behind = if (s.show_title) s.ground else (s.bar orelse s.ground);
        if (behind) |under| _ = lb.MoveLayerInFrontOf(layer, under);
    }
    var where: usize = 0;
    const ask = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&where) }, .{} };
    lb.GetLayerAttrs(layer, &ask);

    const hook = w.backfill;
    w.* = .{
        .backfill = hook,
        .base = ib,
        .screen = s,
        .layer = layer,
        .rp = @ptrFromInt(where),
        .left = left,
        .top = top,
        .width = width,
        .height = height,
        .min_width = @intCast(ub.GetTagData(wn.WA_MinWidth, @intCast(width), tags)),
        .min_height = @intCast(ub.GetTagData(wn.WA_MinHeight, @intCast(height), tags)),
        .max_width = @intCast(ub.GetTagData(wn.WA_MaxWidth, @intCast(s.width), tags)),
        .max_height = @intCast(ub.GetTagData(wn.WA_MaxHeight, @intCast(s.height), tags)),
        .border_left = bl,
        .border_top = bt,
        .border_right = br,
        .border_bottom = bb,
        .title = title,
        .screen_title = screen_title,
        .detail_pen = @truncate(ub.GetTagData(wn.WA_DetailPen, s.pens[sc.DETAILPEN], tags)),
        .block_pen = @truncate(ub.GetTagData(wn.WA_BlockPen, s.pens[sc.BLOCKPEN], tags)),
        .flags = flags,
        .idcmp = @intCast(ub.GetTagData(wn.WA_IDCMP, 0, tags)),
        .mouse_limit = @intCast(ub.GetTagData(wn.WA_MouseQueue, wn.DEFAULTMOUSEQUEUE, tags)),
        .rpt_limit = @intCast(ub.GetTagData(wn.WA_RptQueue, wn.DEFAULTRPTQUEUE, tags)),
        .check_mark = @ptrFromInt(ub.GetTagData(wn.WA_Checkmark, @intFromPtr(s.draw_info.check_mark), tags)),
        .amiga_key = @ptrFromInt(ub.GetTagData(wn.WA_AmigaKey, @intFromPtr(s.draw_info.amiga_key), tags)),
        .more_flags = if (ub.GetTagData(wn.WA_MenuHelp, 0, tags) != 0) _window.WMF_MENUHELP else 0,
    };
    w.reply_port.msg_list.init(.message);

    // Where the zoom gadget flips to. A window already at its smallest
    // flips to its largest; anything else flips to its smallest, which is
    // what a window with nothing said about it does. A box the caller gave
    // replaces that, and is not looked at further - a box of its own is the
    // caller's business, however odd.
    w.unzoom_box = .{ .left = left, .top = top, .width = width, .height = height };
    w.zoom_box = if (width == w.min_width and height == w.min_height)
        .{ .left = left, .top = top, .width = w.max_width, .height = w.max_height }
    else
        .{ .left = left, .top = top, .width = w.min_width, .height = w.min_height };
    if (zoom_asked) |item| {
        if (item.data != 0) w.zoom_box = @as(*const wn.WindowBox, @ptrFromInt(item.data)).*;
    }

    // A GimmeZeroZero window's interior is a layer of its own, in front of
    // the border's, so that what the program draws is clipped to the inside
    // and its own (0, 0) is that corner. A window that cannot have the
    // second layer opens without it and is an ordinary window, which is
    // better than not opening at all.
    if (flags & WF_GZZ != 0 and bl + br < width and bt + bb < height) {
        const inner = graphics.Rect{
            .min_x = left + bl,
            .min_y = top + bt,
            .max_x = left + width - br,
            .max_y = top + height - bb,
        };
        const inner_tags = [_]TagItem{
            .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&inner) },
            .{ .tag = layers.LATAG_Refresh, .data = refresh },
            .{ .tag = layers.LATAG_BackFill, .data = paints_it },
            .{ .tag = layers.LATAG_SuperBitMap, .data = super },
            .{},
        };
        if (lb.CreateLayerTagList(s.layer_info, &inner_tags)) |inner_layer| {
            _ = lb.MoveLayerInFrontOf(inner_layer, layer);
            var inner_where: usize = 0;
            const ask_inner = [_]TagItem{ .{ .tag = layers.LATAG_GetRastPort, .data = @intFromPtr(&inner_where) }, .{} };
            lb.GetLayerAttrs(inner_layer, &ask_inner);
            w.inner_layer = inner_layer;
            w.inner_rp = @ptrFromInt(inner_where);
        } else {
            w.flags &= ~WF_GZZ;
        }
    }

    // The gadgets' RastPort: the same pixels, its own drawing state. A
    // window whose display would not give one still opens - gadgets then
    // simply do not draw, which is what `ObtainGIRPort` answering null
    // has always meant.
    var gi_bitmap: usize = 0;
    var gi_surface: usize = 0;
    const which = [_]TagItem{
        .{ .tag = graphics.RPTAG_BitMap, .data = @intFromPtr(&gi_bitmap) },
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&gi_surface) },
        .{},
    };
    gb.GetRPAttrs(innerRastPort(w), &which);
    const make = [_]TagItem{
        .{
            .tag = if (gi_bitmap != 0) graphics.RPTAG_BitMap else graphics.RPTAG_Surface,
            .data = if (gi_bitmap != 0) gi_bitmap else gi_surface,
        },
        .{},
    };
    w.gi_rp = gb.CreateRastPortTagList(&make);
    if (w.gi_rp) |gi_rp| graphics.SetFont(gb, gi_rp, s.font);

    // The program's pens: text on the background, in the screen's font.
    graphics.SetFont(gb, innerRastPort(w), s.font);
    const pens = [_]TagItem{
        .{ .tag = graphics.RPTAG_APen, .data = s.pens[sc.TEXTPEN] },
        .{ .tag = graphics.RPTAG_BPen, .data = s.pens[sc.BACKGROUNDPEN] },
        .{},
    };
    gb.SetRPAttrs(innerRastPort(w), &pens);

    var ok = true;
    if (flags & WF_BORDERLESS == 0) {
        const edges = [_]TagItem{ .{ .tag = ic.IA_EdgesOnly, .data = 1 }, .{} };
        w.frame = it.NewObjectTagList(ib.frame_class, null, &edges);
        if (w.frame == null) ok = false;
        if (flags & WF_CLOSE != 0) {
            w.close_image = gadgetImage(ib, s, ic.CLOSEIMAGE, close_width, bt);
            if (w.close_image == null) ok = false;
        }
        if (flags & WF_DEPTH != 0) {
            w.depth_image = gadgetImage(ib, s, ic.DEPTHIMAGE, depth_width, bt);
            if (w.depth_image == null) ok = false;
        }
        if (flags & WF_HASZOOM != 0) {
            w.zoom_image = gadgetImage(ib, s, ic.ZOOMIMAGE, zoom_width, bt);
            if (w.zoom_image == null) ok = false;
        }
        if (flags & WF_SIZE != 0) {
            w.size_image = gadgetImage(ib, s, ic.SIZEIMAGE, size_width, size_height);
            if (w.size_image == null) ok = false;
        }
    }
    if (ok and w.idcmp != 0) {
        w.user_port = ib.sys_base.CreateMsgPort();
        if (w.user_port == null) ok = false;
    }
    if (!ok) {
        disposeParts(ib, w);
        lb.DeleteLayer(layer);
        ib.sys_base.FreeMem(memory, @sizeOf(Window));
        return null;
    }

    ib.sys_base.AddTail(@ptrCast(&s.windows), @ptrCast(&w.node));
    if (ub.GetTagData(wn.WA_Gadgets, 0, tags) != 0) {
        _ = it.AddGList(@ptrCast(w), @ptrFromInt(ub.GetTagData(wn.WA_Gadgets, 0, tags)), -1, -1);
    }
    if (ub.GetTagData(wn.WA_Activate, 0, tags) != 0) {
        activate(ib, w);
    } else {
        drawBorder(ib, w);
    }
    _gadget.renderAll(ib, w);
    // Its help group: the one asked for, a window's, or one of its own;
    // it has gadget help if the group does.
    w.help_group = @truncate(ub.GetTagData(wn.WA_HelpGroup, 0, tags));
    if (ub.GetTagData(wn.WA_HelpGroupWindow, 0, tags) != 0) {
        const other: *Window = @ptrFromInt(ub.GetTagData(wn.WA_HelpGroupWindow, 0, tags));
        w.help_group = other.help_group;
    }
    if (w.help_group == 0) w.help_group = ub.GetUniqueID();
    if (_window.groupHasHelp(ib, w.help_group)) w.more_flags |= _window.WMF_GADGETHELP;
    if (target.locked) {
        visiting = true;
        w.more_flags |= _window.WMF_VISITOR;
        if (ib.pub_modes & sc.POPPUBSCREEN != 0) it.ScreenToFront(@ptrCast(s));
    }
    return @ptrCast(w);
}
