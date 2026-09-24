// SPDX-License-Identifier: MPL-2.0
//! OpenScreenTagList: opens a screen.

const sdk = @import("sdk");
const exec = sdk.exec;
const utility = sdk.utility;
const graphics = sdk.graphics;
const layers = sdk.layers;
const intuition = sdk.intuition;
const sc = intuition.screens;
const ic = intuition.imageclass;
const TagItem = utility.TagItem;
const Pen = graphics.Pen;
const IntuitionBase = @import("../intuition.zig").IntuitionBase;
const _screen = @import("_screen.zig");
const Screen = _screen.Screen;
const bar_border = _screen.bar_border;
const default_pens = _screen.default_pens;
const displayTaken = _screen.displayTaken;
const drawBar = _screen.drawBar;
const fillGround = _screen.fillGround;
const findPublic = _screen.findPublic;
const lock = _screen.lock;
const nameLen = _screen.nameLen;
const setPen = _screen.setPen;
const unlock = _screen.unlock;

/// Opens a screen.
///
/// SYNOPSIS:
/// ```zig
/// fn OpenScreenTagList(ib: *IntuitionBase,
///     tags: ?[*]const TagItem) ?*Screen
/// ```
///
/// SINCE: 0.4. LVO -96.
///
/// INPUTS:
/// - `tags` - the `SA_` names: `SA_Title` (not copied), `SA_Font` (a
///   TextFont the caller keeps open while the screen is), `SA_PubName`
///   (copied; makes it public), `SA_ShowTitle` (true by default),
///   `SA_Pens` (a `*const [NUMDRIPENS]Pen`, copied), and `SA_ErrorCode`, a
///   `*u32` for the reason when it fails. May be null.
///
/// RESULT:
/// The screen, or null: `OSERR_NOMONITOR` (no display), `OSERR_NOTAVAILABLE`
/// (the display already shows a screen), `OSERR_PUBNOTUNIQUE`,
/// `OSERR_BADNAME` (a public name too long), `OSERR_NOMEM`.
///
/// BEHAVIOR:
/// It takes the display rtg shows first: the whole of it, in its own
/// buffer and format. The display is painted in `BACKGROUNDPEN`, and the
/// title bar - `BARBLOCKPEN`, the title in `BARDETAILPEN`, a `BARTRIMPEN`
/// line under it - is a layer at the back, so windows will cover it the
/// way they cover each other. Nothing else is drawn.
///
/// CONTEXT:
/// - Waits: for the screen list's semaphore.
/// - Interrupts: no; it allocates.
/// - Forbid: not held and not needed.
/// - Process: a Task will do.
///
/// OWNERSHIP:
/// The caller's until `CloseScreen`. A public one may also be locked by
/// others, and cannot close while it is.
///
/// NOTES:
/// - One screen to a display, for now. A second on the same display is
///   refused rather than hidden, so a program knows.
/// - Without memory for its title bar it opens with none.
///
/// BUGS:
/// None known.
///
/// SEE ALSO:
/// `CloseScreen`, `GetScreenAttrs`, `LockPubScreen`
///
/// EXAMPLES:
/// ```zig
/// var why: u32 = 0;
/// const tags = [_]TagItem{
///     .{ .tag = SA_Title, .data = @intFromPtr("My Screen") },
///     .{ .tag = SA_ErrorCode, .data = @intFromPtr(&why) },
///     .{},
/// };
/// const screen = ib.OpenScreenTagList(&tags) orelse return why;
/// ```
pub fn OpenScreenTagList(ib: *IntuitionBase, tags: ?[*]const TagItem) ?*Screen {
    const ub = ib.utility_base;
    const gb = ib.graphics_base;
    const lb = ib.layers_base;
    const code_ptr: ?*u32 = @ptrFromInt(ub.GetTagData(sc.SA_ErrorCode, 0, tags));
    const pub_name: ?[*:0]const u8 = @ptrFromInt(ub.GetTagData(sc.SA_PubName, 0, tags));
    if (pub_name) |name| {
        if (nameLen(name) > sc.MAXPUBSCREENNAME) return fail(code_ptr, sc.OSERR_BADNAME);
    }

    // Held throughout, so no other screen can take the name or the display
    // between the checks and this one going on the list.
    lock(ib);
    defer unlock(ib);
    if (pub_name) |name| {
        if (findPublic(ib, name) != null) return fail(code_ptr, sc.OSERR_PUBNOTUNIQUE);
    }

    const rp = gb.CreateRastPortTagList(null) orelse return fail(code_ptr, sc.OSERR_NOMONITOR);
    var bounds: graphics.Rect = .{};
    var surface: usize = 0;
    var format: u32 = 0;
    const ask = [_]TagItem{
        .{ .tag = graphics.RPTAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = graphics.RPTAG_Surface, .data = @intFromPtr(&surface) },
        .{ .tag = graphics.RPTAG_Format, .data = @intFromPtr(&format) },
        .{},
    };
    gb.GetRPAttrs(rp, &ask);
    if (displayTaken(ib, surface)) {
        gb.FreeRastPort(rp);
        return fail(code_ptr, sc.OSERR_NOTAVAILABLE);
    }

    const memory = ib.sys_base.AllocMem(@sizeOf(Screen), exec.MEMF_ANY | exec.MEMF_CLEAR) orelse {
        gb.FreeRastPort(rp);
        return fail(code_ptr, sc.OSERR_NOMEM);
    };
    const s: *Screen = @ptrCast(@alignCast(memory));

    const given_font: ?*graphics.TextFont = @ptrFromInt(ub.GetTagData(sc.SA_Font, 0, tags));
    const font = given_font orelse gb.OpenFont(graphics.POSPAZNAME, ib.font_height) orelse {
        ib.sys_base.FreeMem(memory, @sizeOf(Screen));
        gb.FreeRastPort(rp);
        return fail(code_ptr, sc.OSERR_NOMEM);
    };
    const info = lb.NewLayerInfo(rp) orelse {
        if (given_font == null) gb.CloseFont(font);
        ib.sys_base.FreeMem(memory, @sizeOf(Screen));
        gb.FreeRastPort(rp);
        return fail(code_ptr, sc.OSERR_NOMEM);
    };

    s.* = .{
        .base = ib,
        .rp = rp,
        .surface = surface,
        .layer_info = info,
        .font = font,
        .own_font = given_font == null,
        .title = @ptrFromInt(ub.GetTagData(sc.SA_Title, 0, tags)),
        .default_title = @ptrFromInt(ub.GetTagData(sc.SA_Title, 0, tags)),
        .width = bounds.width(),
        .height = bounds.height(),
        .depth = sdk.rtg.bitmaps.formatBits(@enumFromInt(format)),
        .pens = default_pens,
        .draw_info = undefined,
    };
    if (ub.FindTagItem(sc.SA_Pens, tags)) |item| {
        s.pens = @as(*const [sc.NUMDRIPENS]Pen, @ptrFromInt(item.data)).*;
    }
    s.draw_info = .{ .pens = &s.pens, .font = font, .depth = s.depth };
    if (pub_name) |name| {
        s.public = true;
        for (0..nameLen(name)) |i| s.pub_name[i] = name[i];
    }

    // The bar, then the ground. A new backdrop layer goes behind every
    // other, so made in this order the ground is at the very back and the
    // bar in front of it. The ground's hook paints it as it is made;
    // without memory for it the display is painted directly, and a window
    // leaving a part of it leaves it as it was.
    graphics.SetFont(gb, rp, font);
    menuImages(ib, s);
    if (ub.GetTagData(sc.SA_ShowTitle, 1, tags) != 0) {
        var font_height: u32 = 0;
        const metric = [_]TagItem{ .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) }, .{} };
        gb.GetRPAttrs(rp, &metric);
        s.bar_height = @as(i32, @intCast(font_height)) + 2 * bar_border + 1;
        const bar_bounds = graphics.Rect{ .max_x = s.width, .max_y = s.bar_height };
        const bar_tags = [_]TagItem{
            .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bar_bounds) },
            .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSMART },
            .{ .tag = layers.LATAG_Backdrop, .data = 1 },
            .{ .tag = layers.LATAG_BackFill, .data = layers.LAYERS_NOBACKFILL },
            .{},
        };
        // Without memory for the bar the screen still opens; it has no bar.
        s.bar = lb.CreateLayerTagList(info, &bar_tags);
        if (s.bar == null) s.bar_height = 0;
    }
    s.ground_fill = .{ .entry = &fillGround, .data = s };
    const ground_tags = [_]TagItem{
        .{ .tag = layers.LATAG_Bounds, .data = @intFromPtr(&bounds) },
        .{ .tag = layers.LATAG_Refresh, .data = layers.LAYERSIMPLE },
        .{ .tag = layers.LATAG_Backdrop, .data = 1 },
        .{ .tag = layers.LATAG_BackFill, .data = @intFromPtr(&s.ground_fill) },
        .{},
    };
    s.ground = lb.CreateLayerTagList(info, &ground_tags);
    if (s.ground == null) {
        setPen(ib, rp, s.pens[sc.BACKGROUNDPEN]);
        gb.RectFill(rp, &bounds);
    }
    drawBar(ib, s);

    s.windows.init();
    ib.sys_base.AddTail(@ptrCast(&ib.screen_list), @ptrCast(&s.node));
    // The first screen puts intuition on input.device's chain.
    @import("../input/_input.zig").start(ib);
    return s;
}

/// The images a menu item shows, in the DrawInfo, sized to the screen's
/// font: the tick an em and a little wide, the Amiga key two ems, both as
/// tall as the font's baseline and never under 8 rows for each 8 the font
/// has. The 16-row font is the 8-row one with every row drawn twice, and
/// the images are drawn twice as tall with it, so they keep the shape they
/// have beside the 8-row font. Without memory for them the screen still
/// opens, and its menus show neither.
fn menuImages(ib: *IntuitionBase, s: *Screen) void {
    const gb = ib.graphics_base;
    const em = gb.TextLength(s.rp, "m", 1);
    var baseline: u32 = 0;
    var font_height: u32 = 0;
    const metric = [_]TagItem{
        .{ .tag = graphics.RPTAG_FontBaseline, .data = @intFromPtr(&baseline) },
        .{ .tag = graphics.RPTAG_FontHeight, .data = @intFromPtr(&font_height) },
        .{},
    };
    gb.GetRPAttrs(s.rp, &metric);
    const least: i32 = 8 * @max(1, @as(i32, @intCast(font_height / 8)));
    const height = @max(least, @as(i32, @intCast(baseline)));
    s.draw_info.check_mark = menuImage(ib, s, ic.MENUCHECK, em + 7, height);
    s.draw_info.amiga_key = menuImage(ib, s, ic.AMIGAKEY, 2 * em + 7, height);
}

fn menuImage(ib: *IntuitionBase, s: *Screen, which: u32, width: i32, height: i32) ?*intuition.Object {
    const tags = [_]TagItem{
        .{ .tag = ic.SYSIA_Which, .data = which },
        .{ .tag = ic.SYSIA_DrawInfo, .data = @intFromPtr(&s.draw_info) },
        .{ .tag = ic.IA_Width, .data = @intCast(width) },
        .{ .tag = ic.IA_Height, .data = @intCast(height) },
        .{},
    };
    return ib.iface().NewObjectTagList(ib.sys_class, null, &tags);
}

/// No screen, with the reason where the caller asked for it.
fn fail(code_ptr: ?*u32, code: u32) ?*Screen {
    if (code_ptr) |p| p.* = code;
    return null;
}
